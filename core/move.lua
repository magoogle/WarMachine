-- ---------------------------------------------------------------------------
-- core/move.lua  --  Batmobile-driven movement primitive.
--
-- Activity tasks call into this instead of touching BatmobilePlugin / WarPath
-- directly.  Two tiers in priority order:
--
--   1. Actor in stream  -> interact_object(actor)
--      D4's native click-to-walk.  Works for any actor in actors_manager;
--      D4 walks the player the last few yards on its own.
--
--   2. Position-based  -> Batmobile (BatmobilePlugin.set_target)
--      Batmobile owns scene-aware pathfinding for dungeons/pits/undercity
--      where WarPath's overworld nav data doesn't apply.  Each pulse the
--      activity's pulse() must call move.tick() to drive Batmobile's
--      update + move loop -- that's the heartbeat.
--
-- WarPath is intentionally NOT used here for path planning.  WarPath stays
-- for catalog-lookup helpers (cross-zone routing, get_actors), but the
-- actual walking is Batmobile's job in every zone type.
--
-- Public API:
--
--   move.to_actor(actor)                -- tier 1: click-to-walk
--   move.to_pos(goal, opts)             -- tier 2: Batmobile pathfind
--   move.to_actor_or_pos(actor, pos, opts)
--   move.tick(force?)                   -- per-pulse heartbeat for Batmobile
--   move.clear()                        -- stop, drop target
--   move.is_done()                      -- true when Batmobile reached goal
--
-- Cross-zone helpers (catalog data; delegates to WarPathPlugin):
--   move.plan_to_zone(target_zone)
--   move.next_hop_actor(target_zone)
--   move.bookmark_here(id, kind?, meta?)
--   move.bookmark_nearest(kind?)
-- ---------------------------------------------------------------------------

local M = {}

local CALLER = 'warmachine'

-- Throttle Batmobile's update+move to 10fps.  Batmobile has its own 50ms
-- internal pacing; ticking at 60fps just runs it every call and burns
-- CPU.  Mirrors HelltideRevamped's bm_pulse cadence.  Pass force=true
-- right after set_target so the new path starts immediately.
local BM_TICK_INTERVAL = 0.1
local _last_tick_t     = -math.huge

-- Track the active target so move.to_pos calls with the same destination
-- skip redundant set_target work.
local _active_target = nil

-- Long-path threshold: targets farther than this default to
-- BatmobilePlugin.navigate_long_path which uses uncapped (300ms-capped)
-- A* and is the only reliable way to route across rooms in pits/undercity.
local LONG_PATH_THRESHOLD_M = 60.0

local function batmobile()
    return rawget(_G, 'BatmobilePlugin')
end

local function warpath()
    return rawget(_G, 'WarPathPlugin')
        or rawget(_G, 'StaticPatherPlugin')
        or nil
end

-- Convert any of (vec3, {x=,y=,z=}, {1,2,3}) into a vec3 anchored to the
-- player's z if the input doesn't carry one.
local function to_vec3(g, fallback_z)
    if not g then return nil end
    if type(g.x) == 'number' then return vec3:new(g.x, g.y, g.z or fallback_z) end
    if g[1] then return vec3:new(g[1], g[2], g[3] or fallback_z) end
    return g   -- already a vec3
end

local function targets_match(a, b)
    if not a or not b then return false end
    return math.abs(a:x() - b:x()) < 0.5
       and math.abs(a:y() - b:y()) < 0.5
end

-- ---------------------------------------------------------------------------
-- Tier 1: D4 native click-to-walk via interact_object.
-- ---------------------------------------------------------------------------
M.to_actor = function (actor)
    if not actor then return 'no_actor' end
    if not actor.get_position then return 'no_actor' end
    if not get_local_player() then return 'no_actor' end
    interact_object(actor)
    return 'interacted'
end

-- ---------------------------------------------------------------------------
-- Tier 2: position-based movement via Batmobile.
--
-- opts.arrive_radius  -- meters; default 3
-- opts.long_path      -- bool: force navigate_long_path (uncapped A*).
--                        Auto-engaged when goal is > LONG_PATH_THRESHOLD_M.
-- ---------------------------------------------------------------------------
local DEFAULT_ARRIVE = 3.0

M.is_zone_supported = function ()
    -- Batmobile pathfinds wherever the host pathfinder works -- effectively
    -- "everywhere."  Kept as a stub for callers that still ask.
    return batmobile() ~= nil
end

