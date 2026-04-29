-- ---------------------------------------------------------------------------
-- tasks/warplan/start_cycle.lua
--
-- Open the WAR PLANS menu by interacting with Warplans_Vendor in Skov_Temis.
--
-- Flow:
--   1. If loot_manager.is_in_vendor_screen() -> menu is open, chain into
--      auto-select and exit.
--   2. Otherwise, send interact_object(vendor) and re-send every 2s until
--      the menu opens or we hit the total timeout.
--
-- Retrying is necessary because interact_object often only initiates a
-- walk-up; the actual click that opens the menu has to fire after the
-- player arrives. Polling + retry handles that race cleanly.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'
local interact = require 'core.interact'

local VENDOR_SKIN     = 'Warplans_Vendor'
local INTERACT_RANGE  = 30.0
local RETRY_INTERVAL  = 2.0       -- re-send interact every N seconds
local TOTAL_TIMEOUT   = 15.0      -- abort if menu doesn't open in this long

local task = { name = 'warplan_start_cycle', status = nil }

local function reset(state)
    state.pending          = false
    state.first_attempt_at = nil
    state.last_click_at    = nil
end

local function menu_is_open()
    if not loot_manager or not loot_manager.is_in_vendor_screen then return false end
    local ok, ret = pcall(loot_manager.is_in_vendor_screen)
    return ok and ret == true
end

task.shouldExecute = function ()
    if settings.mode ~= mode.WARPLAN then return false end
    return tracker.warplan.start_cycle.pending == true
end

task.Execute = function ()
    local now   = get_time_since_inject()
    local state = tracker.warplan.start_cycle

    -- 1. Menu already open -> trigger auto-select and exit.
    if menu_is_open() then
        local sel = tracker.warplan.test
        sel.pending      = true
        sel.step         = 0
        sel.current_slot = 1
        sel.timer        = now
        sel.baseline     = #get_quests()
        sel.result       = nil
        console.print('[WarMachine] start_cycle: vendor menu open, triggering auto-select')
        reset(state)
        task.status = nil
        return
    end

    -- 2. Find vendor
    local vendor = interact.find_by_skin(VENDOR_SKIN, true)
    if not vendor then
        console.print('[WarMachine] start_cycle: vendor not in actor stream -- walk closer in Temis')
        reset(state)
        task.status = nil
        return
    end

    -- Initialize on first run
    if not state.first_attempt_at then
        state.first_attempt_at = now
        state.last_click_at    = -math.huge   -- force first click immediately
    end

    -- Total timeout
    if now - state.first_attempt_at > TOTAL_TIMEOUT then
        console.print(string.format('[WarMachine] start_cycle: vendor menu did not open in %.0fs -- aborting', TOTAL_TIMEOUT))
        reset(state)
        task.status = nil
        return
    end

    -- Retry interact every RETRY_INTERVAL seconds until the menu opens
    if now - state.last_click_at >= RETRY_INTERVAL then
        local r = interact.walk_and_interact(vendor, INTERACT_RANGE)
        if r == 'too_far' or r == 'no_actor' then
            local d = interact.distance(get_local_player(), vendor)
            console.print(string.format('[WarMachine] start_cycle: Warplans_Vendor %.1fy away -- aborting', d))
            reset(state)
            task.status = nil
            return
        end
        state.last_click_at = now
        task.status = 'clicking vendor (waiting for menu)'
        return
    end

    task.status = 'waiting for menu'
end

return task
