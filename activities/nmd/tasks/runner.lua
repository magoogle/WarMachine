-- activities/nmd/tasks/runner.lua

local tracker = require 'activities.nmd.tracker'

local R = {}

local TASK_FILES = {
    'exit',                -- boss dead / dungeon_done / auto-reset
    'interact_poi',        -- objectives, chests, shrines
    'kill_monster',        -- fallback combat
    'idle',
}

local tasks = {}
for _, name in ipairs(TASK_FILES) do
    local ok, t = pcall(require, 'activities.nmd.tasks.' .. name)
    if ok and t then tasks[#tasks + 1] = t
    else console.print('[NMD] task load failed: ' .. name .. ' err=' .. tostring(t)) end
end

local last_pulse_t = 0
local PULSE_INTERVAL_S = 0.05

R.pulse = function ()
    local now = get_time_since_inject and get_time_since_inject() or 0
    if (now - last_pulse_t) < PULSE_INTERVAL_S then return end
    last_pulse_t = now
    for _, task in ipairs(tasks) do
        if task.shouldExecute and task.shouldExecute() then
            tracker.current_task = task
            if task.Execute then task:Execute() end
            return
        end
    end
    tracker.current_task = { name = 'idle', status = 'idle' }
end

R.get_current_task = function () return tracker.current_task end

return R
