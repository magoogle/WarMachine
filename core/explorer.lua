-- ---------------------------------------------------------------------------
-- core/explorer.lua
--
-- Embedded zone explorer.  Replaces BatmobilePlugin's freeroam mode for
-- catalog-incomplete zones.  Goal: walk to unexplored space without
-- retracing or spinning, using only data we capture ourselves.
--
-- Design (deliberately simple):
--
--   Visit history.  Per-zone hash keyed on coarse 4y grid cells.  Each
--   cell stores { samples, last_t }.  Updated every pulse.  When zone
--   changes, we drop the previous zone's table to free memory -- the
--   recorder's static catalog persists exploration data across sessions
--   for us, this in-memory map is just for "what have I seen in the
--   last few minutes of THIS run".
--
--   Frontier scoring.  Each tick we sample 8 compass directions at
--   radius RING_DIST_M from the player.  For each ring point we score
--   = (1 - normalized_visit_count) - dead_end_penalty - revisit_recent.
--   The highest-scoring point becomes the walk target.  Ties broken by
--   "stick with current target" momentum so we don't oscillate.
--
--   Dead-end detection.  If position barely changes for STUCK_WINDOW_S
--   seconds while we have an active target, mark the current cell as a
--   dead-end (deadend_count += 1).  Future ring points landing in that
--   cell get a heavy penalty.  Reset on zone change.
--
--   Walk dispatch.  Use core.move.to_pos toward the chosen ring point.
--   No host-walkability queries (the host doesn't reliably expose them
--   for arbitrary points); we trust core.move's tiered StaticPather ->
--   Batmobile fallback to figure out the actual route.  If the bot
--   genuinely cannot path there, stuck-detect kicks in and we re-pick.
--
-- Public API mirrors core/freeroam.lua so existing per-activity runners
-- can drop the explorer in via the same `make_freeroam(caller)` factory:
--
--   local make_explorer = require 'core.explorer'
--   table.insert(tasks, idle_idx, make_explorer('warmachine_nmd'))
--
-- core/freeroam.lua delegates to this module so individual activities
-- don't need to change.
-- ---------------------------------------------------------------------------

local zone = require 'core.zone'
local move = require 'core.move'

local M = {}

-- ---- Tunables ----
-- Tightened from the v1 defaults (12y ring / 8 dirs / 2.5s stuck) after
-- live testing showed the bot walking into walls and over-committing to
-- targets it couldn't actually reach.  Then tightened FURTHER (6y ->
-- 1.5y) per user feedback "we are targeting something too far away when
-- using explorer and its causing us to get stuck".  Very short steps
-- (1.5y) mean the bot can't commit to a target it can't reach -- if the
-- next 1.5y is walkable, take it; if not, pick a different direction
-- next pulse.  Walkability check + dead-end marking still cap the
-- worst-case wandering.
local CELL_SIZE_M    = 1.5       -- visit grid -- match step size for fine dedup
local RING_DIST_M    = 1.5       -- scan radius for frontier candidates (was 6)
local NUM_DIRS       = 12        -- 12 directions = every 30°
local SAMPLE_TICK_S  = 0.2
local PICK_TICK_S    = 0.5       -- re-pick more often since steps are shorter
local STUCK_WINDOW_S = 1.5       -- "no movement for this long" => stuck
local STUCK_DELTA_M  = 0.3       -- min cumulative movement in window (smaller scale)
local ARRIVE_RADIUS_M     = 0.8  -- must be < RING_DIST_M or we never arrive
local DEADEND_PENALTY     = 5.0
local RECENT_REVISIT_S    = 30.0
local RECENT_REVISIT_PEN  = 1.5
local UNREACHABLE_PENALTY = 100.0
-- "Openness" bias -- when scoring a ring candidate, sample its 4 cardinal
-- neighbors at OPEN_NEIGHBOR_DIST and count how many are walkable.  More
-- open neighbors = we're in the middle of a corridor / room; fewer = we're
-- next to a wall.  OPEN_NEIGHBOR_BONUS adds per walkable neighbor to the
-- candidate's score, biasing the bot away from wall-hugging.  Per user:
-- "try to stay in the middle between walls, not hug the walls so much."
local OPEN_NEIGHBOR_DIST  = 2.0
local OPEN_NEIGHBOR_BONUS = 0.25