M.to_pos = function (goal, opts)
    if type(opts) == 'number' then
        opts = { arrive_radius = opts }
    elseif opts == nil then
        opts = {}
    end
    local arrive = opts.arrive_radius or DEFAULT_ARRIVE
    local lp = get_local_player()
    if not lp then return 'no_path' end
    local pp = lp:get_position()
    if not pp then return 'no_path' end

    goal = to_vec3(goal, pp:z())
    if not goal then return 'no_path' end

    local d = pp:dist_to(goal)
    if d <= arrive then
        if _active_target and targets_match(_active_target, goal) then
            M.clear()
        end
        return 'arrived'
    end

    local bm = batmobile()
    if not bm or not bm.set_target then return 'no_path' end

    -- Same destination, target still active -> just drive the next step.
    if _active_target and targets_match(_active_target, goal) then
        M.tick(true)
        return 'walking'
    end

    local accepted
    if opts.long_path or d > LONG_PATH_THRESHOLD_M then
        if bm.navigate_long_path then
            accepted = bm.navigate_long_path(CALLER, goal)
        else
            accepted = bm.set_target(CALLER, goal, false)
        end
    else
        accepted = bm.set_target(CALLER, goal, false)
    end

    if accepted == false then return 'no_path' end

    _active_target = goal
    M.tick(true)
    return 'walking'
end

M.to_actor_or_pos = function (actor, fallback_pos, opts)
    if actor and M.to_actor(actor) == 'interacted' then return 'interacted' end
    if fallback_pos then return M.to_pos(fallback_pos, opts) end
    return 'no_actor'
end

-- ---------------------------------------------------------------------------
-- Free-roam exploration.  Tasks call this when they have no specific
-- target but still want the player to move (helltide/return_to_zone,
-- core/explorer, pit floor seek).  Batmobile's own explorer picks the
-- next frontier cell and drives the player toward it; we just resume it.
--
-- opts.priority -- forwarded to BatmobilePlugin.set_priority (string from
--                  the consuming plugin, governs frontier scoring).
-- ---------------------------------------------------------------------------
M.explore = function (opts)
    local bm = batmobile()
    if not bm then return false end
    _active_target = nil
    if opts and opts.priority and bm.set_priority then
        pcall(bm.set_priority, CALLER, opts.priority)
    end
    if bm.resume then pcall(bm.resume, CALLER) end
    M.tick(true)
    return true
end

-- ---------------------------------------------------------------------------
-- Per-pulse heartbeat.  Each activity api.lua pulse() must call this so
-- Batmobile's pathfind/replan/move cycle ticks even when no task issued a
-- set_target this pulse.
--
-- force=true bypasses the 10fps throttle.  to_pos uses force=true on the
-- first step after set_target so the new path's first move fires
-- immediately rather than waiting up to 100ms.
-- ---------------------------------------------------------------------------
M.tick = function (force)
    local bm = batmobile()
    if not bm then return end
    local now = get_time_since_inject() or 0
    if not force and (now - _last_tick_t) < BM_TICK_INTERVAL then return end
    _last_tick_t = now
    if bm.update then pcall(bm.update, CALLER) end
    if bm.move   then pcall(bm.move,   CALLER) end
end

-- ---------------------------------------------------------------------------
-- Stop any in-flight movement.
-- ---------------------------------------------------------------------------
M.clear = function (_caller)
    _active_target = nil
    local bm = batmobile()
    if bm then
        if bm.is_long_path_navigating and bm.is_long_path_navigating() and bm.stop_long_path then
            pcall(bm.stop_long_path, CALLER)
        end
        if bm.clear_target then pcall(bm.clear_target, CALLER) end
    end
end

M.is_done = function ()
    local bm = batmobile()
    if not bm or not bm.is_done then return true end
    return bm.is_done()
end

-- ---------------------------------------------------------------------------
-- Cross-zone helpers (catalog reads via WarPathPlugin -- still useful for
-- "which zone do I teleport to next" lookups even though movement is
-- Batmobile's job).
-- ---------------------------------------------------------------------------

M.plan_to_zone = function (target_zone)
    local p = warpath()
    if not p or not p.find_route then return nil, 'no_warpath' end
    local lp = get_local_player()
    if not lp then return nil, 'no_player' end
    local w = get_current_world()
    local cur = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if not cur then return nil, 'no_zone' end
    return p.find_route(cur, target_zone)
end

M.next_hop_actor = function (target_zone)
    local p = warpath()
    if not p or not p.next_hop_actor then return nil end
    local w = get_current_world()
    local cur = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if not cur then return nil end
    return p.next_hop_actor(cur, target_zone)
end

M.bookmark_here = function (id, kind, meta)
    local p = warpath()
    if not p or not p.bookmark_add then return false end
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end
    local w = get_current_world()
    local cur = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if not cur then return false end
    return p.bookmark_add({
        id = id, zone = cur,
        x = pp:x(), y = pp:y(), z = pp:z(),
        kind = kind, meta = meta,
    })
end

M.bookmark_nearest = function (kind)
    local p = warpath()
    if not p or not p.bookmark_nearest then return nil end
    local lp = get_local_player()
    if not lp then return nil end
    local pp = lp:get_position()
    if not pp then return nil end
    local w = get_current_world()
    local cur = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if not cur then return nil end
    return p.bookmark_nearest(cur, pp:x(), pp:y(), kind)
end

return M
