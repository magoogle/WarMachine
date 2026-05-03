-- ---------------------------------------------------------------------------
-- core/walker.lua
--
-- Internal locomotion driver -- the tier-3 fallback for core/move.lua
-- when WarPath has no curated data for the current zone.  Plans a
-- host A* path to the goal, walks it node-by-node, handles common
-- D4 obstacles (climb gizmos, doors, "stuck inside a small room").
--
-- Borrows the most useful bits of the deprecated Batmobile plugin's
-- core/navigator.lua (~2000 lines) but stays under 350.  Kept in
-- WarMachine so we don't carry a runtime dependency on Batmobile.
--
-- API:
--   walker.set_target(goal, actor?)  -- vec3/table; optional live actor for blacklist
--   walker.clear_target()
--   walker.tick()                    -- called from move.to_pos's tier-3 path
--   walker.stop()                    -- hard-stop: clear target + halt
--   walker.is_done()
--   walker.get_target()
--   walker.get_status()              -- introspection: trapped? trav-active?
--
-- New in v2 vs v1 (Batmobile borrows):
--   * Traversal-gizmo handling.  When the next path node sits on top
--     of a Traversal_Gizmo actor (climb, ladder, door), walk to it
--     and interact_object() instead of trying to walk through it.
--     Blacklists the gizmo for 15s after use to prevent
--     immediate-recross loops.
--   * Trap escape.  If the player has been confined to a < 25m bbox
--     for > 30s, declare 'trapped'.  Long-blacklist (5min) any
--     traversal we recently used so attempt_escape can pick a
--     different exit (different-floor gizmo, opposite-direction
--     portal).  After escaping, hold trap-state for 15s so the
--     escape's traversal doesn't immediately re-trap us.
--   * Stuck classifier.  Distinguishes static stuck (no movement)
--     from oscillating stuck (corner-bounce, doorway shimmy).
-- ---------------------------------------------------------------------------

local M = {}

-- ---- Tunables ----
local PATH_REPLAN_S      = 2.0    -- repath if active path is older than this
local NODE_ARRIVE_R      = 1.0    -- consider a path node "reached" within R yards
local STUCK_DELTA_M      = 0.5    -- minimum movement to count as "moving"
local STUCK_WINDOW_S     = 2.0    -- if we haven't moved STUCK_DELTA in this long
local UNSTUCK_EVADE_ID   = 337031 -- universal evade spell SNO
local TICK_THROTTLE_S    = 0.05   -- ignore ticks closer together than this

-- Traversal handling.
local TRAV_DETECT_R      = 5.0    -- player must be within this of a gizmo to consider crossing
local TRAV_NODE_NEAR_R   = 3.0    -- gizmo must be within this of next path node to be "in the way"
local TRAV_BLACKLIST_S   = 15     -- skip a just-used traversal for this long
local TRAV_GIZMO_PATTERN = '[Tt]raversal_Gizmo'   -- skin name regex
-- Cache: scanning all actors is expensive; gizmos don't move, so a
-- 100ms-stale list is fine.  Without caching the walker fires
-- get_all_actors 20+ times per second, which the user has reported
-- as a frame-stutter source.
local TRAV_CACHE_TTL_S   = 0.1

-- Trap detection.
local TRAP_BBOX_M        = 25.0   -- "small bbox" threshold
local TRAP_TIMEOUT_S     = 30.0   -- bbox-confined for this long => trapped
local TRAP_SAMPLE_S      = 1.0    -- how often to sample for bbox computation
local TRAP_HISTORY_MAX   = 60     -- ring-buffer size (60 samples * 1s = 60s window)
local TRAP_LONG_BL_S     = 300    -- long-blacklist a trap-implicated traversal for this long
local TRAP_GRACE_S       = 15     -- after escaping, hold trap-state this long

