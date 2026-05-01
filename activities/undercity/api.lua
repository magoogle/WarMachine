-- activities/undercity/api.lua  --  activity contract.

local mount_manager = require 'core.mount_manager'
local settings_mod  = require 'activities.undercity.settings'
local tracker       = require 'activities.undercity.tracker'
local runner        = require 'activities.undercity.tasks.runner'

local M = {}

M.tag   = 'undercity'
M.label = 'Undercity'

M.is_loaded = function () return true end

local function in_undercity()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and z:sub(1, #'X1_Undercity_') == 'X1_Undercity_'
end

local function in_hub()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z == 'Skov_Temis' or z == 'Naha_Kurast'
end

M.shouldExecute = function ()
    return in_undercity() or in_hub()
end

M.pulse = function ()
    settings_mod.update()
    -- Mounting disabled: undercity floors are tight + combat-dense, mount
    -- churn hurts.  Only Helltide uses auto-mount.
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
        chest_looted  = tracker.chest_looted,
        hearth_count  = tracker.hearth_count,
    }
end

M.activate = function ()
    tracker.reset_run()
    -- Silence legacy external plugins so they don't fight us
    if WonderCityPlugin and WonderCityPlugin.disable then
        pcall(WonderCityPlugin.disable)
    end
    if SpelunkerPlugin and SpelunkerPlugin.disable then
        pcall(SpelunkerPlugin.disable)
    end
end

M.deactivate = function ()
    local ok, walker = pcall(require, 'core.walker')
    if ok and walker and walker.stop then walker.stop() end
end

return M
