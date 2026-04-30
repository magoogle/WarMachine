-- activities/undercity/tasks/interact_poi.lua

local move         = require 'core.move'
local tracker      = require 'activities.undercity.tracker'
local settings     = require 'activities.undercity.settings'
local poi_priority = require 'activities.undercity.poi_priority'

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

local task = {
    name = 'interact_poi', status = 'idle',
    interact_t = nil,
    target_key = nil,
}

local function next_target()
    local q = poi_priority.build(tracker, settings)
    for _, p in ipairs(q) do
        if p.kind ~= 'undercity_exit' then return p end
    end
    return nil
end

task.shouldExecute = function ()
    return next_target() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local target = next_target()
    if not target then task.status = 'no targets'; return end
    local target_key = string.format('%s:%d:%d',
        target.skin or '?', math.floor(target.x or 0), math.floor(target.y or 0))

    -- Restart timer if target changed
    if task.target_key ~= target_key then
        task.target_key = target_key
        task.interact_t = nil
    end

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

    -- In range.  Click + start timeout.  Enticements have a fixed wait
    -- window after click before we treat them as "done".
    local actor = live_actor_for(target)
    if not actor then
        tracker.mark_visited(target)
        task.target_key = nil
        task.interact_t = nil
        task.status = 'stale POI cleared'
        return
    end

    if target.kind == 'enticement' then
        local now = get_time_since_inject() or 0
        if not task.interact_t then
            task.interact_t = now
            if actor.is_interactable and actor:is_interactable() then
                if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
                interact_object(actor)
            end
            task.status = 'interacting (enticement)'
            return
        end
        if (now - task.interact_t) >= settings.enticement_timeout then
            -- Done waiting; mark visited + bump hearth_count if it was a hearth
            if target.skin and target.skin:find('SpiritHearth_Switch', 1, true) then
                tracker.hearth_count = tracker.hearth_count + 1
            end
            tracker.mark_visited(target)
            task.target_key = nil
            task.interact_t = nil
            if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(true) end
            task.status = 'enticement done'
            return
        end
        task.status = string.format('waiting %.1fs', settings.enticement_timeout - (now - task.interact_t))
        return
    end

    -- Generic interactable (chest / shrine / etc.)
    if actor.is_interactable and actor:is_interactable() then
        if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
        interact_object(actor)
        tracker.mark_visited(target)
        task.target_key = nil
        task.status = 'interacted: ' .. target.kind
    else
        task.status = 'POI not interactable yet'
    end
end

return task
