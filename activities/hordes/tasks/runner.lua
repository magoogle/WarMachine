-- activities/hordes/tasks/runner.lua

local tracker = require 'activities.hordes.tracker'

local R = {}

-- Order matters: first task whose shouldExecute() returns true wins.
-- Rationale per slot:
--   exit                  -- only fires on run-done (chests opened) or
--                            safety timeout; placed first so we stop
--                            engaging once the run is over.
--   interact_pylon        -- between-wave choice has a ~10s window;
--                            top combat priority when up.
--   interact_boss_portal  -- Bartuc/Council portal at end of waves;
--                            click-and-teleport to boss arena.
--   open_chest            -- boss-kill reward chests; clear all of them.
--   interact_aether       -- BSK_Structure_BonusAether mid-wave bonus.
--   kill_monster          -- engage everything else; tiered priority.
--   walk_boss_room        -- fallback when arena is empty (post-portal
--                            teleport, before boss spawns).
--   idle                  -- no-op terminator.
local TASK_FILES = {
    'exit',
    'interact_pylon',
    'interact_boss_portal',
    'open_chest',
    'interact_aether',
    'kill_monster',
    'walk_boss_room',
    'idle',
}

local tasks = {}
for _, name in ipairs(TASK_FILES) do
    local ok, t = pcall(require, 'activities.hordes.tasks.' .. name)
    if ok and t then tasks[#tasks + 1] = t
    else console.print('[Hordes] task load failed: ' .. name .. ' err=' .. tostring(t)) end
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
