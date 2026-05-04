-- ---------------------------------------------------------------------------
-- activities/helltide/api.lua
--
-- WarMachine helltide activity entry point.  Replaces the legacy 2,000-line
-- HelltideRevamped plugin with a thin wrapper that drives a small task list
-- on top of:
--   * StaticPather merged WarMap data (POI catalog -- chests, pyres, ores,
--     herbs, shrines, world events) from poi_priority.lua
--   * core/move.lua's 2-tier movement (D4 click-to-walk -> WarPath routing)
--   * core/mount_manager.lua so travel between events gallops on horseback
--     when the area is clear
--
-- Activity contract per activities/_template/api.lua.
-- ---------------------------------------------------------------------------

local mount_manager = require 'core.mount_manager'
local settings_mod  = require 'activities.helltide.settings'
local tracker       = require 'activities.helltide.tracker'
local runner        = require 'activities.helltide.tasks.runner'
local quest_state   = require 'activities.helltide.quest_state'

local core_mode    = require 'core.mode'
local core_tracker = require 'core.tracker'

local M = {}

M.tag   = 'helltide'
M.label = 'Helltide'

M.is_loaded = function () return true end

-- ---------------------------------------------------------------------------
-- shouldExecute -- engages the helltide module in a few situations:
--
--   * Player has the helltide buff -- definitely inside the ring.
--   * Helltide hour active AND we have a `last_in_zone_pos` -- the
--     return_to_zone task drives us back when we wander off the edge.
--   * WarPlan mode AND a Helltide WarPlan quest is active -- we may
--     not have the buff yet (just TP'd in) but WarPlan is telling us
--     to be here, so engage and let return_to_zone walk us into the ring.
--   * Standalone HELLTIDE mode AND helltide hour active -- same idea:
--     run the activity even before the buff lights up.
--
-- Without the WarPlan/standalone gates the activity wouldn't engage on
-- a fresh TP into a helltide zone (no buff yet, no in-zone-pos yet),
-- and the bot would just stand there.
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
    if helltide_active_hour() and tracker.last_in_zone_pos ~= nil then return true end
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

    -- Mount management runs every pulse and self-throttles via cooldown.
    -- "allow_mount" gates on whether the current task is travel-flavored
    -- (interact_poi, return_to_zone) vs interaction (farm_chest, maiden).
    --
    -- Force-dismount AND suppress mounting whenever a WarPlan transit
    -- sequence is in flight (Tab+click teleport, vendor menu, NPC click,
    -- turn-in).  Without this, mount_manager fires Z in the same pulse
    -- that test_next_obj sends Tab/click, the keystrokes collide, and
    -- the teleport silently drops.
    local current = tracker.current_task or {}
    local travel_state = (current.name == 'interact_poi' or current.name == 'return_to_zone')
    local wp = core_tracker.warplan
    local wp_pending = wp.next_obj.pending
                    or wp.test.pending
                    or wp.turn_in.pending
                    or wp.start_cycle.pending
    mount_manager.update({
        disabled       = not settings_mod.auto_mount,
        allow_mount    = travel_state and not wp_pending,
        force_dismount = wp_pending,
    })

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
