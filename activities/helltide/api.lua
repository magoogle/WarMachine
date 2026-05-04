-- ---------------------------------------------------------------------------
-- activities/helltide/api.lua
--
-- WarMachine helltide activity entry point.  Replaces the legacy 2,000-line
-- HelltideRevamped plugin with a thin wrapper that drives a small task list
-- on top of:
--   * WarPath catalog (POI -- chests, pyres, ores, herbs, shrines, world
--     events) read via WarPathPlugin.get_actors() from poi_priority.lua
--   * core/move.lua's 2-tier movement (D4 click-to-walk -> WarPath routing)
--
-- Activity contract per activities/_template/api.lua.
-- ---------------------------------------------------------------------------

local mount_manager = require 'core.mount_manager'
local settings_mod  = require 'activities.helltide.settings'
local tracker       = require 'activities.helltide.tracker'
local runner        = require 'activities.helltide.tasks.runner'
local quest_state   = require 'activities.helltide.quest_state'

local core_mode = require 'core.mode'

local M = {}

M.tag   = 'helltide'
M.label = 'Helltide'

M.is_loaded = function () return true end

-- ---------------------------------------------------------------------------
-- shouldExecute -- engages the helltide module when:
--   * Player has the helltide buff -- definitely inside the ring.
--   * WarPlan mode AND a Helltide WarPlan quest is active -- we may not
--     have the buff yet (just TP'd in) but WarPlan is telling us to be
--     here, so engage and let return_to_zone walk us into the ring.
--   * Standalone HELLTIDE mode AND helltide hour active.
-- ---------------------------------------------------------------------------
local function has_helltide_buff()
    local lp = get_local_player()
    if not lp or not lp.get_buffs then return false end
    for _, b in ipairs(lp:get_buffs() or {}) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash())
        if hash == 1066539 then return true end
    end
    return false
end

local function helltide_active_hour()
    local minute = tonumber(os.date('%M')) or 0
    return minute < 55
end

M.shouldExecute = function ()
    if has_helltide_buff() then return true end
    -- WarPlan helltide objective is active -- engage even without the
    -- buff so we can navigate into the ring.
    if core_mode.is_warplan() then
        local wp = quest_state.read()
        if wp and wp.active then return true end
    end
    -- Standalone HELLTIDE mode during the active hour -- run forever
    -- until time's up, opening as many chests as possible.
    if core_mode.is(core_mode.HELLTIDE) and helltide_active_hour() then
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Mount/move/task driver.  Called every WarMachine pulse while we're the
-- selected activity.
-- ---------------------------------------------------------------------------
M.pulse = function ()
    settings_mod.update()

    -- Mount management: never auto-mount.  pathfinder.request_move (which
    -- drives WarPath-routed movement) doesn't navigate a mounted player,
    -- so mounting up freezes the bot in place.  Auto-dismount-on-enemy
    -- still runs as a safety in case the player manually mounts; that's
    -- handled by passing allow_mount=false (rather than disabled=true,
    -- which would short-circuit dismount too).
    mount_manager.update({ allow_mount = false, force_dismount = true })

    runner.pulse()
end

M.get_status = function ()
    local cur = tracker.current_task or {}
    local out = {
        task   = cur.name or 'idle',
        status = cur.status,
        in_maiden = tracker.in_maiden,
        farm_target = tracker.farm_target and tracker.farm_target.skin or nil,
    }
    -- Surface the live WarPlan helltide directive + N/M progress so the
    -- overlay can render "Active: Helltide [tortured_gifts 1/2]" instead
    -- of just the tag.
    local ok, wp = pcall(quest_state.read)
    if ok and wp and wp.active then
        out.directive = wp.directive
        out.progress  = wp.progress
    end
    return out
end

M.activate = function ()
    tracker.reset_run()
    if HelltideRevampedPlugin and HelltideRevampedPlugin.disable then
        pcall(HelltideRevampedPlugin.disable)
    end
end

M.deactivate = function ()
    -- Clear any in-flight walker target so we don't keep walking into
    -- a wall after WarMachine moves to a different activity.
    local ok, walker = pcall(require, 'core.walker')
    if ok and walker and walker.stop then walker.stop() end
    tracker.farm_target = nil
    tracker.in_maiden   = false
end

return M
