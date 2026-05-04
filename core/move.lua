-- ---------------------------------------------------------------------------
-- core/move.lua  --  Two-tier movement primitive.
--
-- Activity tasks call into this instead of directly invoking pathfinder
-- or WarPath.  Two tiers in priority order:
--
--   1. Actor in stream  -> interact_object(actor)
--      D4's native click-to-walk.  Works for any actor in actors_manager,
--      regardless of distance.
--
--   2. Position-based  -> WarPath (required)
--      WarPathPlugin.find_path(start, goal) delegates to the host's
--      world:calculate_path().  Centerline smoothing runs when curated
--      nav data exists for the zone.  We feed the next waypoint into
--      pathfinder.request_move and re-plan every pulse.
--
-- Public API (functions return a status string):
--
--   move.to_actor(actor)                   -- tier 1: click-to-walk
--   move.to_pos(goal, opts)                -- tier 2: WarPath pathfinding
--   move.to_actor_or_pos(actor, pos, opts)
--   move.is_zone_supported()               -- bool: WarPath has curated data here
--   move.clear()                           -- stop any in-flight movement
--
-- Cross-zone helpers (delegates to WarPathPlugin):
--   move.plan_to_zone(target_zone)
--   move.next_hop_actor(target_zone)
--   move.bookmark_here(id, kind?, meta?)
--   move.bookmark_nearest(kind?)
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Plugin reference resolver.  Accepts both WarPathPlugin (current name)
-- and StaticPatherPlugin (legacy alias) so bundles in transition keep working.
-- ---------------------------------------------------------------------------
local function plugin()
    return rawget(_G, 'WarPathPlugin')
        or rawget(_G, 'StaticPatherPlugin')
        or nil
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
-- Tier 2: position-based movement via WarPath.
--
-- opts.arrive_radius  -- meters; default 3
-- opts.smooth         -- bool, default true: run centerline smoothing on the
--                        WarPath path.  Set false for exit-precision moves
--                        where hugging the wall is actually the goal (stepping
--                        ONTO a portal switch).
-- ---------------------------------------------------------------------------
local DEFAULT_ARRIVE   = 3.0
local DEFAULT_LOOKAHEAD = 8.0   -- meters ahead on the path to target; creates
                                 -- smooth curves instead of sharp angle changes

-- ---------------------------------------------------------------------------
-- Path cache.  move.to_pos is called every pulse the bot is moving; without
-- this cache each call recomputes the host pathfinder (~60 A* runs/sec per
-- active task = the dominant lag source).  The runner only drives ONE task
-- per pulse so a single slot suffices; the goal-coord check evicts on
-- target change.
-- ---------------------------------------------------------------------------
local PATH_CACHE_TTL_S = 0.5    -- re-plan after this much wall time
local GOAL_TOLERANCE_M = 1.5    -- re-plan if goal coords moved more than this
local _path_cache = {
    goal_x = nil, goal_y = nil,
    smooth = nil,
    path = nil,
    computed_at = -math.huge,
}

local function cached_find_path(p, pp, goal, find_opts)
    local now = (get_time_since_inject and get_time_since_inject()) or 0
    local gx, gy = goal:x(), goal:y()
    local smooth = not (find_opts and find_opts.smooth == false)
    local c = _path_cache
    if c.path and c.goal_x and c.smooth == smooth then
        local dx = c.goal_x - gx
        local dy = c.goal_y - gy
        if (dx * dx + dy * dy) <= (GOAL_TOLERANCE_M * GOAL_TOLERANCE_M)
           and (now - c.computed_at) < PATH_CACHE_TTL_S then
            return c.path
        end
    end
    local path = p.find_path(pp, goal, find_opts)
    if path and #path > 0 then
        c.goal_x, c.goal_y = gx, gy
        c.smooth = smooth
        c.path = path
        c.computed_at = now
    end
    return path
end

-- Convert any of (vec3, {x=,y=,z=}, {1,2,3}) into a vec3 anchored to the
-- player's z if the input doesn't carry one.
local function to_vec3(g, fallback_z)
    if not g then return nil end
    if type(g.x) == 'number' then return vec3:new(g.x, g.y, g.z or fallback_z) end
    if g[1] then return vec3:new(g[1], g[2], g[3] or fallback_z) end
    return g   -- already a vec3
end

