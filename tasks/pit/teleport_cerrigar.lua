-- ---------------------------------------------------------------------------
-- tasks/pit/teleport_cerrigar.lua
--
-- (Legacy filename retained so task_manager registration is stable; task's
--  internal name is 'pit_travel_to_hub'.)
--
-- When in Pit mode but not at the Pit hub (Skov_Temis) and not yet inside
-- a pit, open the world map (Tab) and click the configured Pit-hub
-- waypoint icon. D4 fast-travels to that waypoint.
--
-- We use the same Tab + map-click pattern that War Plan's Next-Obj uses,
-- but with a different click target (the Pit-hub waypoint specifically).
-- This works regardless of where the player currently is — no SNO-based
-- teleport_to_waypoint() call needed.
--
-- Sequence (poll-style verify):
--   1. send_key_press(Tab)              — open world map
--   2. wait OPEN_MAP_WAIT_S
--   3. send_mouse_click(travel_x, y)    — click waypoint icon
--   4. poll up to MAX_VERIFY_S for zone change → success
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'

local VK_TAB = 0x09

local STEP_OPEN_MAP = 0
local STEP_CLICK    = 1
local STEP_VERIFY   = 2

local OPEN_MAP_WAIT_S = 0.60
local MAX_VERIFY_S    = 8.00
local RETRY_COOLDOWN  = 12.0   -- after a tp attempt, don't retry for this long

local task = { name = 'pit_travel_to_hub', status = nil }

local function in_pit_hub()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    return zone == 'Skov_Temis'
end

local function in_pit()
    local w = get_current_world()
    if not w then return false end
    local n = w:get_name()
    return n ~= nil and n:match('^PIT_') ~= nil
end

local function reset(state)
    state.pending           = false
    state.step              = 0
    state.timer             = 0
    state.verify_started_at = nil
    state.baseline_zone     = nil
end

task.shouldExecute = function ()
    if settings.mode ~= mode.PIT then return false end
    if in_pit() then return false end
    if in_pit_hub() then return false end
    if not (settings.pit and settings.pit.auto_travel) then return false end

    local state = tracker.pit.travel

    -- Already mid-flight? Keep running.
    if state.pending then return true end

    -- Cooldown after a previous attempt
    if get_time_since_inject() - (state.last_attempt_at or -math.huge) < RETRY_COOLDOWN then
        return false
    end

    -- Travel coords must be configured. Otherwise silent skip — the user
    -- still gets the static console warning from the supervisor / no-action.
    local cp = settings.pit.travel_click
    if not (cp and (cp.x ~= 0 or cp.y ~= 0)) then return false end

    return true
end

task.Execute = function ()
    local now   = get_time_since_inject()
    local state = tracker.pit.travel
    local cp    = settings.pit.travel_click

    -- First-pulse setup
    if not state.pending then
        state.pending           = true
        state.step              = STEP_OPEN_MAP
        state.timer             = now
        state.last_attempt_at   = now
        state.baseline_zone     = get_current_world() and get_current_world():get_current_zone_name() or nil
        state.verify_started_at = nil
        console.print(string.format('[WarMachine] pit travel: started, baseline zone = %s',
            tostring(state.baseline_zone)))
    end

    if state.step == STEP_OPEN_MAP then
        utility.send_key_press(VK_TAB)
        state.timer = now
        state.step  = STEP_CLICK
        task.status = 'open map (Tab)'
        return
    end

    if state.step == STEP_CLICK then
        if now - state.timer < OPEN_MAP_WAIT_S then return end
        console.print(string.format('[WarMachine] pit travel: click (%d,%d)', cp.x, cp.y))
        utility.send_mouse_click(cp.x, cp.y)
        state.timer = now
        state.step  = STEP_VERIFY
        task.status = 'click waypoint'
        return
    end

    if state.step == STEP_VERIFY then
        if not state.verify_started_at then state.verify_started_at = now end

        local cur_zone = get_current_world() and get_current_world():get_current_zone_name() or nil
        if cur_zone ~= state.baseline_zone then
            console.print(string.format('[WarMachine] pit travel: SUCCESS zone %s -> %s',
                tostring(state.baseline_zone), tostring(cur_zone)))
            reset(state)
            task.status = nil
            return
        end

        if now - state.verify_started_at > MAX_VERIFY_S then
            console.print(string.format('[WarMachine] pit travel: no zone change after %.0fs',
                MAX_VERIFY_S))
            reset(state)
            task.status = nil
            return
        end

        task.status = string.format('verifying (%.1fs)', now - state.verify_started_at)
        return
    end
end

return task
