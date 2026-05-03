-- ---------------------------------------------------------------------------
-- core/runner.lua
--
-- Factory for the standard activity runner pattern: load a list of
-- task modules, optionally insert the freeroam fallback before idle,
-- and run a priority-ordered pulse loop.  Replaces 6 nearly-identical
-- runner.lua files (boss / helltide / hordes / nmd / pit / undercity).
--
-- Each per-activity runner.lua becomes ~10 lines: a TASK_FILES list
-- and a M.make() call.  Activity-specific bits stay configurable via
-- options (idle-diag watchdog, freeroam suppression, custom pulse
-- interval).
--
-- API:
--
--   local runner = require 'core.runner'
--   local R = runner.make({
--       activity   = 'pit',                                  -- for the freeroam tag + log prefix
--       module_path = 'activities.pit.tasks',                -- where tasks live
--       tracker    = require 'activities.pit.tracker',
--       task_files = { 'exit', 'kill_monster', 'idle', ... },
--       freeroam   = true,                                   -- default true; false for hordes
--       settings   = require 'activities.pit.settings',      -- optional, for debug_mode gate
--       debug_idle = true,                                   -- default false
--       idle_log_s = 8,                                       -- default 8
--   })
--   return R    -- exposes R.pulse() + R.get_current_task()
--
-- Behavior:
--   * pulse() iterates task list; first task whose shouldExecute returns
--     true wins.  Falls through to idle when nothing fires.
--   * pulse_interval_s throttle (default 0.05s = 20 Hz) applies to
--     pulse() so the runner doesn't churn faster than gameplay needs.
--   * debug_idle prints a once-per-IDLE_LOG_S diagnostic dump while
--     stuck idle, listing each task's shouldExecute return + status,
--     plus zone + position.  Gated behind settings.debug_mode if
--     settings is provided -- otherwise always on.
-- ---------------------------------------------------------------------------

local make_freeroam = require 'core.freeroam'
local entry_portal  = require 'core.entry_portal'

local M = {}

local DEFAULT_PULSE_INTERVAL_S = 0.05
local DEFAULT_IDLE_LOG_S       = 8

-- Resolve the freeroam-fallback name based on the activity tag, e.g.
-- 'pit' -> 'warmachine_pit'.  Matches the labels every existing
-- runner used so the GUI label mapping in core/labels.lua keeps
-- working unchanged.
local function freeroam_tag(activity)
    return 'warmachine_' .. tostring(activity or 'unknown')
end

-- Internal: dump a one-line-per-task snapshot of "why did nothing
-- fire?" so an operator can debug stalled runs.  Cheap; only called
-- after IDLE_LOG_S of continuous idle.
local function log_idle_diag(activity, tasks)
    local lines = { '[' .. tostring(activity) .. '] runner idle diagnostic:' }
    for _, t in ipairs(tasks) do
        local ok, want = pcall(t.shouldExecute or function () return false end)
        local name   = t.name or '?'
        local status = t.status or '-'
        lines[#lines + 1] = string.format('  - %-22s shouldExecute=%s status=%s',
            name, tostring(ok and want), tostring(status))
    end
    local w = get_current_world()
    local zone = w and w.get_current_zone_name and w:get_current_zone_name() or '?'
    local lp = get_local_player()
    local pp = lp and lp:get_position() or nil
    lines[#lines + 1] = string.format('  zone=%s pos=%s', zone,
        pp and string.format('(%.1f,%.1f)', pp:x(), pp:y()) or 'nil')
    for _, l in ipairs(lines) do console.print(l) end
end

-- ---------------------------------------------------------------------------
-- Factory
-- ---------------------------------------------------------------------------
M.make = function (cfg)
    cfg = cfg or {}
    assert(cfg.activity,    'core.runner: cfg.activity is required (e.g. "pit")')
    assert(cfg.module_path, 'core.runner: cfg.module_path is required (e.g. "activities.pit.tasks")')
    assert(cfg.tracker,     'core.runner: cfg.tracker is required')
    assert(cfg.task_files,  'core.runner: cfg.task_files is required')

    local activity         = cfg.activity
    local module_path      = cfg.module_path
    local tracker          = cfg.tracker
    local task_files       = cfg.task_files
    local freeroam_enabled = cfg.freeroam ~= false
    local pulse_interval_s = cfg.pulse_interval_s or DEFAULT_PULSE_INTERVAL_S
    local debug_idle       = cfg.debug_idle == true
    local idle_log_s       = cfg.idle_log_s or DEFAULT_IDLE_LOG_S
    local settings         = cfg.settings

    -- Load task modules in declared order.  Failures get logged but
    -- don't abort the runner -- a typo'd task name shouldn't break the
    -- whole activity.
    local tasks = {}
    local log_prefix = '[' .. tostring(activity) .. ']'
    for _, name in ipairs(task_files) do
        local ok, t = pcall(require, module_path .. '.' .. name)
        if ok and t then
            tasks[#tasks + 1] = t
        else
            console.print(log_prefix .. ' task load failed: ' .. name ..
                ' err=' .. tostring(t))
        end
    end

    -- Insert freeroam fallback as the second-to-last task (i.e. just
    -- before idle).  This way exploration only fires when nothing
    -- else has work, keeping the priority semantics every activity
    -- expects.  Suppress for activities where freeroam is wrong --
    -- e.g. hordes (small fixed arena, would just thrash the
    -- pathfinder for no benefit).
    if freeroam_enabled then
        local idle_idx = #tasks
        if idle_idx > 0 then
            -- Insert AT idle_idx; idle (if present) shifts to idle_idx+1.
            table.insert(tasks, idle_idx, make_freeroam(freeroam_tag(activity)))
        else
            tasks[#tasks + 1] = make_freeroam(freeroam_tag(activity))
        end
    end

    -- Watchdog state.
    local last_pulse_t  = 0
    local idle_since_t  = nil
    local last_idle_log_t = 0

    local R = {}

    R.pulse = function ()
        local now = get_time_since_inject and get_time_since_inject() or 0
        if (now - last_pulse_t) < pulse_interval_s then return end
        last_pulse_t = now

        -- Pre-pulse: refresh the entry-portal exclusion snapshot for
        -- ANY active activity.  Cheap (one zone-name fetch + one
        -- position read on the rare zone-change frame; no-op
        -- otherwise).  Done here so individual tasks can consult
        -- `core.entry_portal.is_near_entry` without each runner
        -- having to remember to tick it.
        entry_portal.tick()

        for _, task in ipairs(tasks) do
            if task.shouldExecute and task.shouldExecute() then
                tracker.current_task = task
                if task.Execute then task:Execute() end
                idle_since_t = nil
                return
            end
        end

        -- All tasks declined.  Mark idle + (optional) diagnostic dump
        -- after sustained no-op time.
        if debug_idle then
            if not idle_since_t then idle_since_t = now end
            if (now - idle_since_t) > idle_log_s
               and (now - last_idle_log_t) >= idle_log_s
            then
                last_idle_log_t = now
                local debug_on = true
                if settings and settings.debug_mode == false then
                    debug_on = false
                end
                if debug_on then log_idle_diag(activity, tasks) end
            end
        end
        tracker.current_task = { name = 'idle', status = 'idle' }
    end

    R.get_current_task = function () return tracker.current_task end

    -- Expose the assembled task list for diagnostics (helps the idle
    -- diag in tests + lets sibling code probe what loaded).
    R._tasks = tasks

    return R
end

return M
