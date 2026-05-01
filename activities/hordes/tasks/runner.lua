-- activities/hordes/tasks/runner.lua

local tracker = require 'activities.hordes.tracker'

-- NOTE: hordes does NOT use core/freeroam (the embedded explorer).
-- The horde arena is small + fully catalogued by WarPath / StaticPather,
-- so explorer's frontier-search adds no value here and would just spam
-- pathfinder.calculate_and_get_path_points calls.  walk_boss_room
-- (quest-directed) is sufficient for the "no enemy in range" case.

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
    -- 'freeroam_fallback' inserted programmatically below (it's a factory)
    'idle',
}

local tasks = {}
for _, name in ipairs(TASK_FILES) do
    local ok, t = pcall(require, 'activities.hordes.tasks.' .. name)
    if ok and t then tasks[#tasks + 1] = t
    else console.print('[Hordes] task load failed: ' .. name .. ' err=' .. tostring(t)) end
end

-- (No freeroam fallback inserted -- hordes intentionally relies on
-- catalog data + walk_boss_room.  Adding the explorer here would
-- thrash pathfinder for no benefit on the tiny BSK arena.)

local last_pulse_t = 0
local PULSE_INTERVAL_S = 0.05

-- Watchdog: when we've been idle for IDLE_LOG_S, log it once with a
-- diagnostic dump so the operator knows WHY no task fired.  Reset on
-- every non-idle pulse.  The user reported "teleported in and just
-- stood there" -- this surfaces the cause (no enemies in stream, no
-- pylons, no portal, etc.) the next time it happens.
local idle_since_t   = nil
local last_idle_log_t = 0
local IDLE_LOG_S     = 8

local function log_idle_diag(now)
    -- Throttle the diag log to once every IDLE_LOG_S so a long idle
    -- doesn't spam the console.
    if (now - last_idle_log_t) < IDLE_LOG_S then return end
    last_idle_log_t = now
    -- Cheap snapshot of why each task said no.  We re-call shouldExecute
    -- and prefix with the task's name for visibility.
    local lines = { '[Hordes] runner idle diagnostic:' }
    for _, t in ipairs(tasks) do
        local ok, want = pcall(t.shouldExecute or function () return false end)
        local name = t.name or '?'
        local status = t.status or '-'
        lines[#lines + 1] = string.format('  - %-22s shouldExecute=%s status=%s',
            name, tostring(ok and want), tostring(status))
    end
    -- Add basic world state for context.
    local w = get_current_world()
    local zone = w and w.get_current_zone_name and w:get_current_zone_name() or '?'
    local lp = get_local_player()
    local pp = lp and lp:get_position() or nil
    lines[#lines + 1] = string.format('  zone=%s pos=%s', zone,
        pp and string.format('(%.1f,%.1f)', pp:x(), pp:y()) or 'nil')
    for _, l in ipairs(lines) do console.print(l) end
end

R.pulse = function ()
    local now = get_time_since_inject and get_time_since_inject() or 0
    if (now - last_pulse_t) < PULSE_INTERVAL_S then return end
    last_pulse_t = now
    for _, task in ipairs(tasks) do
        if task.shouldExecute and task.shouldExecute() then
            tracker.current_task = task
            if task.Execute then task:Execute() end
            idle_since_t = nil    -- reset watchdog on any non-idle pulse
            return
        end
    end
    -- All tasks declined this pulse.  Mark idle, and once we've been
    -- idle long enough, dump a diagnostic.  Helps catch "teleported in
    -- and just stood there" failure modes where the user has no
    -- visibility into which task chain broke.
    if not idle_since_t then idle_since_t = now end
    if (now - idle_since_t) > IDLE_LOG_S then
        local s_ok, s = pcall(require, 'activities.hordes.settings')
        if s_ok and s and s.debug_mode then log_idle_diag(now) end
    end
    tracker.current_task = { name = 'idle', status = 'idle' }
end

R.get_current_task = function () return tracker.current_task end

return R
