-- ---------------------------------------------------------------------------
-- Task manager — same shouldExecute/Execute contract as SigilRunner et al.
-- Phase 1 registers only the idle no-op. Per-activity tasks register
-- themselves into the same list during Phase 2-5 ports.
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

-- Task registration order = priority. Highest priority first.
-- Phase 1 only registers the idle fallback. As activities are ported
-- (Phase 2-5) they prepend their tasks above 'shared.idle'.
-- Priority order — first task whose shouldExecute() returns true wins the
-- pulse. Test/click tasks run BEFORE the dispatcher so that pending flags
-- set by dispatch get serviced on the next pulse. Idle is always last.
local task_files = {
    -- Manual test buttons (fire once on click)
    'warplan.test_confirm',     -- "dismiss confirm dialog" probe

    -- Triggered actions (fire when their pending flag is set, by either
    -- the GUI test buttons or the dispatch task)
    'warplan.test_select',      -- vendor menu click sequence
    'warplan.test_next_obj',    -- Tab + click Next-Obj button
    'warplan.turn_in',          -- walk to Tyrael + interact
    'warplan.start_cycle',      -- walk to Warplans_Vendor + interact

    -- Self-triggering entry tasks (in town, mode-dependent)
    'warplan.enter_undercity',  -- Undercity Obelisk + Open Portal (WarPlan UC OR standalone UC)
    'nmd.use_sigil',            -- consume sigil + map-click (standalone NMD)
    'nmd.enter_portal',         -- walk into NMD entrance portal once it spawns

    -- Pit tasks (standalone Pit mode)
    'pit.exit',                 -- triggered first — exit conditions take priority over entry
    'pit.teleport_cerrigar',    -- tp to Cerrigar if not there + not in pit
    'pit.enter',                -- walk to Pit-key Crafter, open + enter portal

    -- Hordes stub (data discovery TBD)
    'hordes.dispatch',

    -- In-zone supervisor — mode-agnostic. Drives Batmobile auto-explore
    -- and objective targeting in the active activity's zone (NMD, Helltide,
    -- Undercity).
    'warplan.supervisor',

    -- War Plan top-level state machine — only active in War Plan mode.
    'warplan.dispatch',

    -- Always last
    'shared.idle',
}

for _, file in ipairs(task_files) do
    local task = require('tasks.' .. file)
    task_manager.register_task(task)
end

return task_manager
