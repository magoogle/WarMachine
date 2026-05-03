-- activities/undercity/tasks/goto_chest.lua  --  attunement chest after boss.

local move    = require 'core.move'
local tracker = require 'activities.undercity.tracker'

local task = { name = 'goto_chest', status = 'idle' }

local CHEST_PATTERN = 'X1_Undercity_Chest_Attunement'

local function find_chest()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_ally_actors()) do
        local sn = a:get_skin_name()
        if sn and sn:find(CHEST_PATTERN, 1, true) then return a end
    end
    return nil
end

task.shouldExecute = function ()
    if tracker.chest_looted then return false end
    return find_chest() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local chest = find_chest()
    if not chest then task.status = 'no chest'; return end
    local pp = lp:get_position()
    local cp = chest:get_position()
    local d = math.sqrt((cp:x()-pp:x())^2 + (cp:y()-pp:y())^2)
    if d <= 3 then
        if chest.is_interactable and chest:is_interactable() then
            interact_object(chest)
        end
        if not tracker.chest_looted then
            tracker.chest_looted   = true
            tracker.chest_looted_t = get_time_since_inject() or 0
        end
        task.status = 'opened chest'
        return
    end
    move.to_actor(chest)
    task.status = string.format('walking to chest (%.0fm)', d)
end

return task
