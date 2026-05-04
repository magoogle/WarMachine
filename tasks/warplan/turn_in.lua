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
--   2. Tyrael not in actor stream -> walk toward last-known position.
--      (Position is cached the first time we see Tyrael; on cold start
--      WarPath frontier exploration is used to wander toward him.)
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
local WALK_TIMEOUT_S     = 60.0   -- abort if Tyrael not found in stream after this long
local INTERACT_TIMEOUT_S = 15.0   -- abort if quest doesn't clear after Tyrael found

local task = { name = 'warplan_turn_in', status = nil }

-- Session cache: last known world-position of Tyrael.  Populated the first
-- time he enters the actor stream; persists for the session so turn_in
-- can navigate directly to him from anywhere in Skov_Temis.
local _tyrael_pos = nil

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

local function warpath()
    return rawget(_G, 'WarPathPlugin') or rawget(_G, 'StaticPatherPlugin') or nil
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

    -- Start the walk-phase timer on the first pulse.
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
        -- Not in stream yet: navigate toward last-known position.
        if _tyrael_pos then
            move.to_pos(_tyrael_pos)
            task.status = 'walking to Tyrael'
        else
            -- Cold start: explore Temis via WarPath frontier until Tyrael
            -- comes into actor stream.
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
            task.status = 'searching for Tyrael (exploring Temis)'
        end
        return
    end

    -- Tyrael is in stream: cache position for future navigation.
    local tp = tyrael:get_position()
    if tp then _tyrael_pos = { x = tp:x(), y = tp:y(), z = tp:z() } end

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
            -- Tyrael in stream but beyond INTERACT_RANGE: walk closer.
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
