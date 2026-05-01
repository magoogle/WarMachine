-- activities/hordes/tasks/exit.lua
--
-- Two trigger paths:
--   1) Run-complete: chest_opened=true AND no more chests visible AND a
--      grace window has passed since last chest click.  Sets run_done=true
--      and (in standalone mode) calls reset_all_dungeons so the next run
--      can start.  In WarPlan mode the supervisor reads run_done and
--      drives Next-Obj instead.
--   2) Safety-timeout: tracker.run_start_t + settings.auto_reset_after has
--      elapsed.  Catches stuck runs.
--
-- This is the LAST task in runner.lua's priority list -- pylon, portal,
-- chest, and combat all win first if they have work to do.

local settings    = require 'activities.hordes.settings'
local tracker     = require 'activities.hordes.tracker'
-- core.settings + core.mode let us tell standalone HORDES from WarPlan mode
-- so we only fire reset_all_dungeons in standalone (WarPlan drives Next-Obj
-- + Tyrael turn-in via task_manager).
local core_settings = require 'core.settings'
local core_mode     = require 'core.mode'

local task = { name = 'exit', status = 'idle', debounce_t = nil, last_chest_t = nil }

local CHEST_GRACE_S = 4    -- wait this long after last chest click before declaring done

local function in_hordes()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    -- S05_BSK_Prototype02 was the historical hordes zone; the season-7
    -- variants share the BSK_ prefix.
    return z and (z:find('BSK_', 1, true) ~= nil)
end

task.shouldExecute = function ()
    if not in_hordes() then return false end
    -- Path 1: run-complete handoff.  Drives off the open_chest task's
    -- chest_phase_done latch -- which only flips true once every enabled
    -- chest type is either successfully opened OR marked-failed
    -- (insufficient aether).  Old `chest_opened AND not chest_visible`
    -- was racy: chest_opened got set on first click attempt regardless
    -- of outcome, and chest_visible saw rejected chests as "still
    -- interactable" so the run never declared done after a rejected
    -- click.  See open_chest.lua header for the rewrite rationale.
    if tracker.chest_phase_done then
        return true
    end
    -- Path 2: safety timeout
    if tracker.run_start_t and settings.auto_reset_after
       and (tracker.run_start_t + settings.auto_reset_after) < (get_time_since_inject() or 0)
    then return true end
    return false
end

task.Execute = function ()
    local now = get_time_since_inject() or 0

    -- Run-complete branch: signal run_done so WarPlan can advance.  In
    -- standalone mode (no warplan_active), also call reset_all_dungeons
    -- to start the next run.
    if tracker.chest_phase_done then
        if not tracker.run_done then
            tracker.run_done = true
            if settings.debug_mode then console.print('[Hordes] run_done set; awaiting handoff') end
        end
        -- The WarPlan task_manager drives Next-Obj + Tyrael turn-in once
        -- the in-game quest objective updates (which D4 does within ~1s of
        -- the chest open).  In standalone mode no one else is watching, so
        -- we reset the dungeon ourselves to start the next run.
        local in_warplan = core_settings.mode == core_mode.WARPLAN
        if not in_warplan then
            if task.debounce_t and (task.debounce_t + 5 > now) then
                task.status = 'reset issued, waiting'
                return
            end
            task.debounce_t = now
            if settings.debug_mode then console.print('[Hordes] reset_all_dungeons (run-complete)') end
            if reset_all_dungeons then reset_all_dungeons() end
            task.status = 'reset_all_dungeons (run done)'
        else
            task.status = 'run_done; WarPlan handoff'
        end
        return
    end

    -- Safety-timeout branch
    if task.debounce_t and (task.debounce_t + 5 > now) then
        task.status = 'reset issued, waiting'
        return
    end
    task.debounce_t = now
    if settings.debug_mode then console.print('[Hordes] reset_all_dungeons (timeout)') end
    if reset_all_dungeons then reset_all_dungeons() end
    task.status = 'reset_all_dungeons (timeout)'
end

return task
