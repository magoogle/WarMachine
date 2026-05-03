-- ---------------------------------------------------------------------------
-- activities/boss/api.lua
--
-- Boss summon-altar runs.  Architecture ported from the standalone Reaper
-- plugin (Current Scripts/Reaper) but flattened to the WarMachine activity
-- contract.
--
-- Two run modes:
--   1) WarPlan-driven -- WarPlan teleports us to a Boss_WT*_* zone for a
--      "kill <Boss>" objective; we run the in-zone state machine
--      (walk-altar -> click -> kill -> open-chest), set run_done,
--      WarPlan supervisor advances Next-Obj.
--   2) Standalone -- user picks 'BOSS' mode, manually teleports to a
--      boss zone (or sets a target via an external rotation).  Same
--      state machine fires; on run_done we reset_all_dungeons so the
--      next run is ready when they teleport back in.
--
-- Materials / rotation / boss-selection-vendor logic from Reaper is
-- intentionally NOT ported in this commit -- WarPlan owns activity
-- selection.  A standalone rotation can be added later if you want
-- automatic multi-boss farming without WarPlan.
-- ---------------------------------------------------------------------------

local mount_manager = require 'core.mount_manager'
local settings_mod  = require 'activities.boss.settings'
local tracker       = require 'activities.boss.tracker'
local boss_data     = require 'activities.boss.data.boss_data'
local runner        = require 'activities.boss.tasks.runner'

local M = {}

M.tag   = 'boss'
M.label = 'Boss'

M.is_loaded = function () return true end

local core_mode = require 'core.mode'

local function in_boss_zone()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    return boss_data.zone_matches(w:get_current_zone_name())
end

-- One-time diagnostics. Set TRUE on first call; the trace prints fire
-- only on the first call so we don't spam the console mid-run. Used to
-- diagnose "boss is dispatched but runner never pulses" cases.
local _se_diagnosed   = false
local _pulse_diagnosed = false

M.shouldExecute = function ()
    local result
    -- WarPlan path: only engage when WarPlan teleported us into a boss
    -- zone.  WarPlan dispatch handles transit; activity_manager only
    -- fires in-zone gameplay.
    if core_mode.is_warplan() then
        result = in_boss_zone()
    -- Standalone Boss mode: also fire when the player has the activity
    -- selected but isn't in any boss zone yet -- select_boss takes the
    -- pulse and teleports.  Otherwise we'd never get out of Cerrigar.
    elseif core_mode.is(core_mode.BOSS) then
        result = true
    else
        -- Other standalone modes: don't engage
        result = in_boss_zone()
    end
    if not _se_diagnosed then
        _se_diagnosed = true
        local cs = require 'core.settings'
        console.print(string.format(
            '[Boss/diag] shouldExecute first-call: result=%s settings.mode=%s is_warplan=%s is_BOSS=%s in_boss_zone=%s',
            tostring(result), tostring(cs.mode),
            tostring(core_mode.is_warplan()),
            tostring(core_mode.is(core_mode.BOSS)),
            tostring(in_boss_zone())))
    end
    return result
end

M.pulse = function ()
    if not _pulse_diagnosed then
        _pulse_diagnosed = true
        console.print('[Boss/diag] pulse first-call reached')
    end
    settings_mod.update()
    -- Mounting disabled in boss rooms: tight space + constant combat.
    -- Helltide is the only activity exposing the mount option.
    mount_manager.update({ disabled = true, allow_mount = false })
    runner.pulse()
end

M.get_status = function ()
    local cur = tracker.current_task or {}
    return {
        task             = cur.name or 'idle',
        status           = cur.status,
        altar_seen       = tracker.altar_seen,
        altar_activated  = tracker.altar_activated,
        chest_opened     = tracker.chest_opened,
        run_done         = tracker.run_done,
    }
end

M.activate = function ()
    tracker.reset_run()
    -- Silence the legacy external Reaper plugin if it's still installed --
    -- otherwise its on_update would fight us for control.  No-op if not
    -- loaded (most users won't have ReaperPlugin globally registered).
    if ReaperPlugin and ReaperPlugin.disable then
        pcall(ReaperPlugin.disable)
    end
end

M.deactivate = function ()
    local ok, walker = pcall(require, 'core.walker')
    if ok and walker and walker.stop then walker.stop() end
end

return M
