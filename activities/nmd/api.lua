-- activities/nmd/api.lua

local mount_manager = require 'core.mount_manager'
local settings_mod  = require 'activities.nmd.settings'
local tracker       = require 'activities.nmd.tracker'
local runner        = require 'activities.nmd.tasks.runner'

local core_mode     = require 'core.mode'
local zone          = require 'core.zone'

local M = {}

M.tag   = 'nmd'
M.label = 'Nightmare'

M.is_loaded = function () return true end

M.shouldExecute = function ()
    -- Inside a DGN_* zone we always engage (kill/loot/exit pipeline).
    if zone.in_dungeon() then return true end
    -- Outside a dungeon we only engage in standalone NIGHTMARE so
    -- select_dungeon can consume a sigil and start the next run.
    -- WarPlan owns transit, so we stay quiet there.
    if core_mode.is(core_mode.NIGHTMARE) then return true end
    return false
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
        task               = cur.name or 'idle',
        status             = cur.status,
        floor              = tracker.current_floor,
        boss_seen          = tracker.boss_seen,
        boss_killed_at     = tracker.boss_killed_at,
        dungeon_done       = tracker.dungeon_done,
        nmd_quest_seen     = tracker.nmd_quest_seen,
        nmd_quest_complete = tracker.nmd_quest_complete,
        cursed_started     = tracker.cursed_started,
        cursed_complete    = tracker.cursed_complete,
    }
end

M.activate = function ()
    tracker.reset_run()
    if SigilRunnerPlugin and SigilRunnerPlugin.disable then
        pcall(SigilRunnerPlugin.disable)
    end
end

M.deactivate = function ()
    -- Stop any in-flight walker target so the player doesn't keep
    -- walking when we transition activities or shut down.
    local ok, walker = pcall(require, 'core.walker')
    if ok and walker and walker.stop then walker.stop() end
end

return M
