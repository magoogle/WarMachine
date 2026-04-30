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

local function in_boss_zone()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    return boss_data.zone_matches(w:get_current_zone_name())
end

M.shouldExecute = function ()
    return in_boss_zone()
end

M.pulse = function ()
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
    if BatmobilePlugin and BatmobilePlugin.resume then
        pcall(BatmobilePlugin.resume, 'warmachine_boss')
    end
    -- Silence the legacy external Reaper plugin if it's still installed --
    -- otherwise its on_update would fight us for control.  No-op if not
    -- loaded (most users won't have ReaperPlugin globally registered).
    if ReaperPlugin and ReaperPlugin.disable then
        pcall(ReaperPlugin.disable)
    end
end

M.deactivate = function ()
    if BatmobilePlugin and BatmobilePlugin.clear_target then
        pcall(BatmobilePlugin.clear_target, 'warmachine_boss')
    end
end

return M
