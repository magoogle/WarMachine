-- ---------------------------------------------------------------------------
-- core/move.lua  --  Three-tier movement primitive.
--
-- Activity tasks call into this instead of directly invoking pathfinder
-- or the walker.  The primitive picks the best transport for the
-- situation in this priority order:
--
--   1. Actor in stream  -> interact_object(actor)
--      D4's native click-to-walk.  Works for any actor in actors_manager,
--      regardless of distance.  No Lua A*, no pause/resume games.
--
--   2. WarPath has data for the current zone  -> host pathfinder + centerline
--      WarPathPlugin.find_path(start, goal) drives world:calculate_path
--      under the hood and runs the result through centerline smoothing
--      using the server-precomputed wall_dist map.  We feed the next
--      waypoint into pathfinder.request_move and re-plan every pulse.
--      Path is collision-aware against the live walkable mesh.
--
--   3. Fallback  -> internal walker (core/walker.lua)
--      For zones we have no merged WarMap data on yet.  Plans a path
--      via the host's pathfinder and walks node-by-node with stuck
--      detection + evade-based unstick.  Borrows traversal-gizmo and
--      trap-escape patterns from the (deprecated) Batmobile plugin
--      WITHOUT a runtime dependency on it.
--
-- Public API (all functions return a status string -- 'interacted' /
-- 'walking' / 'arrived' / 'no_actor' / 'no_path' / etc):
--
--   move.to_actor(actor)              -- tier 1: click-to-walk + interact
--   move.to_pos(goal, opts)           -- tier 2 or 3 depending on data availability
--   move.to_actor_or_pos(actor, fallback_pos, opts)
--   move.is_zone_supported()          -- bool: does WarPath have data here
--
-- New cross-zone helpers (v2):
--   move.travel_to_zone(zone_name, opts)  -- multi-hop via WarPathPlugin.find_route
--   move.next_hop_actor(zone_name)        -- which actor in current zone leads
--                                            toward zone_name (for tasks that
--                                            want to display "go through X")
--   move.bookmark_here(name, kind?)       -- drop a POI bookmark at current pos
--                                            so a sequencer step can recall it
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Plugin reference resolver.
--
-- The plugin used to be called StaticPatherPlugin.  After the rename to
-- WarPathPlugin we still want WarMachine to work with either:
--   * Newer bundles (only WarPathPlugin defined)
--   * Older bundles (only StaticPatherPlugin defined, no alias)
--   * The transition period (both defined as aliases of each other)
-- so resolve through a shim that re-checks each call -- the global may
-- not exist yet when this file is required, but will by the time
-- to_pos() actually fires.
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
-- Tier 2/3: position-based movement.
--
-- opts.arrive_radius    -- meters; default 3
-- opts.prefer_fallback  -- force tier 3 even when WarPath has data
--                          (useful when curated data is stale and the
--                          live mesh has changed)
-- opts.smooth           -- bool, default true: run centerline smoothing
--                          on the WarPath path.  Set false for exit-
--                          precision moves where hugging the wall is
--                          actually the goal (stepping ONTO a portal
--                          switch).
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
    local p = plugin()
    return p and p.is_zone_supported and p.is_zone_supported() or false
end

