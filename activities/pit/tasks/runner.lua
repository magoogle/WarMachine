-- ---------------------------------------------------------------------------
-- activities/pit/tasks/runner.lua  --  task list dispatcher.
-- ---------------------------------------------------------------------------

local tracker = require 'activities.pit.tracker'

local R = {}

-- Order matters: highest priority first.
--   exit              -- terminal: chest looted or auto-reset triggered
--   upgrade_glyph     -- post-boss glyph UI sequence (final floor only)
--   floor_portal      -- descend via PortalSwitch / floor portal
--   interact_poi      -- chests, shrines, side objectives
--   kill_monster      -- combat (orbwalker handles auto-attack on the way too,
--                        so this only fires when no POI is in range)
--   enter_pit         -- standalone: open the pit portal in town
--   idle
local TASK_FILES = {
    'exit',
    'upgrade_glyph',
    'floor_portal',
    'interact_poi',
    'kill_monster',
    'enter_pit',
    'idle',
}

local tasks = {}
for _, name in ipairs(TASK_FILES) do
    local ok, t = pcall(require, 'activities.pit.tasks.' .. name)
    if ok and t then
        tasks[#tasks + 1] = t
    else
        console.print('[Pit] task load failed: ' .. name .. ' err=' .. tostring(t))
    end
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
