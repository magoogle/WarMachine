-- activities/nmd/api.lua

local mount_manager = require 'core.mount_manager'
local settings_mod  = require 'activities.nmd.settings'
local tracker       = require 'activities.nmd.tracker'
local runner        = require 'activities.nmd.tasks.runner'

local M = {}

M.tag   = 'nmd'
M.label = 'Nightmare'

M.is_loaded = function () return true end

local function in_dungeon()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and z:sub(1, 4) == 'DGN_'
end

M.shouldExecute = function ()
    -- Standalone NMD mode runs only inside DGN_* zones.  Entry (sigil
    -- consume + map click) is deferred -- WarPlan drives it via Next-Obj
    -- and standalone mode expects the user to have pre-entered a dungeon
    -- (or restock_sigils + start_dungeon to be ported in v0.2).
    return in_dungeon()
end

M.pulse = function ()
    settings_mod.update()
    -- Mounting disabled in nightmare dungeons: tight corridors + combat
    -- density makes mount churn a net loss.  Only Helltide uses auto-mount.
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
        dungeon_done  = tracker.dungeon_done,
    }
end

M.activate = function ()
    tracker.reset_run()
    if BatmobilePlugin and BatmobilePlugin.resume then
        pcall(BatmobilePlugin.resume, 'warmachine_nmd')
    end
    if SigilRunnerPlugin and SigilRunnerPlugin.disable then
        pcall(SigilRunnerPlugin.disable)
    end
end

M.deactivate = function ()
    if BatmobilePlugin and BatmobilePlugin.clear_target then
        pcall(BatmobilePlugin.clear_target, 'warmachine_nmd')
    end
end

return M
