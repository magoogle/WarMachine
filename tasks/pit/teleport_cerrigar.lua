-- ---------------------------------------------------------------------------
-- tasks/pit/teleport_cerrigar.lua
--
-- (Legacy filename retained for stable task_manager registration.
--  Internal name: 'pit_travel_to_hub'.)
--
-- When in Pit mode but not at the Pit hub (Skov_Temis) and not yet inside
-- a pit, trigger the SHARED Next-Obj map-click flow that War Plan / NMD /
-- Undercity already use. We just set the pending flag on
-- tracker.warplan.next_obj — the existing tasks/warplan/test_next_obj
-- task picks it up and runs the Tab + click + poll-verify sequence using
-- the user's already-configured "Next Warplan Objective" map button
-- (purple crosshair).
--
-- This avoids a separate Pit-specific click point and reuses the same
-- one-stop map-travel mechanism the other modes already validate works.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'

local CRAFTER_SKIN   = 'TWN_Kehj_IronWolves_PitKey_Crafter'
local RETRY_COOLDOWN = 12.0   -- seconds between travel triggers

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

-- True when the Iron Wolves Pit-key Crafter is in our actor stream.
-- This is the most reliable "I'm at the hub" signal — works regardless
-- of how the zone name is reported.
local function crafter_in_stream()
    if not actors_manager then return false end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a:get_skin_name() == CRAFTER_SKIN then return true end
    end
    return false
end

task.shouldExecute = function ()
    if settings.mode ~= mode.PIT then return false end
    if not (settings.pit and settings.pit.auto_travel) then return false end
    if in_pit() then return false end
    if in_pit_hub() then return false end
    -- Defensive: even if zone reports something other than 'Skov_Temis'
    -- (sub-zone, future patch rename, etc.), don't teleport if we can
    -- already see the Pit-key Crafter — entry task can interact directly.
    if crafter_in_stream() then return false end

    -- Don't fire while a Next-Obj sequence is already in flight (we
    -- triggered one earlier and it's still working through Tab + click + verify).
    if tracker.warplan.next_obj.pending then return false end

    -- Cooldown to avoid hammering the map button if a travel attempt
    -- doesn't actually move us (e.g. button missed, no objective queued).
    if get_time_since_inject() - (tracker.pit.last_travel_attempt_at or -math.huge) < RETRY_COOLDOWN then
        return false
    end

    return true
end

task.Execute = function ()
    local now = get_time_since_inject()
    local lp  = get_local_player()

    -- Set up tracker.warplan.next_obj exactly the way test_next_obj's
    -- button-press path would, then return. The next pulse, the
    -- test_next_obj task fires and runs the full Tab + click + verify
    -- sequence.
    local s = tracker.warplan.next_obj
    s.pending           = true
    s.step              = 0     -- STEP_OPEN_MAP (test_next_obj's first state)
    s.timer             = now
    s.verify_started_at = nil
    s.baseline_zone     = get_current_world() and get_current_world():get_current_zone_name() or nil
    s.baseline_pos_x    = nil
    s.baseline_pos_y    = nil
    if lp then
        local p = lp:get_position()
        if p then
            s.baseline_pos_x = p:x()
            s.baseline_pos_y = p:y()
        end
    end
    s.result = nil

    tracker.pit.last_travel_attempt_at = now

    console.print(string.format(
        '[WarMachine] pit: triggering Next-Obj travel to Pit hub (baseline zone=%s)',
        tostring(s.baseline_zone)))
    task.status = 'travel via Next-Obj'
end

return task
