-- ---------------------------------------------------------------------------
-- tasks/warplan/turn_in.lua
--
-- Interact with NPC_QST_X2_Tyrael_NonCombat to claim war plan rewards.
-- A single successful click drops 3 reward chests as floor loot and clears
-- WarPlans_QST_TurnIn_Rewards from the active quest list.
--
-- Flow:
--   1. If WarPlans_QST_TurnIn_Rewards is no longer in the quest list ->
--      already turned in. Exit.
--   2. Tyrael not in actor stream -> look up his position from WarPath's
--      static catalog for Skov_Temis and navigate there directly.
--   3. Tyrael in stream -> send interact_object every 2s until the quest
--      disappears or we hit the interact timeout.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'
local interact = require 'core.interact'
local move     = require 'core.move'

local TYRAEL_SKIN        = 'NPC_QST_X2_Tyrael_NonCombat'
local TURNIN_QUEST       = 'WarPlans_QST_TurnIn_Rewards'
local INTERACT_RANGE     = 30.0
local RETRY_INTERVAL     = 2.0
local WALK_TIMEOUT_S     = 60.0   -- abort if Tyrael not in stream after this long
local INTERACT_TIMEOUT_S = 15.0   -- abort if quest doesn't clear after Tyrael found

local task = { name = 'warplan_turn_in', status = nil }

local function reset(state)
    state.pending          = false
    state.walk_started_at  = nil
    state.first_attempt_at = nil
    state.last_click_at    = nil
end

local function turnin_quest_present()
    for _, q in ipairs(get_quests()) do
        if q:get_name() == TURNIN_QUEST then return true end
    end
    return false
end

-- Query WarPath's static catalog for the current zone to find a POI by
-- skin name.  Returns {x,y,z} or nil.
local function catalog_pos(skin)
    local p = rawget(_G, 'WarPathPlugin') or rawget(_G, 'StaticPatherPlugin')
    if not p or not p.get_actors then return nil end
    local actors = p.get_actors()
    if not actors then return nil end
    for _, a in ipairs(actors) do
        if a.skin and a.skin:find(skin, 1, true) then
            return { x = a.x, y = a.y, z = a.z }
        end
    end
    return nil
end

task.shouldExecute = function ()
    if settings.mode ~= mode.WARPLAN then return false end
    return tracker.warplan.turn_in.pending == true
end

task.Execute = function ()
    local now   = get_time_since_inject()
    local state = tracker.warplan.turn_in

    -- 1. Quest gone -> success. Exit.
    if not turnin_quest_present() then
        console.print('[WarMachine] turn_in: complete (quest cleared)')
        state.result = 'success'
        reset(state)
        task.status = nil
        return
    end

    -- Start walk-phase timer on the first pulse.
    if not state.walk_started_at then
        state.walk_started_at = now
        state.last_click_at   = -math.huge
    end

    -- Walk-phase timeout.
    if now - state.walk_started_at > WALK_TIMEOUT_S then
        console.print(string.format(
            '[WarMachine] turn_in: Tyrael not found in Temis after %.0fs -- aborting',
            WALK_TIMEOUT_S))
        state.result = 'timeout'
        reset(state)
        task.status = nil
        return
    end

    -- 2. Find Tyrael in actor stream.
    local tyrael = interact.find_by_skin(TYRAEL_SKIN, true)

    if not tyrael then
        -- Not in stream: use WarPath catalog to navigate directly to
        -- Tyrael's recorded position.
        local pos = catalog_pos(TYRAEL_SKIN)
        if pos then
            move.to_pos(pos)
            task.status = 'walking to Tyrael'
        else
            task.status = 'Tyrael not in catalog (check WarPath data)'
        end
        return
    end

    -- Initialize interact-phase timer on first sighting.
    if not state.first_attempt_at then
        state.first_attempt_at = now
    end

    -- Interact-phase timeout (from first sighting).
    if now - state.first_attempt_at > INTERACT_TIMEOUT_S then
        console.print(string.format(
            '[WarMachine] turn_in: did not register in %.0fs -- aborting',
            INTERACT_TIMEOUT_S))
        state.result = 'timeout'
        reset(state)
        task.status = nil
        return
    end

    -- 3. Retry interact every RETRY_INTERVAL until the quest disappears.
    if now - state.last_click_at >= RETRY_INTERVAL then
        local r = interact.walk_and_interact(tyrael, INTERACT_RANGE)
        if r == 'too_far' then
            move.to_actor(tyrael)
            task.status = 'walking to Tyrael'
        else
            task.status = 'clicking Tyrael (waiting for quest clear)'
        end
        state.last_click_at = now
        return
    end

    task.status = 'waiting for turn-in'
end

return task
