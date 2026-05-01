-- ---------------------------------------------------------------------------
-- activities/pit/tasks/interact_poi.lua
--
-- Walk to + click the highest-priority POI in the queue.  POIs in pit are
-- mostly chests, shrines, and side objectives -- pit_exit/pit_floor_portal
-- are HIGHER priority and live in tasks/floor_portal.lua, so they get
-- handled there.  This task fills the "killing time on the floor while
-- exploring" role.
-- ---------------------------------------------------------------------------

local move         = require 'core.move'
local zone         = require 'core.zone'
local tracker      = require 'activities.pit.tracker'
local settings     = require 'activities.pit.settings'
local poi_priority = require 'activities.pit.poi_priority'

-- Whitelisted POI kinds that this task is responsible for handling
-- INSIDE pit floors.  Town-side POIs (`pit_obelisk`, `warplans_vendor`,
-- `tyrael`, `npc`, `stash`, `waypoint`, etc.) are deliberately NOT in
-- this list -- those are `enter_pit`'s job and would otherwise get
-- picked here, walked to, fail live_actor_for's strict 8m check, and
-- marked visited (user-reported "stale POI cleared looking for
-- objective" while standing next to the Pit-key Crafter).
local IN_PIT_POI_KINDS = {
    chest                 = true,
    chest_helltide_random = true,
    shrine                = true,
    objective             = true,
    glyph_gizmo           = true,
}

local INTERACT_RADIUS = 3.0

local function live_actor_for(poi)
    if not actors_manager or not actors_manager.get_ally_actors then return nil end
    local best, best_d = nil, math.huge
    for _, a in pairs(actors_manager:get_ally_actors()) do
        local sn = a:get_skin_name()
        if sn == poi.skin then
            local p = a:get_position()
            if p then
                local dx = p:x() - (poi.x or 0)
                local dy = p:y() - (poi.y or 0)
                local d2 = dx*dx + dy*dy
                if d2 < 64 and d2 < best_d then best, best_d = a, d2 end
            end
        end
    end
    return best
end

local task = { name = 'interact_poi', status = 'idle' }

-- Keep this task OUT of the pit_exit / pit_floor_portal handling -- those
-- get their own task.  Whitelist filter to only allowed in-pit POI kinds
-- (chest / shrine / objective / glyph_gizmo).  Town POIs are skipped.
local function next_target()
    local q = poi_priority.build(tracker, settings)
    for _, p in ipairs(q) do
        if IN_PIT_POI_KINDS[p.kind or ''] then
            return p
        end
    end
    return nil
end

task.shouldExecute = function ()
    -- Only fire INSIDE pit floors.  In Skov_Temis (the hub) `enter_pit`
    -- handles the Pit-key Crafter + portal flow; this task would just
    -- pull town POIs and stand confused.
    if not zone.in_pit() then return false end
    return next_target() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local target = next_target()
    if not target then task.status = 'no targets'; return end

    local dx = target.x - pp:x()
    local dy = target.y - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    if d > INTERACT_RADIUS then
        local actor = live_actor_for(target)
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

    local actor = live_actor_for(target)
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
