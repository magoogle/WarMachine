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

local tracker    = require 'activities.pit.tracker'
local settings   = require 'activities.pit.settings'
local exit_grace = require 'core.exit_grace'

local task = { name = 'exit', status = 'idle', debounce_t = nil }

local function in_pit()
    local w = get_current_world()
    if not w or not w.get_name then return false end
    local n = w:get_name()
    return n and n:sub(1, 4) == 'PIT_'
end

task.shouldExecute = function ()
    if not in_pit() then return false end
    -- Run-complete triggers gate on the universal 15s loot grace
    -- (core.exit_grace.MIN_GRACE_S) so any post-kill drops have time
    -- to be picked up before we tear down.  The completion timestamp
    -- gets stamped where the latch flips (upgrade_glyph for glyph_done,
    -- the chest-loot path for chest_looted) -- here we only check it.
    if tracker.glyph_done then
        if exit_grace.has_elapsed(tracker.glyph_done_t) then return true end
        task.status = string.format('looting (%.0fs left)',
            exit_grace.remaining(tracker.glyph_done_t))
        return false
    end
    if tracker.chest_looted and settings.exit_after_chest then
        if exit_grace.has_elapsed(tracker.chest_looted_t) then return true end
        task.status = string.format('looting (%.0fs left)',
            exit_grace.remaining(tracker.chest_looted_t))
        return false
    end
    -- Safety timeout -- the auto_reset_after window covers any case
    -- where the run latch never flipped (boss death missed by tracker,
    -- glyph upgrade fizzled).  No grace gate here -- timeout means
    -- we're already well past any sensible loot window.
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
