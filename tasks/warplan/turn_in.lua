-- ---------------------------------------------------------------------------
-- tasks/warplan/turn_in.lua
--
-- Interact with NPC_QST_X2_Tyrael_NonCombat to claim war plan rewards.
-- A single successful click drops 3 reward chests as floor loot and clears
-- WarPlans_QST_TurnIn_Rewards from the active quest list.
--
-- Flow:
--   1. If WarPlans_QST_TurnIn_Rewards is no longer in the quest list →
--      already turned in. Exit.
--   2. Otherwise send interact_object(tyrael) and re-send every 2s until
--      the quest disappears or we hit the total timeout.
--
-- Retrying is necessary for the same reason as start_cycle: interact_object
-- often only initiates a walk-up; the actual click that registers the
-- turn-in fires after the player arrives. Polling + retry handles that.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'
local interact = require 'core.interact'

local TYRAEL_SKIN     = 'NPC_QST_X2_Tyrael_NonCombat'
local TURNIN_QUEST    = 'WarPlans_QST_TurnIn_Rewards'
local INTERACT_RANGE  = 30.0
local RETRY_INTERVAL  = 2.0
local TOTAL_TIMEOUT   = 15.0

local task = { name = 'warplan_turn_in', status = nil }

local function reset(state)
    state.pending          = false
    state.first_attempt_at = nil
    state.last_click_at    = nil
end

local function turnin_quest_present()
    for _, q in ipairs(get_quests()) do
        if q:get_name() == TURNIN_QUEST then return true end
    end
    return false
end

task.shouldExecute = function ()
    if settings.mode ~= mode.WARPLAN then return false end
    return tracker.warplan.turn_in.pending == true
end

task.Execute = function ()
    local now   = get_time_since_inject()
    local state = tracker.warplan.turn_in

    -- 1. Quest gone → success. Exit.
    if not turnin_quest_present() then
        console.print('[WarMachine] turn_in: complete (quest cleared)')
        state.result = 'success'
        reset(state)
        task.status = nil
        return
    end

    -- 2. Find Tyrael
    local tyrael = interact.find_by_skin(TYRAEL_SKIN, true)
    if not tyrael then
        console.print('[WarMachine] turn_in: Tyrael not in actor stream — walk closer in Temis')
        state.result = 'no_actor'
        reset(state)
        task.status = nil
        return
    end

    -- Initialize on first run
    if not state.first_attempt_at then
        state.first_attempt_at = now
        state.last_click_at    = -math.huge
    end

    -- Total timeout
    if now - state.first_attempt_at > TOTAL_TIMEOUT then
        console.print(string.format('[WarMachine] turn_in: did not register in %.0fs — aborting', TOTAL_TIMEOUT))
        state.result = 'timeout'
        reset(state)
        task.status = nil
        return
    end

    -- Retry interact every RETRY_INTERVAL until the quest disappears
    if now - state.last_click_at >= RETRY_INTERVAL then
        local r = interact.walk_and_interact(tyrael, INTERACT_RANGE)
        if r == 'too_far' or r == 'no_actor' then
            local d = interact.distance(get_local_player(), tyrael)
            console.print(string.format('[WarMachine] turn_in: Tyrael %.1fy away — aborting', d))
            state.result = r
            reset(state)
            task.status = nil
            return
        end
        state.last_click_at = now
        task.status = 'clicking Tyrael (waiting for quest clear)'
        return
    end

    task.status = 'waiting for turn-in'
end

return task
