-- activities/undercity/tasks/exit.lua

local move     = require 'core.move'
local settings = require 'activities.undercity.settings'
local tracker  = require 'activities.undercity.tracker'

local task = { name = 'exit', status = 'idle', debounce_t = nil }

local function in_undercity()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and z:sub(1, #'X1_Undercity_') == 'X1_Undercity_'
end

local function find_warp_pad()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_ally_actors()) do
        if a:get_skin_name() == 'X1_Undercity_WarpPad' then return a end
    end
    return nil
end

task.shouldExecute = function ()
    if not in_undercity() then return false end
    if tracker.chest_looted and settings.exit_after_chest then return true end
    if find_warp_pad() then return true end
    if tracker.run_start_t
       and (tracker.run_start_t + settings.auto_reset_after) < get_time_since_inject()
    then return true end
    return false
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end

    -- Prefer warp pad when visible
    local warp = find_warp_pad()
    if warp then
        local pp = lp:get_position()
        local wp = warp:get_position()
        local d = math.sqrt((wp:x()-pp:x())^2 + (wp:y()-pp:y())^2)
        if d <= 2 then
            interact_object(warp)
            task.status = 'using warp pad'
            return
        end
        move.to_actor(warp)
        task.status = string.format('walking to warp pad (%.0fm)', d)
        return
    end

    -- No warp pad: dungeon reset
    local now = get_time_since_inject() or 0
    if task.debounce_t and (task.debounce_t + 5 > now) then
        task.status = 'reset issued, waiting'
        return
    end
    task.debounce_t = now
    if settings.debug_mode then console.print('[Undercity] reset_all_dungeons') end
    if reset_all_dungeons then reset_all_dungeons() end
    task.status = 'reset_all_dungeons'
end

return task
