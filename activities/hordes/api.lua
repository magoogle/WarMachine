-- activities/hordes/api.lua

local mount_manager = require 'core.mount_manager'
local settings_mod  = require 'activities.hordes.settings'
local tracker       = require 'activities.hordes.tracker'
local runner        = require 'activities.hordes.tasks.runner'

local M = {}

M.tag   = 'hordes'
M.label = 'Hordes'

M.is_loaded = function () return true end

local function in_hordes()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and (z:find('BSK_', 1, true) ~= nil)
end

M.shouldExecute = function ()
    return in_hordes()
end

M.pulse = function ()
    settings_mod.update()
    -- Mounting disabled: small arena, constant combat -- mount churn is
    -- always a net loss here.  Only Helltide uses auto-mount.
    mount_manager.update({ disabled = true, allow_mount = false })
    runner.pulse()
end

M.get_status = function ()
    local cur = tracker.current_task or {}
    return {
        task                 = cur.name or 'idle',
        status               = cur.status,
        wave                 = tracker.current_wave,
        last_pylon_pick      = tracker.last_pylon_pick,
        wave_directive       = tracker.wave_directive,
        wave_directive_text  = tracker.wave_directive_text,
        boss_killed          = tracker.boss_killed,
        chest_opened         = tracker.chest_opened,
        run_done             = tracker.run_done,
    }
end

M.activate = function ()
    tracker.reset_run()
    if BatmobilePlugin and BatmobilePlugin.resume then
        pcall(BatmobilePlugin.resume, 'warmachine_hordes')
    end
    if InfernalHordesPlugin and InfernalHordesPlugin.disable then
        pcall(InfernalHordesPlugin.disable)
    end
end

M.deactivate = function ()
    if BatmobilePlugin and BatmobilePlugin.clear_target then
        pcall(BatmobilePlugin.clear_target, 'warmachine_hordes')
    end
end

return M
