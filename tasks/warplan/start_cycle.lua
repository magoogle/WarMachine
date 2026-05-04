-- ---------------------------------------------------------------------------
-- tasks/warplan/start_cycle.lua
--
-- Open the WAR PLANS menu by interacting with Warplans_Vendor in Skov_Temis.
--
-- Flow:
--   1. If loot_manager.is_in_vendor_screen() -> menu is open, chain into
--      auto-select and exit.
--   2. Vendor not in actor stream -> walk toward last-known position.
--      (Position is cached the first time we see the vendor; on cold start
--      WarPath frontier exploration is used to wander toward it.)
--   3. Vendor in stream -> send interact_object every 2s until the menu
--      opens or we hit the interact timeout.
--
-- Keeping pending=true while walking lets the whole dispatch loop stay
-- paused so no other task fires Next-Obj and teleports us away mid-walk.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'
local interact = require 'core.interact'
local move     = require 'core.move'

local VENDOR_SKIN        = 'Warplans_Vendor'
local INTERACT_RANGE     = 30.0
local RETRY_INTERVAL     = 2.0    -- re-send interact every N seconds
local WALK_TIMEOUT_S     = 60.0   -- abort if vendor not found in stream after this long
local INTERACT_TIMEOUT_S = 15.0   -- abort if menu doesn't open after vendor found

local task = { name = 'warplan_start_cycle', status = nil }

-- Session cache: last known world-position of Warplans_Vendor.  Populated
-- the first time the vendor enters the actor stream; persists for the
-- session so subsequent start_cycle calls can navigate directly to it
-- from anywhere in Skov_Temis without needing a map-teleport.
local _vendor_pos = nil

local function reset(state)
    state.pending          = false
    state.walk_started_at  = nil
    state.first_attempt_at = nil
    state.last_click_at    = nil
end

local function menu_is_open()
    if not loot_manager or not loot_manager.is_in_vendor_screen then return false end
    local ok, ret = pcall(loot_manager.is_in_vendor_screen)
    return ok and ret == true
end

local function warpath()
    return rawget(_G, 'WarPathPlugin') or rawget(_G, 'StaticPatherPlugin') or nil
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

    -- Start the walk-phase timer on the first pulse.
    if not state.walk_started_at then
        state.walk_started_at = now
        state.last_click_at   = -math.huge
    end

    -- Walk-phase timeout.
    if now - state.walk_started_at > WALK_TIMEOUT_S then
        console.print(string.format(
            '[WarMachine] start_cycle: vendor not found in Temis after %.0fs -- aborting',
            WALK_TIMEOUT_S))
        reset(state)
        task.status = nil
        return
    end

    -- 2. Find vendor in actor stream.
    local vendor = interact.find_by_skin(VENDOR_SKIN, true)

    if not vendor then
        -- Not in stream yet: navigate toward last-known position.
        if _vendor_pos then
            move.to_pos(_vendor_pos)
            task.status = 'walking to vendor'
        else
            -- Cold start (first session visit): explore Temis via WarPath
            -- frontier until the vendor comes into stream.
            local p  = warpath()
            local lp = get_local_player()
            local pp = lp and lp:get_position()
            local w  = get_current_world()
            local zone = w and w.get_current_zone_name and w:get_current_zone_name()
            if p and pp and zone then
                if p.exploration_tick then pcall(p.exploration_tick, zone, pp) end
                if p.exploration_frontier then
                    local tgt = p.exploration_frontier(zone, pp)
                    if tgt then move.to_pos(tgt) end
                end
            end
            task.status = 'searching for vendor (exploring Temis)'
        end
        return
    end

    -- Vendor is in stream: cache its position for future navigation.
    local vp = vendor:get_position()
    if vp then _vendor_pos = { x = vp:x(), y = vp:y(), z = vp:z() } end

    -- Initialize interact-phase timer on first sighting.
    if not state.first_attempt_at then
        state.first_attempt_at = now
    end

    -- Interact-phase timeout (from first sighting).
    if now - state.first_attempt_at > INTERACT_TIMEOUT_S then
        console.print(string.format(
            '[WarMachine] start_cycle: vendor menu did not open in %.0fs -- aborting',
            INTERACT_TIMEOUT_S))
        reset(state)
        task.status = nil
        return
    end

    -- 3. Retry interact every RETRY_INTERVAL seconds until the menu opens.
    if now - state.last_click_at >= RETRY_INTERVAL then
        local r = interact.walk_and_interact(vendor, INTERACT_RANGE)
        if r == 'too_far' then
            -- Vendor in stream but beyond INTERACT_RANGE: walk closer.
            -- interact_object handles the final few yards once we're in range.
            move.to_actor(vendor)
            task.status = 'walking to vendor'
        else
            task.status = 'clicking vendor (waiting for menu)'
        end
        state.last_click_at = now
        return
    end

    task.status = 'waiting for menu'
end

return task
