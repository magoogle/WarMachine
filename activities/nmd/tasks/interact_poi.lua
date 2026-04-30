-- activities/nmd/tasks/interact_poi.lua

local move         = require 'core.move'
local tracker      = require 'activities.nmd.tracker'
local settings     = require 'activities.nmd.settings'
local poi_priority = require 'activities.nmd.poi_priority'

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

task.shouldExecute = function ()
    return #poi_priority.build(tracker, settings) > 0
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local q = poi_priority.build(tracker, settings)
    local target = q[1]
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
        if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
        interact_object(actor)
        tracker.mark_visited(target)
        task.status = 'interacted: ' .. target.kind
    else
        task.status = 'POI not interactable yet'
    end
end

return task