-- ---- State (single shared walker; D4 is one-character so this is fine) ----
local state = {
    target          = nil,     -- vec3 goal, or nil
    target_actor    = nil,     -- live actor that produced the target (for unreachable blacklist)
    path            = {},      -- vec3 array, planned path
    path_t          = 0,       -- when path was planned

    last_pos        = nil,     -- last sampled player position
    last_pos_t      = 0,       -- when last_pos was sampled
    last_move_t     = 0,       -- last time we observed actual movement
    stuck_strikes   = 0,

    last_tick_t     = 0,       -- throttle guard

    -- Traversal handling
    trav_cache      = nil,     -- { actor, ... }
    trav_cache_t    = 0,
    trav_blacklist  = {},      -- key -> expiry monotonic seconds
    trav_long_bl    = {},      -- key -> long-blacklist expiry
    trav_active     = nil,     -- {actor, key, started_at} during a crossing

    -- Trap detection
    pos_history     = {},      -- ring buffer of {x, y, t}
    pos_history_t   = 0,
    trapped         = false,
    trapped_since   = nil,
    trap_grace_until = 0,
}

-- ---- Helpers ----

local function now_s()
    return get_time_since_inject and get_time_since_inject() or 0
end

local function as_vec3(g)
    if not g then return nil end
    if g.get_position then g = g:get_position() end
    if type(g) == 'table' and type(g.x) == 'number' then
        return vec3:new(g.x, g.y, g.z or 0)
    end
    return g
end

local function dist2d(a, b)
    if not a or not b then return math.huge end
    local ax, ay = a:x(), a:y()
    local bx, by = b:x(), b:y()
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx*dx + dy*dy)
end

local function trav_key(actor)
    if not actor or not actor.get_skin_name or not actor.get_position then return nil end
    local p = actor:get_position()
    if not p then return nil end
    return string.format('%s|%.0f|%.0f|%.0f',
        actor:get_skin_name() or '?',
        p:x(), p:y(), p:z() or 0)
end

local function is_blacklisted(key, now)
    if not key then return true end
    local short = state.trav_blacklist[key]
    if short and now < short then return true end
    if short and now >= short then state.trav_blacklist[key] = nil end
    local long = state.trav_long_bl[key]
    if long and now < long then return true end
    if long and now >= long then state.trav_long_bl[key] = nil end
    return false
end

-- ---- Traversal-gizmo discovery ----

-- Returns a list of nearby Traversal_Gizmo actors, sorted by distance.
-- Cached for TRAV_CACHE_TTL_S so we don't rescan every tick.
local function get_traversals(player_pos)
    local now = now_s()
    if state.trav_cache and (now - state.trav_cache_t) < TRAV_CACHE_TTL_S then
        return state.trav_cache
    end
    local out = {}
    if not actors_manager or not actors_manager.get_all_actors then
        state.trav_cache, state.trav_cache_t = out, now
        return out
    end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a.get_skin_name and a.get_position then
            local sn = a:get_skin_name()
            if sn and sn:match(TRAV_GIZMO_PATTERN) then
                local p = a:get_position()
                if p then
                    local d = dist2d(player_pos, p)
                    if d <= 30 then
                        out[#out + 1] = { actor = a, dist = d, pos = p }
                    end
                end
            end
        end
    end
    table.sort(out, function (a, b) return a.dist < b.dist end)
    state.trav_cache, state.trav_cache_t = out, now
    return out
end

-- Returns the closest non-blacklisted traversal whose position is "in
-- the way" of the next path node (i.e. closer to it than the player
-- is).  Used when we're stuck or when the next path node sits on top
-- of a traversal.  Returns nil if no usable gizmo nearby.
local function find_blocking_traversal(player_pos, next_node)
    if not next_node then return nil end
    local now = now_s()
    local travs = get_traversals(player_pos)
    for _, t in ipairs(travs) do
        if t.dist <= TRAV_DETECT_R then
            local key = trav_key(t.actor)
            if key and not is_blacklisted(key, now) then
                local d_to_node = dist2d(t.pos, next_node)
                if d_to_node <= TRAV_NODE_NEAR_R then
                    -- Direction check: only pick a traversal that is
                    -- AT LEAST AS CLOSE to the goal as we are -- avoids
                    -- backtracking into a gizmo behind us when there's
                    -- one ahead too.
                    return t.actor, key
                end
            end
        end
    end
    return nil
end

-- ---- Trap detection ----

