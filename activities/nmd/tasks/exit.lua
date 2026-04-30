-- activities/nmd/tasks/exit.lua

local settings = require 'activities.nmd.settings'
local tracker  = require 'activities.nmd.tracker'

local task = { name = 'exit', status = 'idle', debounce_t = nil }

local function in_dungeon()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and z:sub(1, 4) == 'DGN_'
end

task.shouldExecute = function ()
    if not in_dungeon() then return false end
    -- Trigger after boss kill if exit_after_boss is on, or when dungeon_done
    -- is latched by some other task, or auto-reset timeout
    if settings.exit_after_boss and tracker.boss_killed_at then return true end
    if tracker.dungeon_done then return true end
    if tracker.run_start_t
       and (tracker.run_start_t + settings.auto_reset_after) < get_time_since_inject()
    then return true end
    return false
end

task.Execute = function ()
    local now = get_time_since_inject() or 0
    if task.debounce_t and (task.debounce_t + 5 > now) then
        task.status = 'reset issued, waiting'
        return
    end
    task.debounce_t = now
    if settings.debug_mode then console.print('[NMD] reset_all_dungeons') end
    if reset_all_dungeons then reset_all_dungeons() end
    task.status = 'reset_all_dungeons'
end

return task
