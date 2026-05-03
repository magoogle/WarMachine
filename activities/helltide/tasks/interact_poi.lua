-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/interact_poi.lua
--
-- Walk to + click the highest-priority POI in the queue: chests,
-- ores, herbs, shrines, pyres, world-event triggers.  Movement uses
-- core.move's tiered fallback (host pathfinder when WarPath has data,
-- internal walker otherwise).
--
-- Shared primitives (see core/poi_pick.lua, core/live_actor.lua):
--   * Reachability filter on the queue picker (skip catalog entries
--     the host pathfinder can't currently route to)
--   * Live-actor matcher with helltide-specific Pyre fallback (see
--     extra_match below) so a catalog-stamped Pyre POI still finds
--     a runtime Pyre_Helltide_* live actor.
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local poi_pick    = require 'core.poi_pick'
local live_actor  = require 'core.live_actor'
local tracker     = require 'activities.helltide.tracker'
local settings    = require 'activities.helltide.settings'
local poi_priority = require 'activities.helltide.poi_priority'

local task = { name = 'interact_poi', status = 'idle' }

local INTERACT_RADIUS = 3.0

local picker = poi_pick.make_picker({
    budget        = 4,
    short_stale_s = 6.0,
})

-- Helltide-specific live-actor extra-match.  When the catalog says
-- kind='pyre' but the runtime skin is some Pyre_Helltide_* variant
-- the recorder didn't capture verbatim, accept any skin substring-
-- matching 'Pyre_Helltide'.
local function helltide_pyre_fallback(live_skin, poi)
    if poi.kind ~= 'pyre' then return false end
    return live_skin and live_skin:find('Pyre_Helltide', 1, true) ~= nil
end

local function find_helltide_actor(poi)
    return live_actor.find(poi, {
        scan_lists  = 'ally',         -- helltide POIs are ally-only
        match_mode  = 'exact',        -- catalog skin = runtime skin almost always
        extra_match = helltide_pyre_fallback,
    })
end

task.shouldExecute = function ()
    -- Yield to higher-priority tasks; this fires whenever we have ANY POI
    -- in the queue (which is most of the time during a helltide hour).
    local q = poi_priority.build(tracker, settings, tracker.in_maiden)
    return picker.pick(q) ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local q = poi_priority.build(tracker, settings, tracker.in_maiden)
    local target = picker.pick(q, { player_pos = pp })
    if not target then
        task.status = 'no reachable POI (exploring)'
        return
    end

    local dx = target.x - pp:x()
    local dy = target.y - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    if d > INTERACT_RADIUS then
        local actor = find_helltide_actor(target)
        if actor then
            move.to_actor(actor)
            task.status = string.format('walking to %s (%.0fm)', target.kind, d)
        else
            local goal = vec3:new(target.x, target.y, target.z or pp:z())
            move.to_pos(goal, INTERACT_RADIUS)
            task.status = string.format('routing to %s (%.0fm)', target.kind, d)
        end
        return
    end

    -- Within interact radius.
    local actor = find_helltide_actor(target)
    if not actor then
        if settings.debug_mode then
            console.print(string.format(
                '[Helltide] POI %s @(%.1f,%.1f) had no live actor -- marking visited',
                target.kind, target.x, target.y))
        end
        tracker.mark_visited(target)
        task.status = 'stale POI cleared'
        return
    end

    if actor.is_interactable and actor:is_interactable() then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(actor)
        tracker.mark_visited(target)
        task.status = 'interacted: ' .. target.kind
    else
        task.status = 'POI not interactable yet'
    end
end

return task
