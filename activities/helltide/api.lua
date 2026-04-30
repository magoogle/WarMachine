-- ---------------------------------------------------------------------------
-- activities/helltide/api.lua
--
-- WarMachine helltide activity entry point.  Replaces the legacy 2,000-line
-- HelltideRevamped plugin with a thin wrapper that drives a small task list
-- on top of:
--   * StaticPather merged WarMap data (POI catalog -- chests, pyres, ores,
--     herbs, shrines, world events) from poi_priority.lua
--   * core/move.lua's 3-tier fallback (D4 click-to-walk -> StaticPather
--     routing -> Batmobile freeroam) so zones with no curated data still
--     run, just less efficiently
--   * core/mount_manager.lua so travel between events gallops on horseback
--     when the area is clear
--
-- Activity contract per activities/_template/api.lua.
-- ---------------------------------------------------------------------------

local mount_manager = require 'core.mount_manager'
local settings_mod  = require 'activities.helltide.settings'
local tracker       = require 'activities.helltide.tracker'
local runner        = require 'activities.helltide.tasks.runner'

local M = {}

M.tag   = 'helltide'
M.label = 'Helltide'

M.is_loaded = function () return true end

-- ---------------------------------------------------------------------------
-- shouldExecute -- run when:
--   * The player has the helltide buff (real run)
--   * OR helltide hour is active and we're recovering back to the zone
-- The buff check is in tasks/return_to_zone.lua's helpers; we keep this
-- top-level gate broad so the runner gets a chance to fire its recovery
-- task even when the buff is briefly absent.
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
    return has_helltide_buff()
        or (helltide_active_hour() and tracker.last_in_zone_pos ~= nil)
end

-- ---------------------------------------------------------------------------
-- Mount/move/task driver.  Called every WarMachine pulse while we're the
-- selected activity.
-- ---------------------------------------------------------------------------
M.pulse = function ()
    settings_mod.update()

    -- Mount management runs every pulse and self-throttles via cooldown.
    -- "allow_mount" gates on whether the current task is travel-flavored
    -- (interact_poi, return_to_zone) vs interaction (farm_chest, maiden).
    local current = tracker.current_task or {}
    local travel_state = (current.name == 'interact_poi' or current.name == 'return_to_zone')
    mount_manager.update({
        disabled    = not settings_mod.auto_mount,
        allow_mount = travel_state,
    })

    runner.pulse()
end

M.get_status = function ()
    local cur = tracker.current_task or {}
    return {
        task   = cur.name or 'idle',
        status = cur.status,
        in_maiden = tracker.in_maiden,
        farm_target = tracker.farm_target and tracker.farm_target.skin or nil,
    }
end

M.activate = function ()
    tracker.reset_run()
    if BatmobilePlugin and BatmobilePlugin.resume then
        -- Make sure Batmobile is unpaused so move.lua's tier-3 fallback
        -- can drive us when StaticPather has no data.
        pcall(BatmobilePlugin.resume, 'warmachine_helltide')
    end
    if HelltideRevampedPlugin and HelltideRevampedPlugin.disable then
        pcall(HelltideRevampedPlugin.disable)
    end
end

M.deactivate = function ()
    -- Clear any in-flight movement so we don't keep walking into a wall
    -- after WarMachine moves to a different activity.
    if BatmobilePlugin and BatmobilePlugin.clear_target then
        pcall(BatmobilePlugin.clear_target, 'warmachine_helltide')
    end
    tracker.farm_target = nil
    tracker.in_maiden   = false
end

return M
