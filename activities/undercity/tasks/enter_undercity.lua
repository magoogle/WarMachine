-- activities/undercity/tasks/enter_undercity.lua  --  Skov_Temis brazier flow.

local move    = require 'core.move'
local tracker = require 'activities.undercity.tracker'

local task = { name = 'enter_undercity', status = 'idle', interacted = false }

local TOWN_ZONES = { ['Skov_Temis'] = true, ['Naha_Kurast'] = true }

local function in_a_town()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    return TOWN_ZONES[w:get_current_zone_name()] == true
end

local function in_undercity()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and z:sub(1, #'X1_Undercity_') == 'X1_Undercity_'
end

local function find_actor(skin, require_interactable)
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_ally_actors()) do
        if a:get_skin_name() == skin then
            if not require_interactable or (a.is_interactable and a:is_interactable()) then
                return a
            end
        end
    end
    return nil
end

task.shouldExecute = function ()
    if in_undercity() then return false end
    return in_a_town()
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    -- 1. Already-spawned portal? Walk in, fresh-run trigger.
    local portal = find_actor('Portal_Dungeon_Undercity', true)
    if portal then
        local p = portal:get_position()
        local d = math.sqrt((p:x()-pp:x())^2 + (p:y()-pp:y())^2)
        if d <= 2 then
            interact_object(portal)
            tracker.reset_run()
            task.interacted = false
            task.status = 'entering portal'
        else
            move.to_actor(portal)
            task.status = string.format('walking to portal (%.0fm)', d)
        end
        return
    end

    -- 2. Walk to brazier + open menu (user clicks through tribute UI manually
    --    until we port the bargain flow proper).
    local brazier = find_actor('Aubrie_Test_Undercity_Crafter', false)
    if not brazier then
        task.status = 'no brazier in stream'
        return
    end
    local bp = brazier:get_position()
    local bd = math.sqrt((bp:x()-pp:x())^2 + (bp:y()-pp:y())^2)
    if bd > 3 then
        move.to_actor(brazier)
        task.status = string.format('walking to brazier (%.0fm)', bd)
        return
    end

    if loot_manager and not loot_manager:is_in_vendor_screen() and not task.interacted then
        interact_object(brazier)
        task.status = 'opening obelisk'
        return
    end

    if loot_manager and not loot_manager:is_in_vendor_screen() then
        task.status = 'waiting for menu'
        return
    end

    task.interacted = true
    task.status = 'awaiting manual UI confirmation (v0.2 will automate)'
end

return task