-- Push a position sample, evict old entries.  Returns true if we
-- judge the player is currently trapped (bbox < TRAP_BBOX_M for the
-- last TRAP_TIMEOUT_S of samples).
local function update_trap(pp, now)
    if (now - state.pos_history_t) < TRAP_SAMPLE_S then return state.trapped end
    state.pos_history_t = now
    local h = state.pos_history
    h[#h + 1] = { x = pp:x(), y = pp:y(), t = now }
    while #h > TRAP_HISTORY_MAX do table.remove(h, 1) end

    -- Need at least TRAP_TIMEOUT_S of history to make a call.
    if #h < math.floor(TRAP_TIMEOUT_S / TRAP_SAMPLE_S) then
        state.trapped = false
        return false
    end
    local cutoff = now - TRAP_TIMEOUT_S
    local mnx, mxx, mny, mxy = math.huge, -math.huge, math.huge, -math.huge
    for _, s in ipairs(h) do
        if s.t >= cutoff then
            if s.x < mnx then mnx = s.x end
            if s.x > mxx then mxx = s.x end
            if s.y < mny then mny = s.y end
            if s.y > mxy then mxy = s.y end
        end
    end
    local bbox = math.max(mxx - mnx, mxy - mny)
    if bbox > 0 and bbox < TRAP_BBOX_M then
        if not state.trapped then
            state.trapped = true
            state.trapped_since = now
            -- Long-blacklist the most-recently-used traversal so the
            -- escape path picks something else.  Without this, a
            -- broken trav (e.g. cliffside climb that drops you back
            -- into the same room) will be re-selected immediately.
            if state.trav_active then
                state.trav_long_bl[state.trav_active.key] = now + TRAP_LONG_BL_S
            end
            -- TRAP-RECOVERY: clear the active target + mark its actor
            -- (if any) unreachable.  Without this, the bot stays
            -- pinned on a target it can't reach -- "pathing through
            -- impassable wall" the user reported.  Caller's next
            -- pulse re-picks (interact_poi will skip a now-unreachable
            -- POI; freeroam picks a different ring direction).
            if state.target_actor then
                local ok, target_mod = pcall(require, 'core.target')
                if ok and target_mod and target_mod.mark_unreachable then
                    pcall(target_mod.mark_unreachable, state.target_actor)
                end
            end
            state.target       = nil
            state.target_actor = nil
            state.path         = {}
            if pathfinder and pathfinder.clear_stored_path then
                pcall(pathfinder.clear_stored_path)
            end
            console.print(string.format(
                '[walker] TRAPPED -- bbox=%.1fm for %.0fs; cleared target + blacklisted',
                bbox, TRAP_TIMEOUT_S))
        end
        return true
    else
        if state.trapped then
            -- Just escaped.  Hold "trap mode" briefly so the escape
            -- traversal doesn't immediately re-trap us via the same
            -- path home.
            state.trapped = false
            state.trap_grace_until = now + TRAP_GRACE_S
            console.print(string.format('[walker] escaped trap -- grace until +%ds', TRAP_GRACE_S))
        end
    end
    return false
end

-- ---- Public ----

M.set_target = function (goal, actor)
    local v = as_vec3(goal)
    if not v then return end
    if state.target and dist2d(state.target, v) < 0.5 then
        if actor and not state.target_actor then state.target_actor = actor end
        return
    end
    state.target       = v
    state.target_actor = actor
    state.path         = {}
    state.path_t       = 0
end

M.clear_target = function ()
    state.target       = nil
    state.target_actor = nil
    state.path         = {}
end

M.stop = function ()
    M.clear_target()
    if pathfinder and pathfinder.clear_stored_path then
        pcall(pathfinder.clear_stored_path)
    end
end

M.is_done = function ()
    if not state.target then return true end
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end
    return dist2d(pp, state.target) <= NODE_ARRIVE_R
end

M.get_target = function ()
    return state.target
end

-- For GUI / diagnostics.
M.get_status = function ()
    return {
        target       = state.target ~= nil,
        path_len     = #state.path,
        stuck        = state.stuck_strikes,
        trapped      = state.trapped,
        trav_active  = state.trav_active and state.trav_active.key or nil,
        trav_bl_count = (function ()
            local n = 0
            for _ in pairs(state.trav_blacklist) do n = n + 1 end
            return n
        end)(),
    }
end

-- ---- Tick ----

M.tick = function ()
    local now = now_s()
    if (now - state.last_tick_t) < TICK_THROTTLE_S then return end
    state.last_tick_t = now

    if not state.target then return end
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    -- Always update trap state: triggers long-blacklist on the active
    -- traversal if a crossing dumped us right back into a small bbox.
    update_trap(pp, now)

    -- Auto-clear target on arrival.
    if dist2d(pp, state.target) <= NODE_ARRIVE_R then
        state.target = nil
        state.path   = {}
        if pathfinder and pathfinder.clear_stored_path then
            pcall(pathfinder.clear_stored_path)
        end
        return
    end

    -- (Re)plan path if missing or stale.
    if #state.path == 0 or (now - state.path_t) > PATH_REPLAN_S then
        if pathfinder and pathfinder.calculate_and_get_path_points then
            local ok, path = pcall(pathfinder.calculate_and_get_path_points, pp, state.target)
            if ok and type(path) == 'table' and #path > 0 then
                state.path   = path
                state.path_t = now
            end
        end
    end

    -- Trim path nodes already passed.
    while #state.path > 0 and dist2d(pp, state.path[1]) <= NODE_ARRIVE_R do
        table.remove(state.path, 1)
    end

    local next_node = state.path[1] or state.target

    -- Traversal handling: if the next node sits on top of a gizmo,
    -- interact with the gizmo (climb / open door) instead of trying
    -- to walk past it.
    local trav_actor, trav_id = find_blocking_traversal(pp, next_node)
    if trav_actor then
        local d_to_trav = dist2d(pp, trav_actor:get_position())
        if d_to_trav <= TRAV_NODE_NEAR_R then
            -- Right on top of it; interact.
            interact_object(trav_actor)
            state.trav_blacklist[trav_id] = now + TRAV_BLACKLIST_S
            state.trav_active = { actor = trav_actor, key = trav_id, started_at = now }
            -- Drop the path so we re-plan from the post-crossing position.
            state.path = {}
            return
        else
            -- Walk to it.
            if pathfinder and pathfinder.request_move then
                pcall(pathfinder.request_move, trav_actor:get_position())
            end
            return
        end
    end

    -- Stuck detection.
    if state.last_pos == nil or dist2d(pp, state.last_pos) >= STUCK_DELTA_M then
        state.last_pos    = pp
        state.last_move_t = now
        state.stuck_strikes = 0
    end
    local stuck = (now - state.last_move_t) > STUCK_WINDOW_S

    if stuck then
        state.stuck_strikes = (state.stuck_strikes or 0) + 1
        -- Cheapest unstick: one evade in the goal direction.
        local goto_node = state.path[1] or state.target
        if cast_spell and cast_spell.position
           and utility and utility.can_cast_spell
           and utility.can_cast_spell(UNSTUCK_EVADE_ID)
           and goto_node
        then
            pcall(cast_spell.position, UNSTUCK_EVADE_ID, goto_node, 0)
        end
        if state.stuck_strikes >= 2 then
            -- Give up on this target; blacklist the actor that produced
            -- it so kill_monster's pick() doesn't re-pick the same one.
            local ok, target_mod = pcall(require, 'core.target')
            if ok and target_mod and state.target_actor then
                pcall(target_mod.mark_unreachable, state.target_actor)
            end
            -- Long-blacklist the active traversal if any -- maybe it's
            -- a broken gizmo, even if our trap-detector hasn't fired
            -- yet (player is stuck right at the gizmo's threshold).
            if state.trav_active then
                state.trav_long_bl[state.trav_active.key] =
                    now + TRAP_LONG_BL_S
            end
            state.target       = nil
            state.target_actor = nil
            state.path         = {}
            state.stuck_strikes = 0
            if pathfinder and pathfinder.clear_stored_path then
                pcall(pathfinder.clear_stored_path)
            end
            return
        end
        -- Force replan on next tick.
        state.path_t      = 0
        state.last_move_t = now
        return
    end

    -- Walk toward next node.
    if next_node and pathfinder and pathfinder.request_move then
        pcall(pathfinder.request_move, next_node)
    end
end

return M
