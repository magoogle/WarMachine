-- activities/undercity/tasks/floor_portal.lua  --  click X1_Undercity_PortalSwitch.

local move    = require 'core.move'
local tracker = require 'activities.undercity.tracker'

local task = { name = 'floor_portal', status = 'idle', last_interact_t = nil }

local PORTAL_SWITCH_SKIN = 'X1_Undercity_PortalSwitch'
local INTERACT_RANGE = 3.0

local function in_undercity()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and z:sub(1, #'X1_Undercity_') == 'X1_Undercity_'
end

local function find_switch()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_ally_actors()) do
        if a:is_interactable() and a:get_skin_name() == PORTAL_SWITCH_SKIN then
            return a
        end
    end
    return nil
end

local function update_world_tracking()
    if not in_undercity() then return end
    local w = get_current_world()
    local wid = w and w.get_world_id and w:get_world_id() or nil
    if not wid then return end
    if tracker.last_world_id and tracker.last_world_id ~= wid then
        tracker.current_floor = (tracker.current_floor or 1) + 1
        -- New floor -- reset visited dedup
        tracker.visited = {}
        tracker.poi_cache = nil
    end
    tracker.last_world_id = wid
end

task.shouldExecute = function ()
    update_world_tracking()
    if not in_undercity() then return false end
    if tracker.boss_seen then return false end   -- final floor: no descent
    return find_switch() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local switch = find_switch()
    if not switch then task.status = 'no switch'; return end
    local pp = lp:get_position()
    local sp = switch:get_position()
    local d = math.sqrt((sp:x()-pp:x())^2 + (sp:y()-pp:y())^2)
    if d <= INTERACT_RANGE then
        task.last_interact_t = get_time_since_inject()
        interact_object(switch)
        task.status = 'descending'
        return
    end
    move.to_actor(switch)
    task.status = string.format('walking to switch (%.0fm)', d)
end

return task
