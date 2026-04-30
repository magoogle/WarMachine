-- ---------------------------------------------------------------------------
-- activities/pit/tasks/exit.lua
--
-- Run termination: fires when the run is "done" (glyph upgrade complete,
-- chest looted, OR auto-reset timeout hit).  Standalone mode calls
-- reset_all_dungeons() to send us back to town for the next run.
--
-- WarMachine warplan mode: the supervisor / warplan dispatch handles
-- exit via Next-Obj instead, so this task is gated off via
-- settings.warmachine_mode (set externally by main.lua when warplan is
-- driving).  v1: always self-runs in standalone mode.
-- ---------------------------------------------------------------------------

local tracker  = require 'activities.pit.tracker'
local settings = require 'activities.pit.settings'

local task = { name = 'exit', status = 'idle', debounce_t = nil }

local function in_pit()
    local w = get_current_world()
    if not w or not w.get_name then return false end
    local n = w:get_name()
    return n and n:sub(1, 4) == 'PIT_'
end

task.shouldExecute = function ()
    if not in_pit() then return false end
    -- Exit triggers
    if tracker.glyph_done then return true end
    if tracker.chest_looted and settings.exit_after_chest then return true end
    if tracker.run_start_t
       and (tracker.run_start_t + settings.auto_reset_after) < get_time_since_inject()
    then
        return true
    end
    return false
end

task.Execute = function ()
    local now = get_time_since_inject() or 0
    if task.debounce_t and (task.debounce_t + 5 > now) then
        task.status = 'reset issued, waiting'
        return
    end
    task.debounce_t = now
    if settings.debug_mode then
        console.print('[Pit] reset_all_dungeons (run end)')
    end
    if reset_all_dungeons then reset_all_dungeons() end
    task.status = 'reset_all_dungeons'
end

return task