-- ---------------------------------------------------------------------------
-- Pure-pursuit lookahead: walk along path segments from the player's
-- current position and return the point exactly `lookahead_m` meters
-- ahead.  When the lookahead distance exceeds the remaining path length
-- the final waypoint (the goal) is returned, so precise arrival is
-- preserved at close range.
-- ---------------------------------------------------------------------------
local function lookahead_target(path, player_pos, lookahead_m)
    if not path or #path == 0 then return nil end
    if #path == 1 or lookahead_m <= 0 then return path[#path] end
    local remaining = lookahead_m
    local px, py, pz = player_pos:x(), player_pos:y(), player_pos:z()
    for i = 1, #path do
        local wp = path[i]
        local wx, wy, wz = wp:x(), wp:y(), wp:z()
        local dx, dy = wx - px, wy - py
        local seg_len = math.sqrt(dx * dx + dy * dy)
        if seg_len >= remaining then
            local t = remaining / seg_len
            return vec3:new(px + dx * t, py + dy * t, pz + (wz - pz) * t)
        end
        remaining = remaining - seg_len
        px, py, pz = wx, wy, wz
    end
    return path[#path]
end

M.is_zone_supported = function ()
    local p = plugin()
    return p and p.is_zone_supported and p.is_zone_supported() or false
end

M.to_pos = function (goal, opts)
    -- Accept both signatures:
    --   move.to_pos(goal, { arrive_radius = 3.0, smooth = false })
    --   move.to_pos(goal, 3.0)   -- legacy: number = arrive radius
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
    if d <= arrive then return 'arrived' end

    -- WarPath: find_path delegates to world:calculate_path().
    local p = plugin()
    if not p or not p.find_path then return 'no_path' end

    local find_opts = (opts.smooth == false) and { smooth = false } or nil
    local path = cached_find_path(p, pp, goal, find_opts)
    if path and #path > 0 then
        local lm = opts.lookahead_m
        if lm == nil then lm = DEFAULT_LOOKAHEAD end
        local next_node = lookahead_target(path, pp, lm)
        if next_node and pathfinder and pathfinder.request_move then
            pathfinder.request_move(next_node)
            return 'walking'
        end
    end

    return 'no_path'
end

-- ---------------------------------------------------------------------------
-- Convenience: try the live actor first, fall back to a known position.
-- ---------------------------------------------------------------------------
M.to_actor_or_pos = function (actor, fallback_pos, opts)
    if actor and M.to_actor(actor) == 'interacted' then return 'interacted' end
    if fallback_pos then return M.to_pos(fallback_pos, opts) end
    return 'no_actor'
end

-- ---------------------------------------------------------------------------
-- Stop any in-flight movement.  Activity tasks call this when done with
-- a target so movement doesn't persist across pulses.
-- ---------------------------------------------------------------------------
M.clear = function (_caller)
    if pathfinder and pathfinder.clear_stored_path then
        pcall(pathfinder.clear_stored_path)
    end
    _path_cache.path = nil
    _path_cache.goal_x = nil
    _path_cache.goal_y = nil
end

-- ---------------------------------------------------------------------------
-- Cross-zone helpers (delegates to WarPathPlugin).
-- ---------------------------------------------------------------------------

-- Returns an array of "go-here" steps to reach `target_zone` from the
-- player's current zone, or nil + reason on unreachable.
M.plan_to_zone = function (target_zone)
    local p = plugin()
    if not p or not p.find_route then return nil, 'no_warpath' end
    local lp = get_local_player()
    if not lp then return nil, 'no_player' end
    local w = get_current_world()
    local cur = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if not cur then return nil, 'no_zone' end
    return p.find_route(cur, target_zone)
end

-- Returns the actor coords in the current zone to walk to in order to
-- progress toward `target_zone`.  Returns nil when unknown.
M.next_hop_actor = function (target_zone)
    local p = plugin()
    if not p or not p.next_hop_actor then return nil end
    local w = get_current_world()
    local cur = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if not cur then return nil end
    return p.next_hop_actor(cur, target_zone)
end

-- Drop a bookmark at the player's current position for later recall.
M.bookmark_here = function (id, kind, meta)
    local p = plugin()
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

-- Recall the nearest bookmarked POI of the given kind.
M.bookmark_nearest = function (kind)
    local p = plugin()
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