-- Per-zone state.  Re-initialized on zone change.
local state = {
    zone        = nil,                    -- current zone name
    cells       = {},                     -- "cx:cy" -> { samples, last_t, deadend }
    -- Cached "most-visited cell sample count".  Maintained incrementally
    -- in sample_position() so score_point() doesn't have to scan all
    -- cells on every call (the original O(n_cells) scan inside scoring
    -- was the explorer's main per-frame cost -- 12 ring-points * O(N)
    -- every pick = O(12N) per pick).  Now O(1).
    max_visits  = 1,
    last_sample_t = 0,
    last_pick_t   = 0,

    target_x    = nil,
    target_y    = nil,
    target_cell = nil,

    -- stuck detection
    last_pos_x  = nil,
    last_pos_y  = nil,
    stuck_anchor_x = nil,
    stuck_anchor_y = nil,
    stuck_anchor_t = 0,
}

local function cell_key(x, y)
    return string.format('%d:%d', math.floor(x / CELL_SIZE_M), math.floor(y / CELL_SIZE_M))
end

local function cell_xy(x, y)
    return math.floor(x / CELL_SIZE_M), math.floor(y / CELL_SIZE_M)
end

-- Reset state when entering a new zone.
local function maybe_reset(cur_zone)
    if state.zone ~= cur_zone then
        state.zone        = cur_zone
        state.cells       = {}
        state.max_visits  = 1
        state.last_pick_t = 0
        state.target_x, state.target_y, state.target_cell = nil, nil, nil
        state.stuck_anchor_x, state.stuck_anchor_y, state.stuck_anchor_t = nil, nil, 0
    end
end

-- Sample current position into the visit grid.  Cheap; called every
-- SAMPLE_TICK_S seconds.
local function sample_position(now)
    if (now - state.last_sample_t) < SAMPLE_TICK_S then return end
    state.last_sample_t = now
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local x, y = pp:x(), pp:y()
    local key = cell_key(x, y)
    local c = state.cells[key]
    if not c then
        c = { samples = 0, last_t = 0, deadend = 0 }
        state.cells[key] = c
    end
    c.samples = c.samples + 1
    c.last_t  = now
    if c.samples > state.max_visits then state.max_visits = c.samples end

    -- Stuck-detection: if we've barely moved since the last anchor
    -- inside STUCK_WINDOW_S, mark the current cell as dead-end.
    if state.stuck_anchor_x == nil then
        state.stuck_anchor_x = x
        state.stuck_anchor_y = y
        state.stuck_anchor_t = now
    else
        local dx, dy = x - state.stuck_anchor_x, y - state.stuck_anchor_y
        local moved = math.sqrt(dx*dx + dy*dy)
        if moved >= STUCK_DELTA_M then
            state.stuck_anchor_x = x
            state.stuck_anchor_y = y
            state.stuck_anchor_t = now
        elseif (now - state.stuck_anchor_t) >= STUCK_WINDOW_S then
            -- Stuck.  Penalize current cell + invalidate any active target.
            c.deadend = (c.deadend or 0) + 1
            state.target_x, state.target_y, state.target_cell = nil, nil, nil
            state.last_pick_t = 0
            -- Re-anchor so we don't keep escalating the deadend count
            -- every frame while stuck.
            state.stuck_anchor_t = now
        end
    end
end

-- Count of walkable cardinal neighbors at OPEN_NEIGHBOR_DIST around
-- (x, y).  4 = wide-open space; 0 = isolated point or off-mesh.  We
-- use 4 cardinals (not all 8) for cost: each call is 4 host probes.
local function open_neighbors(x, y, z)
    if not utility or not utility.is_point_walkeable then return 4 end
    local count = 0
    local d = OPEN_NEIGHBOR_DIST
    local offsets = { {d,0}, {-d,0}, {0,d}, {0,-d} }
    for _, o in ipairs(offsets) do
        local p = vec3:new(x + o[1], y + o[2], z or 0)
        if utility.set_height_of_valid_position then
            local sok, snapped = pcall(utility.set_height_of_valid_position, p)
            if sok and snapped then p = snapped end
        end
        local ok, w = pcall(utility.is_point_walkeable, p)
        if ok and w then count = count + 1 end
    end
    return count
