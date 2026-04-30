-- ---------------------------------------------------------------------------
-- tasks/pit/enter.lua
--
-- In Skov_Temis (the S07 Pit hub), walk to the Iron Wolves Pit-key Crafter,
-- open the configured pit level via utility.open_pit_portal(pit_address),
-- then walk into the spawned EGD_MSWK_World_Portal_01.
--
-- NOTE: The crafter actor's skin name still has the legacy `TWN_Kehj_`
-- prefix from when the Pit was in Kehjistan, then briefly Cerrigar; in
-- S07 / Skarn it lives in Skov_Temis. We key off the actor skin name so
-- it works regardless of where the game places the NPC in future patches.
--
-- Ported from ArkhamAsylum-1.0.6/tasks/enter_pit.lua, adapted to use D4's
-- built-in walk-on-click for NPC interactions (no Batmobile path-to-NPC).
-- ---------------------------------------------------------------------------

local settings   = require 'core.settings'
local tracker    = require 'core.tracker'
local mode       = require 'core.mode'
local interact   = require 'core.interact'
local pit_levels = require 'data.pit_levels'

local CRAFTER_SKIN  = 'TWN_Kehj_IronWolves_PitKey_Crafter'
local PORTAL_SKIN   = 'EGD_MSWK_World_Portal_01'
local INTERACT_RANGE = 30.0
local CONFIRM_DELAY  = 1.5   -- after open_pit_portal call before re-checking

local task = { name = 'pit_enter', status = nil }

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

local function get_portal()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a:is_interactable() and a:get_skin_name() == PORTAL_SKIN then
            return a
        end
    end
    return nil
end

local function menu_open()
    if not loot_manager or not loot_manager.is_in_vendor_screen then return false end
    local ok, ret = pcall(loot_manager.is_in_vendor_screen)
    return ok and ret == true
end

-- True when the Pit-key Crafter is in our actor stream. This is what
-- actually matters -- if we can see + interact with the crafter, we're
-- close enough to start the pit, regardless of how the zone is named.
local function crafter_in_stream()
    if not actors_manager then return false end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a:get_skin_name() == CRAFTER_SKIN then return true end
    end
    return false
end

task.shouldExecute = function ()
    -- Drive Pit entry only when:
    --   * War Plan mode is active (orchestrator-only design -- mode.PIT
    --     was removed when standalone Pit was handed back to ArkhamAsylum)
    --   * Active war plan activity is 'pit'
    --   * settings.pit.auto_enter is on (lets the user disable WarMachine
    --     pit driving while still using sub-plugin orchestration)
    if settings.mode ~= mode.WARPLAN then return false end
    if not (settings.pit and settings.pit.auto_enter) then return false end
    local wp = tracker.warplan and tracker.warplan.snapshot
    if not (wp and wp.active and wp.activity == 'pit') then return false end
    if in_pit() then return false end
    -- Yield to other in-flight click sequences so we don't fight them.
    if tracker.warplan.test.pending        then return false end
    if tracker.warplan.next_obj.pending    then return false end
    if tracker.warplan.turn_in.pending     then return false end
    if tracker.warplan.start_cycle.pending then return false end
    if tracker.undercity.enter.pending     then return false end
    -- Only claim the pulse when something is actionable in stream: the
    -- Pit-key Crafter NPC, the spawned portal, or an open vendor menu
    -- (player just clicked the crafter and we're waiting on the pit-level
    -- selection). If none are visible (player teleported far from the
    -- crafter after war plan accept), yield to dispatch so it can fire
    -- Next-Obj to map-teleport us right to the crafter.
    if menu_open()         then return true  end
    if get_portal()        then return true  end
    if crafter_in_stream() then return true  end
    return false
end

task.Execute = function ()
    local now   = get_time_since_inject()
    local state = tracker.pit.enter

    -- 1. Portal already up? Walk + interact (D4 handles walk).
    local portal = get_portal()
    if portal then
        local r = interact.walk_and_interact(portal, INTERACT_RANGE)
        if r == 'interacted' then
            -- Snapshot start time for the in-pit reset timer
            tracker.pit.start_time = now
            tracker.pit.exit_trigger_time = nil
            tracker.pit.glyph_gizmo_seen  = false
            task.status = 'enter pit portal'
        elseif r == 'too_far' then
            task.status = 'pit portal too far'
        end
        return
    end

    -- 2. Pit-key Crafter menu open? Trigger pit portal.
    if menu_open() then
        if state.debounce_time + CONFIRM_DELAY > now then
            task.status = 'waiting for portal'
            return
        end
        local addr = pit_levels[settings.pit.level]
        if not addr then
            console.print(string.format('[WarMachine] pit: invalid pit level %s', tostring(settings.pit.level)))
            task.status = 'invalid pit level'
            return
        end
        console.print(string.format('[WarMachine] pit: open_pit_portal level=%d address=0x%X',
            settings.pit.level, addr))
        utility.open_pit_portal(addr)
        state.debounce_time = now
        task.status = string.format('opening pit %d', settings.pit.level)
        return
    end

    -- 3. No portal, no menu -> interact with the Pit-key Crafter NPC.
    local crafter = interact.find_by_skin(CRAFTER_SKIN, true)
    if not crafter then
        task.status = 'Pit-key Crafter not in stream'
        return
    end
    local r = interact.walk_and_interact(crafter, INTERACT_RANGE)
    if r == 'interacted' then
        task.status = 'click Pit-key Crafter'
    elseif r == 'too_far' then
        local d = interact.distance(get_local_player(), crafter)
        console.print(string.format('[WarMachine] pit: Pit-key Crafter %.1fy away', d))
        task.status = string.format('Pit-key Crafter %.1fy', d)
    end
end

return task
