-- ---------------------------------------------------------------------------
-- activities/pit/api.lua
--
-- Activity contract entry point.  The activity_manager picks this up
-- when settings.mode == PIT (standalone) or when WarPlan's active
-- activity is 'pit'.
-- ---------------------------------------------------------------------------

local mount_manager = require 'core.mount_manager'
local settings_mod  = require 'activities.pit.settings'
local tracker       = require 'activities.pit.tracker'
local runner        = require 'activities.pit.tasks.runner'

local M = {}

M.tag   = 'pit'
M.label = 'Pit'

M.is_loaded = function () return true end

local function in_pit()
    local w = get_current_world()
    if not w or not w.get_name then return false end
    local n = w:get_name()
    return n and n:sub(1, 4) == 'PIT_'
end

local function in_pit_hub()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    return w:get_current_zone_name() == 'Skov_Temis'
end

M.shouldExecute = function ()
    -- Standalone PIT mode: fire either when we're in a pit (do the run)
    -- or when we're in the hub (open the next pit).  WarPlan mode uses
    -- the existing WarMachine task_manager path so this can stay broad.
    return in_pit() or in_pit_hub()
end

M.pulse = function ()
    settings_mod.update()

    -- Mounting is intentionally disabled in Pit: floors are short, mount
    -- churn (pre-engage dismount + post-engage remount) hurts more than
    -- it helps.  Helltide is the only activity where mounting between
    -- POIs is a net win.  Keep mount_manager engaged but always-disabled
    -- so any prior mount state from another activity gets cleared.
    mount_manager.update({ disabled = true, allow_mount = false })

    runner.pulse()
end

M.get_status = function ()
    local cur = tracker.current_task or {}
    return {
        task          = cur.name or 'idle',
        status        = cur.status,
        floor         = tracker.current_floor,
        boss_seen     = tracker.boss_seen,
        boss_killed_at = tracker.boss_killed_at,
        glyph_done    = tracker.glyph_done,
        chest_looted  = tracker.chest_looted,
    }
end

M.activate = function ()
    tracker.reset_run()
    if BatmobilePlugin and BatmobilePlugin.resume then
        pcall(BatmobilePlugin.resume, 'warmachine_pit')
    end
    -- Silence the legacy external plugin if it's still installed -- otherwise
    -- ArkhamAsylum's own on_update hook keeps trying to run pit gameplay
    -- alongside us, both bots fighting for control.  No-op if not loaded.
    if ArkhamAsylumPlugin and ArkhamAsylumPlugin.disable then
        pcall(ArkhamAsylumPlugin.disable)
    end
end

M.deactivate = function ()
    if BatmobilePlugin and BatmobilePlugin.clear_target then
        pcall(BatmobilePlugin.clear_target, 'warmachine_pit')
    end
end

return M
