-- ---------------------------------------------------------------------------
-- WarMachine task manager (orchestrator-only).
-- Same shouldExecute/Execute contract as the sub-plugins.
-- ---------------------------------------------------------------------------

local task_manager = {}
local tasks        = {}
local current_task = { name = 'idle', status = nil }

task_manager.register_task = function (task)
    table.insert(tasks, task)
end

local last_call_time = 0.0
task_manager.execute_tasks = function ()
    local now = get_time_since_inject()
    if now - last_call_time < 0.05 then return end
    last_call_time = now

    for _, task in ipairs(tasks) do
        if task.shouldExecute() then
            current_task = task
            task:Execute()
            break
        end
    end

    current_task = current_task or { name = 'idle', status = nil }
end

task_manager.get_current_task = function ()
    return current_task
end

-- Priority order — first task whose shouldExecute() returns true wins.
local task_files = {
    -- Manual probes
    'warplan.test_confirm',     -- "dismiss confirm dialog" probe

    -- Triggered click sequences (fire on tracker pending flags)
    'warplan.test_select',      -- vendor menu click sequence
    'warplan.test_next_obj',    -- Tab + click Next-Obj button
    'warplan.turn_in',          -- walk to Tyrael + interact
    'warplan.start_cycle',      -- walk to Warplans_Vendor + interact

    -- Self-triggering town-side entry helpers (sub-plugin entry tasks
    -- gate on legacy zones, so WarMachine handles UC/Pit entry from Temis)
    'warplan.enter_undercity',  -- Undercity Obelisk + Open Portal
    'pit.enter',                -- Iron Wolves Pit-key Crafter + open + portal

    -- Sub-plugin orchestrator — enables the matching sub-plugin
    -- (SigilRunner / HelltideRevamped / WonderCity / ArkhamAsylum) when
    -- in the activity's runtime zone, disables on transition.
    'warplan.supervisor',

    -- War Plan top-level state machine (sets pending flags, fires next_obj
    -- / turn_in / start_cycle based on warplan state).
    'warplan.dispatch',

    -- Always last
    'shared.idle',
}

for _, file in ipairs(task_files) do
    local task = require('tasks.' .. file)
    task_manager.register_task(task)
end

return task_manager