M.to_pos = function (goal, opts)
    -- Accept both signatures:
    --   move.to_pos(goal, { arrive_radius = 3.0, smooth = false })
    --   move.to_pos(goal, 3.0)                     -- legacy: number = arrive radius
    -- Several activity tasks (interact_poi.lua across nmd/pit/helltide/
    -- undercity) historically passed a number here.  Indexing into a
    -- number raises "attempt to index a number value", and because
    -- QQT swallows pulse errors silently, the calling task would stop
    -- progressing without a visible error -- e.g. NMD interact_poi
    -- would cycle forever with status='idle' as the user reported.
    -- Coerce here so old call sites keep working.
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

    -- Tier 2: WarPath + host pathfinder + centerline smoothing.
    -- find_path returns the full smoothed waypoint list; we drive the
    -- next 1-2 waypoints into the host's request_move so the bot
    -- follows the centerlined route instead of the wall-hugging
    -- direct path the host picks on its own.
    local p = plugin()
    if not opts.prefer_fallback and p and p.is_zone_supported and p.is_zone_supported() then
        if p.find_path then
            local find_opts = nil
            if opts.smooth == false then
                find_opts = { smooth = false }
            end
            local path = p.find_path(pp, goal, find_opts)
            if path and #path > 0 then
                -- Pick the FIRST node we haven't already passed.  Most
                -- of the time path[1] is the player's position -- in
                -- that case path[2] is the next real waypoint.  Falling
                -- back to path[1] handles the single-node "almost there"
                -- case.
                local next_node = path[2] or path[1]
                if next_node and pathfinder and pathfinder.request_move then
                    pathfinder.request_move(next_node)
                    return 'walking'
                end
            end
        end
        -- WarPath couldn't find a path; fall through to the walker.
    end

    -- Tier 3: internal walker.  Plans a host A* path to the goal and
    -- walks it node-by-node.  Borrows traversal-gizmo + trap-escape
    -- patterns from the deprecated Batmobile plugin without depending
    -- on the plugin itself.
    local walker = require 'core.walker'
    walker.set_target(goal)
    walker.tick()
    return 'walking'
end

-- ---------------------------------------------------------------------------
-- Convenience: try the live actor first, fall back to a known position
-- (typically the same actor's last-known coords from WarPath data).
-- ---------------------------------------------------------------------------
M.to_actor_or_pos = function (actor, fallback_pos, opts)
    if actor and M.to_actor(actor) == 'interacted' then return 'interacted' end
    if fallback_pos then return M.to_pos(fallback_pos, opts) end
    return 'no_actor'
end

-- ---------------------------------------------------------------------------
-- Stop / clear any in-flight movement.  Activity tasks call this when
-- they decide they're done with a target so the walker doesn't keep
-- driving the player.  (Tier 1/2 don't have stick-iness; only the
-- tier-3 walker maintains a target across calls.)
--
-- `caller` parameter retained for source-compat with old call sites
-- that passed a Batmobile-style caller string; ignored internally.
-- ---------------------------------------------------------------------------
M.clear = function (_caller)
    local walker = require 'core.walker'
    walker.stop()
end

-- ---------------------------------------------------------------------------
-- Cross-zone helpers (v2: built on WarPathPlugin.find_route).
-- ---------------------------------------------------------------------------

-- Returns an array of "go-here" steps to reach `target_zone` from the
-- player's current zone.  Each step is one of:
--   { kind='teleport', sno, to_zone, name }
--   { kind='walk',     in_zone, to_zone, via_actor = { skin, kind, x, y, z, sno_id } }
-- Returns nil + reason on unreachable.
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

-- Returns the actor coords in the CURRENT zone the bot should walk
-- to in order to make progress toward `target_zone`.  Use when an
-- activity already knows it wants to leave the current zone but
-- doesn't want to drive the whole multi-hop sequencer -- it just
-- needs "where do I walk next."  Returns nil when no portal is
-- known in the current zone heading toward target.
M.next_hop_actor = function (target_zone)
    local p = plugin()
    if not p or not p.next_hop_actor then return nil end
    local w = get_current_world()
    local cur = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if not cur then return nil end
    return p.next_hop_actor(cur, target_zone)
end

-- Drop a bookmark at the player's current position.  Caller-named so
-- they can recall it later via the sequencer's walk_to_bookmark step
-- or via WarPathPlugin.bookmark_nearest.  Useful for "I'll be back" --
-- e.g. "I saw the next-floor portal here while I was busy fighting,
-- come back when this room is clear."
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
        id   = id,
        zone = cur,
        x    = pp:x(),
        y    = pp:y(),
        z    = pp:z(),
        kind = kind,
        meta = meta,
    })
end

-- Recall a bookmarked POI.  `kind` filters to a specific kind of
-- bookmark (e.g. 'pit_floor_portal'); omit for any.  Returns the
-- bookmark table or nil.
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
