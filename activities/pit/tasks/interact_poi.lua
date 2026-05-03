-- ---------------------------------------------------------------------------
-- activities/pit/tasks/interact_poi.lua
--
-- Walk to + click the highest-priority POI in the queue.  POIs in pit
-- are mostly chests, shrines, side objectives, glyph gizmos --
-- pit_exit and pit_floor_portal live in tasks/floor_portal.lua and
-- get higher priority than this task.  This file fills the
-- "killing time on the floor while exploring" role.
--
-- Shared primitives (see core/poi_pick.lua, core/live_actor.lua):
--   * Reachability-filtered queue picker -- skip catalog entries the
--     host pathfinder can't currently route to (chest in a sealed-off
--     room, etc.).  Was the user-reported "wall-walking toward an
--     unreachable chest" symptom.
--   * Live-actor matcher -- catalog skin -> in-stream actor.
--
-- Pit-specific behavior layered on top:
--   * Whitelist filter (IN_PIT_POI_KINDS) -- skip town POIs that
--     showed up in the catalog scan but belong to enter_pit.
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local zone        = require 'core.zone'
local poi_pick    = require 'core.poi_pick'
local live_actor  = require 'core.live_actor'
local tracker     = require 'activities.pit.tracker'
local settings    = require 'activities.pit.settings'
local poi_priority = require 'activities.pit.poi_priority'

-- Whitelisted POI kinds for in-pit handling.  Town POIs (Pit-key
-- Crafter, Warplans Vendor, etc.) are deliberately excluded so this
-- task doesn't fight enter_pit / pit_obelisk over the same target.
local IN_PIT_POI_KINDS = {
    chest                 = true,
    chest_helltide_random = true,
    shrine                = true,
    objective             = true,
    glyph_gizmo           = true,
}

local INTERACT_RADIUS = 3.0

local picker = poi_pick.make_picker({
    budget        = 4,
    short_stale_s = 6.0,
})

local task = { name = 'interact_poi', status = 'idle' }

task.shouldExecute = function ()
    if not zone.in_pit() then return false end
    -- Cheap pre-check (no reach test); reach filter happens in Execute.
    local q = poi_priority.build(tracker, settings)
    return picker.pick(q, { kind_filter = IN_PIT_POI_KINDS }) ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local q = poi_priority.build(tracker, settings)
    local target = picker.pick(q, {
        kind_filter = IN_PIT_POI_KINDS,
        player_pos  = pp,
    })
    if not target then
        task.status = 'no reachable POI (exploring)'
        return
    end

    local dx = target.x - pp:x()
    local dy = target.y - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    if d > INTERACT_RADIUS then
        local actor = live_actor.find(target)
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

    local actor = live_actor.find(target)
    if not actor then
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
