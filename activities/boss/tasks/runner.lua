-- activities/boss/tasks/runner.lua

local tracker        = require 'activities.boss.tracker'
local make_freeroam  = require 'core.freeroam'

local R = {}

-- Priority chain.  Order matters; each task's shouldExecute() decides
-- whether to claim the pulse.
--   select_boss       -- standalone-only: teleport to the next boss in the
--                        rotation.  WarPlan mode short-circuits this so it
--                        doesn't fight WarPlan's Next-Obj clicks.
--   exit              -- run-complete (chest opened) or safety timeout
--   interact_altar    -- click the summon altar
--   open_chest        -- post-kill reward chest
--   kill_monster      -- engage boss + adds + suppressors
--   walk_boss_room    -- anchor when arena's empty (post-altar, pre-spawn)
--   freeroam_fallback -- Batmobile freeroam if nothing else fires
--   idle
local TASK_FILES = {
    'select_boss',
    'exit',
    'interact_altar',
    'open_chest',
    'kill_monster',
    'walk_boss_room',
    -- 'freeroam_fallback' inserted programmatically below
    'idle',
}

local tasks = {}
for _, name in ipairs(TASK_FILES) do
    local ok, t = pcall(require, 'activities.boss.tasks.' .. name)
    if ok and t then tasks[#tasks + 1] = t
    else console.print('[Boss] task load failed: ' .. name .. ' err=' .. tostring(t)) end
end

-- Insert the Batmobile freeroam fallback just before idle, same pattern
-- as the other activities.  Useful if the bot lands in a boss zone
-- without an altar in stream yet (briefly, post-teleport) -- Batmobile
-- explores until it gets close enough to spot the altar.
local idle_idx = #tasks
table.insert(tasks, idle_idx, make_freeroam('warmachine_boss'))

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
