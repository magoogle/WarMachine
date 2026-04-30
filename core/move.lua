-- ---------------------------------------------------------------------------
-- core/move.lua  --  Three-tier movement primitive.
--
-- Activity tasks call into this instead of directly invoking BatmobilePlugin
-- or pathfinder.request_move.  The primitive picks the best transport for
-- the situation in this priority order:
--
--   1. Actor in stream  -> interact_object(actor)
--      D4's native click-to-walk.  Works for any actor in actors_manager,
--      regardless of distance.  No Lua A*, no pause/resume games.
--
--   2. StaticPather has data for the current zone  -> host pathfinder
--      StaticPatherPlugin.find_path(start, goal) drives world:calculate_path
--      under the hood.  We feed the next waypoint into pathfinder.request_move
--      and re-plan every pulse.  Path is collision-aware against the live
--      walkable mesh.
--
--   3. Fallback  -> BatmobilePlugin (frontier-BFS exploration)
--      For zones we have no merged WarMap data on yet.  Same API the old
--      sub-plugins used; we just call it through this thin facade so
--      activities don't have to scatter `BatmobilePlugin.set_target / move`
--      everywhere.
--
-- Public API (all functions return a status string -- 'interacted' /
-- 'walking' / 'arrived' / 'no_actor' / 'no_path' / etc):
--
--   move.to_actor(actor)          -- tier 1: click-to-walk + interact
--   move.to_pos(goal, opts)       -- tier 2 or 3 depending on data availability
--   move.to_actor_or_pos(actor, fallback_pos, opts)
--   move.is_zone_supported()      -- bool: does StaticPather have data here
-- ---------------------------------------------------------------------------

local M = {}

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
-- Tier 2/3: position-based movement.
--
-- opts.arrive_radius    -- meters; default 3
-- opts.prefer_batmobile -- force tier 3 even when StaticPather has data
--                          (useful when curated data is stale and the
--                          live mesh has changed)
-- opts.batmobile_caller -- caller label for Batmobile's per-caller pause/
--                          resume bookkeeping; defaults to 'warmachine'
-- ---------------------------------------------------------------------------
local DEFAULT_ARRIVE = 3.0

-- Convert any of (vec3, {x=,y=,z=}, {1,2,3}) into a vec3 anchored to the
-- player's z if the input doesn't carry one.
local function to_vec3(g, fallback_z)
    if not g then return nil end
    if type(g.x) == 'number' then return vec3:new(g.x, g.y, g.z or fallback_z) end
    if g[1] then return vec3:new(g[1], g[2], g[3] or fallback_z) end
    -- Already a vec3 (g.x is a method).
    return g
end

M.is_zone_supported = function ()
    return StaticPatherPlugin
       and StaticPatherPlugin.is_zone_supported
       and StaticPatherPlugin.is_zone_supported() or false
end

M.to_pos = function (goal, opts)
    opts = opts or {}
    local arrive = opts.arrive_radius or DEFAULT_ARRIVE
    local lp = get_local_player()
    if not lp then return 'no_path' end
    local pp = lp:get_position()
    if not pp then return 'no_path' end

    goal = to_vec3(goal, pp:z())
    if not goal then return 'no_path' end

    local d = pp:dist_to(goal)
    if d <= arrive then return 'arrived' end

    -- Tier 2: StaticPather + host pathfinder
    if not opts.prefer_batmobile and M.is_zone_supported() then
        if StaticPatherPlugin.find_path then
            local path = StaticPatherPlugin.find_path(pp, goal)
            if path and #path > 0 then
                local next_node = path[2] or path[1]
                if next_node then
                    if pathfinder and pathfinder.request_move then
                        pathfinder.request_move(next_node)
                        return 'walking'
                    end
                end
            end
        end
        -- StaticPather couldn't find a path; fall through to Batmobile.
    end

    -- Tier 3: Batmobile
    if BatmobilePlugin then
        local caller = opts.batmobile_caller or 'warmachine'
        if BatmobilePlugin.set_target then
            BatmobilePlugin.set_target(caller, goal)
        end
        if BatmobilePlugin.update then BatmobilePlugin.update(caller) end
        if BatmobilePlugin.move   then BatmobilePlugin.move(caller)   end
        return 'walking'
    end

    return 'no_path'
end

-- ---------------------------------------------------------------------------
-- Convenience: try the live actor first, fall back to a known position
-- (typically the same actor's last-known coords from StaticPather data).
-- ---------------------------------------------------------------------------
M.to_actor_or_pos = function (actor, fallback_pos, opts)
    if actor and M.to_actor(actor) == 'interacted' then return 'interacted' end
    if fallback_pos then return M.to_pos(fallback_pos, opts) end
    return 'no_actor'
end

-- ---------------------------------------------------------------------------
-- Stop / clear any in-flight movement.  Activity tasks call this when they
-- decide they're done with a target so Batmobile doesn't keep walking.
-- (Tier 1/2 don't have stick-iness; only tier 3 needs clearing.)
-- ---------------------------------------------------------------------------
M.clear = function (caller)
    caller = caller or 'warmachine'
    if BatmobilePlugin and BatmobilePlugin.clear_target then
        BatmobilePlugin.clear_target(caller)
    end
end

return M
