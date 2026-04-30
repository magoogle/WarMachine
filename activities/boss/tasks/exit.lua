-- activities/boss/tasks/exit.lua
--
-- Two trigger paths (parallels activities/hordes/tasks/exit):
--   1) Run-complete: chest_opened=true AND no more chests visible AND
--      a chest_grace_secs window has passed since the click.  Sets
--      run_done=true.  Standalone -> reset_all_dungeons + tp Cerrigar
--      so the next manual run is ready.  WarPlan -> just signal;
--      supervisor advances Next-Obj.
--   2) Safety-timeout: tracker.run_start_t + auto_reset_after has
--      elapsed.  Catches stuck runs.

local settings  = require 'activities.boss.settings'
local tracker   = require 'activities.boss.tracker'
local boss_data = require 'activities.boss.data.boss_data'
-- Mode lookup so we know whether to fire reset_all_dungeons (standalone)
-- or just signal run_done (WarPlan supervisor handles transit).
local core_settings = require 'core.settings'
local core_mode     = require 'core.mode'

local task = { name = 'exit', status = 'idle', debounce_t = nil }

local function chest_visible()
    if not actors_manager or not actors_manager.get_all_actors then return false end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a.is_interactable and a:is_interactable() and boss_data.is_reward_chest(a) then
            return true
        end
    end
    return false
end

task.shouldExecute = function ()
    -- Run-complete handoff (preferred path)
    if tracker.chest_opened and not chest_visible() then
        local now = get_time_since_inject() or 0
        if tracker.chest_opened_t
           and (now - tracker.chest_opened_t) >= settings.chest_grace_secs
        then return true end
    end
    -- Safety timeout
    if tracker.run_start_t and settings.auto_reset_after
       and (tracker.run_start_t + settings.auto_reset_after) < (get_time_since_inject() or 0)
    then return true end
    return false
end

task.Execute = function ()
    local now = get_time_since_inject() or 0
    -- Run-complete branch
    if tracker.chest_opened and not chest_visible() then
        if not tracker.run_done then
            tracker.run_done = true
            if settings.debug_mode then console.print('[Boss] run_done set; awaiting handoff') end
        end
        local in_warplan = core_settings.mode == core_mode.WARPLAN
        if not in_warplan then
            if task.debounce_t and (task.debounce_t + 5 > now) then
                task.status = 'reset issued, waiting'
                return
            end
            task.debounce_t = now
            if settings.debug_mode then console.print('[Boss] reset_all_dungeons + tp Cerrigar') end
            if reset_all_dungeons then reset_all_dungeons() end
            if teleport_to_waypoint and boss_data.CERRIGAR_WAYPOINT_ID then
                teleport_to_waypoint(boss_data.CERRIGAR_WAYPOINT_ID)
            end
            task.status = 'reset_all_dungeons (run done)'
        else
            task.status = 'run_done; WarPlan handoff'
        end
        return
    end
    -- Safety-timeout branch
    if task.debounce_t and (task.debounce_t + 5 > now) then
        task.status = 'reset issued, waiting'
        return
    end
    task.debounce_t = now
    if settings.debug_mode then console.print('[Boss] reset_all_dungeons (timeout)') end
    if reset_all_dungeons then reset_all_dungeons() end
    task.status = 'reset_all_dungeons (timeout)'
end

return task