end

-- Score a single ring point.  Higher is better.  Mostly O(1): uses
-- the incrementally-maintained state.max_visits instead of re-scanning
-- every cell.  The openness bonus does 4 host probes per call which
-- is cheap (utility.is_point_walkeable is the recorder's primitive).
local function score_point(x, y, z, now)
    local cx, cy = cell_xy(x, y)
    local key = string.format('%d:%d', cx, cy)
    local c = state.cells[key]
    local visits = c and c.samples or 0
    local last_t = c and c.last_t or 0
    local deadend = c and c.deadend or 0

    local visit_norm = visits / state.max_visits

    local recent_pen = 0
    if c and (now - last_t) < RECENT_REVISIT_S then
        recent_pen = RECENT_REVISIT_PEN * (1 - (now - last_t) / RECENT_REVISIT_S)
    end

    -- Openness bonus: prefer points with all 4 cardinal neighbors
    -- walkable -- those are corridor / room interiors.  Wall-edges
    -- have 1-2 walkable cardinals and score lower, so the bot drifts
    -- toward the middle of traversable space.
    local open_bonus = OPEN_NEIGHBOR_BONUS * open_neighbors(x, y, z)

    -- Base: 1 = totally fresh frontier; 0 = saturated cell.  Plus open
    -- bonus, minus dead-end / recent-revisit penalties.
    return (1 - visit_norm) + open_bonus
                            - (deadend * DEADEND_PENALTY)
                            - recent_pen
end

-- Walkability probe.  Now uses utility.is_point_walkeable -- the same
-- O(1) primitive WarMapRecorder uses to fill its walkable-cell grid.
-- Was pathfinder.calculate_and_get_path_points (full A* per call) which
-- did dozens of route-computations per second and contributed to the
-- frame-stutter / crash issues earlier.  is_point_walkeable doesn't tell
-- us reachability, only "is this point on the navmesh" -- but for the
-- explorer's 1.5y next-step rings that's exactly the question we have:
-- "can the player physically stand here" -- since adjacent walkable
-- cells are by definition reachable from the current cell.
--
-- Returns 1 (walkable) or 0 (not).  Wrapped in pcall so a missing host
-- fn doesn't crash the explorer; in that case we fall back to "trust
-- everything" (treat all points reachable).
local function walkable_path_length(start_pos, goal_x, goal_y, goal_z)
    if not utility or not utility.is_point_walkeable then
        return 1   -- host doesn't expose the probe; assume reachable
    end
    local goal = vec3:new(goal_x, goal_y, goal_z or start_pos:z())
    -- Snap height to a valid walkable Z first if the host exposes it --
    -- otherwise is_point_walkeable rejects anything off the navmesh
    -- vertical band even when the XY is valid.  Recorder does the same.
    if utility.set_height_of_valid_position then
        local sok, snapped = pcall(utility.set_height_of_valid_position, goal)
        if sok and snapped then goal = snapped end
    end
    local ok, walkable = pcall(utility.is_point_walkeable, goal)
    if not ok or not walkable then return 0 end
    return 1
end

-- Pick a new target by scanning NUM_DIRS ring points.  Sticky momentum:
-- bias toward an existing valid target so we don't thrash.
--
-- Performance: we ONLY walkability-validate the top-scoring candidate
-- (and fall through to the next-best on failure), not all 12.  The
-- previous version called pathfinder.calculate_and_get_path_points
-- per ring point per pick = 12 path-calcs per 0.8s = 15+ per second,
-- which the user reported as severe lag.  Typical case is now ONE
-- path-calc per pick; pathological case (top several candidates all
-- behind walls) caps at NUM_DIRS path-calcs but stops the moment one
-- passes.
local function pick_target(now)
    if (now - state.last_pick_t) < PICK_TICK_S and state.target_x then
        return
    end
    state.last_pick_t = now
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local px, py, pz = pp:x(), pp:y(), pp:z()

    -- Phase 1: score all ring points cheaply (no walkability check).
    -- Build a small array sorted high-to-low so we can pick top-down.
    local cand = {}
    for i = 0, NUM_DIRS - 1 do
        local theta = (i / NUM_DIRS) * 2 * math.pi
        local rx = px + math.cos(theta) * RING_DIST_M
        local ry = py + math.sin(theta) * RING_DIST_M
        cand[#cand + 1] = { x = rx, y = ry, s = score_point(rx, ry, pz, now) }
    end
    table.sort(cand, function (a, b) return a.s > b.s end)

    -- Phase 2: walkability-validate only the top candidate (and fall
    -- through to next-best on failure).  Most picks resolve in 1 call.
    local best_x, best_y, best_s = nil, nil, -math.huge
    for i = 1, #cand do
        local c = cand[i]
        local plen = walkable_path_length(pp, c.x, c.y, pz)
        if plen > 0 then
            best_x, best_y, best_s = c.x, c.y, c.s
            break
        end
        -- Mark this cell as a soft dead-end so the same direction stops
        -- winning the score race forever.  Helps the bot drift to better
        -- frontiers when the ideal direction is permanently walled.
        local cx, cy = cell_xy(c.x, c.y)
        local cell = state.cells[string.format('%d:%d', cx, cy)]
        if not cell then
            cell = { samples = 0, last_t = now, deadend = 1 }
            state.cells[string.format('%d:%d', cx, cy)] = cell
        else
            cell.deadend = (cell.deadend or 0) + 1
        end
    end

    if not best_x then
        -- Every direction unreachable.  Drop target; next sample tick
        -- will adjust as the bot moves (stuck-detect).
        state.target_x, state.target_y, state.target_cell = nil, nil, nil
        return
    end

    -- Momentum: if the previous target is still scoring competitively
    -- AND still reachable, keep it.  One walkability call.
    if state.target_x and state.target_y then
        local prev_s = score_point(state.target_x, state.target_y, pz, now)
        if prev_s + 0.15 >= best_s then
            local prev_reach = walkable_path_length(pp, state.target_x, state.target_y, pz)
            if prev_reach > 0 then return end
        end
    end

    state.target_x   = best_x
    state.target_y   = best_y
    state.target_cell = cell_key(best_x, best_y)
end

-- Public: tick the explorer.  Call from a freeroam-fallback task once
-- per pulse.  Returns the active target for diagnostic display.
M.tick = function ()
    local cur_zone = zone.current()
    if not cur_zone then return nil end
    maybe_reset(cur_zone)
    local now = get_time_since_inject() or 0
    sample_position(now)
    pick_target(now)
    if state.target_x and state.target_y then
        local lp = get_local_player()
        local pp = lp and lp:get_position() or nil
        if pp then
            local goal = { x = state.target_x, y = state.target_y, z = pp:z() }
            move.to_pos(goal, { arrive_radius = ARRIVE_RADIUS_M })
        end
    end
    return state.target_x, state.target_y
end

-- Public: clear all explorer state.  Called when an activity is forced
-- to deactivate (mode change, main toggle off) so we don't carry a
-- stale target into the next session.
M.reset = function ()
    state.zone        = nil
    state.cells       = {}
    state.target_x, state.target_y, state.target_cell = nil, nil, nil
    state.last_pick_t = 0
    state.stuck_anchor_x, state.stuck_anchor_y, state.stuck_anchor_t = nil, nil, 0
end

-- Public: factory that produces a runner-task object compatible with
-- the existing make_freeroam contract.  The `caller` string is purely
-- diagnostic now (no Batmobile to forward it to); we keep it for
-- console-print parity with the old freeroam fallback.
M.make_task = function (caller)
    local task = {
        name           = 'explorer',
        status         = 'idle',
    }
    task.shouldExecute = function ()
        return get_local_player() ~= nil
    end
    task.Execute = function ()
        local tx, ty = M.tick()
        if tx and ty then
            task.status = string.format('exploring %s -> (%.0f,%.0f)', caller, tx, ty)
        else
            task.status = 'exploring ' .. caller
        end
    end
    return task
end

return M
