-- activities/undercity/tasks/runner.lua  --  task list dispatcher.

local tracker        = require 'activities.undercity.tracker'
local make_freeroam  = require 'core.freeroam'

local R = {}

local TASK_FILES = {
    'exit',                -- chest looted / auto-reset / warp pad ready
    'goto_chest',          -- attunement chest after boss kill
    'interact_enticement', -- live-stream SpiritHearth/Beacon clicks.
                           -- Higher priority than floor_portal so we
                           -- consume enticements BEFORE descending.
    'floor_portal',        -- descend via X1_Undercity_PortalSwitch
    'interact_poi',        -- enticements, shrines, side chests (catalog)
    'kill_monster',        -- fallback combat
    'enter_undercity',     -- standalone: town brazier flow
    'idle',
}

local tasks = {}
for _, name in ipairs(TASK_FILES) do
    local ok, t = pcall(require, 'activities.undercity.tasks.' .. name)
    if ok and t then tasks[#tasks + 1] = t
    else console.print('[Undercity] task load failed: ' .. name .. ' err=' .. tostring(t)) end
end

-- Batmobile freeroam fallback: keeps the bot exploring when no enticement /
-- chest / portal switch is in actor stream (sparse data zones, between
-- engagements).  Priority-wise: enter-undercity standalone fires first
-- when in town, then the in-zone tasks, then this catches everything
-- else before idle.
local idle_idx = #tasks
table.insert(tasks, idle_idx, make_freeroam('warmachine_undercity'))

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
