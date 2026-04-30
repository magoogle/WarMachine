-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/runner.lua  --  task list dispatcher.
--
-- One pulse = first task in the priority list whose shouldExecute() returns
-- true gets to run.  Each task has the same contract as the WarMachine
-- top-level task_manager:
--
--   task = { name, status, shouldExecute(), Execute() }
--
-- The list is small on purpose -- the heavy lifting (which POI, which
-- enemy) is in poi_priority.lua + per-task logic, not in priority chains.
-- ---------------------------------------------------------------------------

local tracker = require 'activities.helltide.tracker'

local R = {}

-- Order matters: highest priority first.  See per-task files for what each
-- does.  Priorities chosen so combat happens during travel (orbwalker
-- auto-attacks while we walk to a POI), not as the dominant behavior.
local TASK_FILES = {
    'return_to_zone',     -- recovery if we wandered out of the helltide ring
    'maiden',             -- maiden event takes over when active
    'interact_poi',       -- the main event: walk to + click the highest-prio POI
                          -- (the priority queue handles cinder affordability:
                          -- unaffordable Tortured Gifts are filtered out, the
                          -- bot moves on to the next-best POI; once cinders
                          -- accumulate from kills along the way, the chest
                          -- becomes top-priority again automatically)
    'kill_monster',       -- fallback combat when nothing in the priority list
    'idle',
}

local tasks = {}
for _, name in ipairs(TASK_FILES) do
    local ok, t = pcall(require, 'activities.helltide.tasks.' .. name)
    if ok and t then
        tasks[#tasks + 1] = t
    else
        console.print('[Helltide] task load failed: ' .. name .. ' err=' .. tostring(t))
    end
end

-- Throttle so we don't spam clicks every frame
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

R.get_current_task = function ()
    return tracker.current_task
end

return R
