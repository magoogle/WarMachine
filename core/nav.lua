-- ---------------------------------------------------------------------------
-- core/nav.lua
--
-- High-level "Go Here -> Do This -> Go Here" wrapper around WarPath's
-- sequencer.  Activity tasks call this for compound goals (multi-hop
-- cross-zone travel, "explore until X then walk to bookmark", ...)
-- instead of orchestrating individual move.to_pos calls themselves.
--
-- For SIMPLE in-zone movement, keep using core/move.lua.  Use nav
-- when you need:
--   * multi-hop cross-zone routes (zone graph from _links_index.json)
--   * "find a portal kind, fight while exploring, then take it"
--   * combat-coexistence (sequencer pauses while a guard returns true)
--   * abort-on-condition / on-complete callbacks
--
-- Falls back gracefully when WarPath isn't available -- the calls
-- return false + a reason string so the caller can drop to its own
-- legacy path-walk logic.
--
-- API:
--   nav.start(steps, opts)              -- raw passthrough to sequencer
--   nav.travel_to_zone(zone, opts)      -- multi-hop nav to a named zone
--   nav.find_and_take_portal(opts)      -- the pit-floor flow
--   nav.abort(reason?)
--   nav.is_active()
--   nav.status()
--   nav.set_combat_guard(fn)            -- shared with WarPath sequencer
-- ---------------------------------------------------------------------------

local move = require 'core.move'

local M = {}

local function plugin()
    return rawget(_G, 'WarPathPlugin')
        or rawget(_G, 'StaticPatherPlugin')
        or nil
end

local function require_plugin()
    local p = plugin()
    if not p then return nil, 'no_warpath_plugin' end
    if not p.start_goal then return nil, 'no_sequencer (old WarPath)' end
    return p
end

-- ---------------------------------------------------------------------------
-- nav.start(steps, opts)
--
-- Start an arbitrary sequencer goal.  Pass-through to WarPath; useful
-- for tasks that want to compose their own steps.  See sequencer.lua
-- for the supported step kinds:
--   walk_to / walk_to_actor / walk_to_bookmark / travel_to_zone
--   explore_until / interact / wait / callback
-- ---------------------------------------------------------------------------
M.start = function (steps, opts)
    local p, why = require_plugin()
    if not p then return false, why end
    return p.start_goal(steps, opts)
end

-- ---------------------------------------------------------------------------
-- nav.travel_to_zone(target_zone, opts)
--
-- Multi-hop cross-zone navigation via the zone graph.  Hands the
-- planner the target zone name; sequencer walks the bot through every
-- portal hop on the way (with teleport sub-steps when a known
-- waypoint is available).
--
-- opts:
--   on_teleport(ctx, sub)  -- caller-supplied: invoke
--                            teleport_to_waypoint(sub.sno) here.
--                            The host plugin probably exposes that
--                            differently per character; we don't
--                            issue the teleport ourselves.
--   on_arrive(ctx)         -- fires when current_zone == target_zone
--   on_abort(ctx, reason)
--   combat_guard(ctx)      -- bool fn; while true the sequencer pauses
-- ---------------------------------------------------------------------------
M.travel_to_zone = function (target_zone, opts)
    opts = opts or {}
    local p, why = require_plugin()
    if not p then return false, why end
    if opts.combat_guard then p.set_combat_guard(opts.combat_guard) end
    return p.start_goal({
        {
            kind         = 'travel_to_zone',
            target_zone  = target_zone,
            on_teleport  = opts.on_teleport,
            on_arrive    = opts.on_arrive,
            timeout_s    = opts.timeout_s or 300,
        },
    }, {
        on_complete = opts.on_complete,
        on_abort    = opts.on_abort,
    })
end

-- ---------------------------------------------------------------------------
-- nav.find_and_take_portal(opts)
--
-- The pit-floor flow, exactly as the user described:
--   1. Explore the current zone (room) until coverage_threshold is
--      reached, marking visited cells along the way.
--   2. Whenever the bot's actor catalog spots a `target_kind` actor
--      nearby, drop a bookmark at that position so we can recall it.
--   3. Once coverage is high enough AND a bookmark exists, walk to
--      the bookmarked portal and call interact_fn.
--
-- Critical: this does NOT handle combat.  WarMachine activities still
-- use their kill_monster task chain; they pass `combat_guard` so the
-- sequencer holds movement while the bot fights.
--
-- opts:
--   target_kind     = 'pit_floor_portal'  (or 'dungeon_entrance', 'pit_exit', etc.)
--   target_coverage = 0.7                  -- 0..1; explore until this fraction visited
--   interact_fn     = function (ctx) interact_object(...) end
--   combat_guard    = function (ctx) return mob_in_kill_range() end
--   on_complete     = function (ctx) ... end
--   on_abort        = function (ctx, reason) ... end
--   explore_timeout_s = 600 (10 min cap)
-- ---------------------------------------------------------------------------
M.find_and_take_portal = function (opts)
    opts = opts or {}
    local p, why = require_plugin()
    if not p then return false, why end
    if not p.find_and_take_portal then
        -- WarPath build is too old (sequencer is there but the
        -- prebuilt helper isn't).  Caller should fall back to
        -- their own seek-progression task.
        return false, 'no_find_and_take_portal'
    end
    return p.find_and_take_portal(opts)
end

-- ---------------------------------------------------------------------------
-- Status / lifecycle
-- ---------------------------------------------------------------------------

M.abort = function (reason)
    local p = plugin()
    if p and p.abort_goal then p.abort_goal(reason) end
end

M.is_active = function ()
    local p = plugin()
    if p and p.is_goal_active then return p.is_goal_active() end
    return false
end

M.status = function ()
    local p = plugin()
    if p and p.goal_status then return p.goal_status() end
    return { active = false }
end

M.set_combat_guard = function (fn)
    local p = plugin()
    if p and p.set_combat_guard then p.set_combat_guard(fn) end
end

-- ---------------------------------------------------------------------------
-- Capability check helpers -- caller can use these to decide whether
-- to invoke nav.* at all or fall through to legacy logic.
-- ---------------------------------------------------------------------------
M.has_warpath = function ()
    return plugin() ~= nil
end

M.has_sequencer = function ()
    local p = plugin()
    return p ~= nil and p.start_goal ~= nil
end

-- Tactical preload check.  When the bundled WarPath is fresh, the
-- preloader still has zones queued -- callers may want to defer
-- expensive work like activity start-up until the cache is warm.
M.preload_progress = function ()
    local p = plugin()
    if p and p.preload_stats then return p.preload_stats() end
    return { meta_zones = 0, nav_zones = 0, nav_pending = 0 }
end

return M
