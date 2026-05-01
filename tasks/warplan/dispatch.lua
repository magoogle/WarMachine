-- ---------------------------------------------------------------------------
-- tasks/warplan/dispatch.lua
--
-- The War Plan state machine. Reads warplan_state every pulse and
-- decides which sub-task should fire (next-obj teleport / turn-in /
-- start-cycle / activity supervisor).
--
-- This task ONLY decides -- it sets pending flags on tracker.warplan.*
-- and returns. Higher-priority tasks (test_select, test_next_obj,
-- turn_in, start_cycle) execute the actual mouse/keyboard work on
-- subsequent pulses.
--
-- Decision tree:
--   active warplan exists:
--     activity == 'turnin'
--       in Skov_Temis    -> set turn_in.pending
--       elsewhere        -> set next_obj.pending  (tp home)
--     activity in {nightmare, helltide, undercity}
--       wrong zone       -> set next_obj.pending  (tp to dungeon/zone)
--       correct zone     -> no-op (activity supervisor handles in-zone)
--   no active warplan:
--     in Skov_Temis      -> if auto_cycle on, set start_cycle.pending
--     elsewhere          -> if auto_next_obj on, set next_obj.pending
-- ---------------------------------------------------------------------------

local settings      = require 'core.settings'
local tracker       = require 'core.tracker'
local mode          = require 'core.mode'
local whispers      = require 'core.whispers'

local task = { name = 'warplan_dispatch', status = nil }

local NEXT_OBJ_COOLDOWN_S    = 8.0    -- after issuing tp, don't retry for this long
local TURN_IN_COOLDOWN_S     = 5.0
local START_CYCLE_COOLDOWN_S = 5.0
local LOOT_GRACE_S           = 10.0   -- wait this long after activity completes
                                       -- before firing next_obj so the player
                                       -- can pick up floor loot
-- Helltide-specific: how long to wait BEFORE deciding the TP failed
-- (we ended up nowhere helltide-y) and how long to wait BEFORE retrying
-- after a failed TP (helltide cycles every ~hour with a few-minute gap).
local HELLTIDE_TP_VERIFY_S   = 30.0
local HELLTIDE_TP_RETRY_S    = 300.0  -- 5 min suspension

local function classify_zone(zone)
    if not zone then return 'unknown' end
    if zone == 'Skov_Temis' then return 'temis' end
    if zone:match('^DGN_') then return 'dungeon' end
    if zone:match('^X1_Undercity_') then return 'undercity' end
    if zone:match('^PIT_') then return 'pit' end
    if zone == 'S05_BSK_Prototype02' or zone:match('^S05_BSK_') then return 'hordes' end
    -- Boss-altar zones: Boss_WT3_*, Boss_WT4_*, Boss_WT5_*, Boss_Kehj_*
    -- (Belial), S12_Boss_* (Butcher), and any *_Varshan variant.  Keep
    -- this AFTER the others so PIT_/X1_/S05_BSK_ match first.
    if zone:match('^Boss_') or zone:match('^S12_Boss_') or zone:find('_Varshan', 1, true) then
        return 'boss'
    end
    return 'overworld'    -- could be helltide, world boss zone, or unrelated
end

-- True when current zone matches the kind of place the active war plan
-- activity progresses in. We deliberately do NOT include 'temis' for
-- undercity / pit even though the obelisks live there: when in Temis
-- without the obelisk in actor stream, dispatch needs to fire Next-Obj
-- to map-teleport us right to the obelisk. The entry tasks
-- (enter_undercity, pit/enter) yield to dispatch when their actor isn't
-- in stream, then claim the pulse once the actor appears.
local function zone_matches_activity(zone, activity)
    local zc = classify_zone(zone)
    if activity == 'nightmare' then return zc == 'dungeon'   end
    if activity == 'undercity' then return zc == 'undercity' end
    if activity == 'helltide'  then return zc == 'overworld' end
    if activity == 'pit'       then return zc == 'pit'       end
    -- Hordes: the war plan teleport drops us straight in the arena; if that
    -- ever changes to land us in Caldeum first, add `or zc == 'overworld'`
    -- and let HordeDev's walking_to_horde drive the gate (un-gate that task).
    if activity == 'hordes'    then return zc == 'hordes'    end
    if activity == 'boss'      then return zc == 'boss'      end
    if activity == 'turnin'    then return zc == 'temis'     end
    return false
end

local function fire_next_obj(reason, activity)
    local now = get_time_since_inject()
    local s = tracker.warplan.next_obj
    s.pending       = true
    s.step          = 0
    s.timer         = now
    s.baseline_zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    s.result        = nil
    tracker.warplan.next_obj_cooldown_until = now + NEXT_OBJ_COOLDOWN_S
    -- Helltide-specific: stamp the attempt time so we can detect TP
    -- failure 30s later (we're still not in a helltide zone) and bump
    -- the retry cooldown.
    if activity == 'helltide' then
        tracker.warplan.helltide_tp_attempt_at = now
    end
    if settings.debug_mode then
        console.print('[WarMachine] dispatch -> next_obj: ' .. tostring(reason))
    end
end

local function fire_turn_in()
    local now = get_time_since_inject()
    local s = tracker.warplan.turn_in
    s.pending = true
    s.timer   = now
    s.result  = nil
    tracker.warplan.turn_in_cooldown_until = now + TURN_IN_COOLDOWN_S
    if settings.debug_mode then
        console.print('[WarMachine] dispatch -> turn_in')
    end
end

local function fire_start_cycle()
    local now = get_time_since_inject()
    local s = tracker.warplan.start_cycle
    s.pending = true
    s.timer   = now
    s.result  = nil
    tracker.warplan.start_cycle_cooldown_until = now + START_CYCLE_COOLDOWN_S
    if settings.debug_mode then
        console.print('[WarMachine] dispatch -> start_cycle')
    end
end

-- Hordes post-boss guard.  After the boss dies the WarPlan objective
-- ticks (so wp.activity might flip to 'turnin' or another activity)
-- but we still need to finish the chest-opening phase.  Yield to the
-- in-zone activity until exit.lua sets run_done.  Same shape as the
-- pit_post_boss_pending() guard in supervisor.lua.
local function hordes_post_boss_pending()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    if not zone then return false end
    if zone ~= 'S05_BSK_Prototype02' and not zone:match('^S05_BSK_') then return false end
    local ok, ht = pcall(require, 'activities.hordes.tracker')
    if not ok or not ht then return false end
    return ht.boss_killed and not ht.run_done
end

-- Boss post-kill guard.  Same pattern as hordes: WarPlan ticks the moment
-- the boss dies (its objective flips), but we still need open_chest to
-- walk to the reward chest, click it, dismiss the key prompt, and let
-- the chest_opened_t grace elapse.  Yield to the activity until run_done
-- is signaled.
--
-- The user-reported symptom this fixes: bot kills boss -> WarPlan races
-- to next_obj before chest is looted -> chest is forfeited.
local function boss_post_kill_pending()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    if not zone then return false end
    -- Boss zones: Boss_WT*_*, Boss_Kehj_*, S12_Boss_*, *_Varshan*
    local in_boss_zone =
            zone:match('^Boss_')
         or zone:match('^S12_Boss_')
         or zone:find('_Varshan', 1, true)
    if not in_boss_zone then return false end
    local ok, bt = pcall(require, 'activities.boss.tracker')
    if not ok or not bt then return false end
    -- "Pending" = we're past altar (so a fight happened) but exit hasn't
    -- signaled run_done yet.  Covers boss-fight, chest-walk, chest-click,
    -- post-click grace.
    return bt.altar_activated and not bt.run_done
end

-- Whispers turn-in piggyback yield.  When the user has the auto-turn-in
-- toggle on AND a whispers turn-in is ready AND we're in a town that
-- hosts the bounty NPC (Skov_Temis / Hawe_TreeOfWhispers), yield so
-- dispatch doesn't fire next_obj before whisper_turnin can find the
-- Raven and complete the click sequence.
--
-- Without this yield, the actor-stream-on-zone-arrival timing window
-- (NPC takes a few frames to enter stream after zoning in) lets
-- dispatch latch next_obj.pending = true; test_next_obj then fires
-- the Tab+click teleport on the very next pulse and we leave town
-- before whispers can run.  User-reported symptom: "it tries to
-- teleport to the next obj instead of turning in the whispers."
local function whispers_pending()
    if not settings.warplan or not settings.warplan.whisper_turn_in then
        return false
    end
    if not whispers.in_whisper_town() then return false end
    return whispers.count_ready_bounties() > 0
end

-- NMD post-completion guard.  In WarPlan mode the NMD activity's exit task
-- is a no-op (WarPlan owns transit), but loot_chest may still be walking
-- to the Horadric reward.  Yield until either: (a) we're back out of the
-- DGN_* zone (WarPlan already TP'd somewhere), or (b) tracker.dungeon_done
-- latches in a future enhancement.  For now: yield while in DGN_* and
-- nmd_quest_complete is set but chest loot is still in flight.
local function nmd_post_complete_pending()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    if not zone or zone:sub(1,4) ~= 'DGN_' then return false end
    local ok, nt = pcall(require, 'activities.nmd.tracker')
    if not ok or not nt then return false end
    if not nt.nmd_quest_complete then return false end
    -- Honor a fixed-window post-complete grace identical to NMD exit.lua's
    -- CHEST_GRACE_S so loot_chest gets a fair shot at the reward.
    local POST_COMPLETE_GRACE_S = 10
    if not nt.nmd_quest_complete_t then return false end
    local now = get_time_since_inject() or 0
    return (now - nt.nmd_quest_complete_t) < POST_COMPLETE_GRACE_S
end

task.shouldExecute = function ()
    if settings.mode ~= mode.WARPLAN then return false end
    -- Don't dispatch if any sub-task is already mid-flight
    if tracker.warplan.test.pending then return false end
    if tracker.warplan.next_obj.pending then return false end
    if tracker.warplan.turn_in.pending then return false end
    if tracker.warplan.start_cycle.pending then return false end
    -- Yield to hordes chest-opening even when the WarPlan quest already
    -- considers itself complete.
    if hordes_post_boss_pending() then return false end
    -- Same yield for boss + NMD: WarPlan ticks before chest is looted,
    -- so dispatch must wait for the activity to finish its post-kill
    -- chest sequence before firing next_obj.
    if boss_post_kill_pending() then return false end
    if nmd_post_complete_pending() then return false end
    -- Whispers turn-in piggyback (Alfred has higher priority via the
    -- alfred_bridge yield in main.lua).  Yield while a turn-in is
    -- available in the current whisper-NPC town so whisper_turnin can
    -- run before we TP to the next warplan objective.
    if whispers_pending() then return false end
    return true
end

task.Execute = function ()
    local now  = get_time_since_inject()
    local wp   = tracker.warplan.snapshot
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    local zc   = classify_zone(zone)

    -- Detect war plan transitions (an activity completed). Set timestamp so
    -- we can delay any tp action long enough for the player to grab loot.
    local cur_name = wp and wp.active and wp.quest and wp.quest.name or nil
    local prev_name = tracker.warplan.last_seen_warplan
    if prev_name ~= cur_name then
        if prev_name ~= nil then
            tracker.warplan.activity_completed_at = now
            if settings.debug_mode then
                console.print(string.format('[WarMachine] activity transition: %s -> %s (loot grace %.0fs)',
                    tostring(prev_name), tostring(cur_name), LOOT_GRACE_S))
            end
        end
        tracker.warplan.last_seen_warplan = cur_name
    end

    -- Helper: are we still in the post-activity-complete grace window?
    local function in_loot_grace()
        local at = tracker.warplan.activity_completed_at
        return at and (now - at < LOOT_GRACE_S)
    end

    if wp and wp.active and wp.quest then
        -- We have an active war plan
        local match = zone_matches_activity(zone, wp.activity)
        if not match then
            -- Wrong zone for active activity -> tp (after loot grace)
            if in_loot_grace() then
                local left = LOOT_GRACE_S - (now - tracker.warplan.activity_completed_at)
                task.status = string.format('loot grace %.1fs', left)
                return
            end
            -- Helltide failed-TP retry guard: if we recently TP'd for
            -- helltide and still aren't in a helltide overworld zone
            -- after HELLTIDE_TP_VERIFY_S, the helltide isn't currently
            -- active.  Suspend retries for HELLTIDE_TP_RETRY_S (~5 min)
            -- so the next helltide window has time to spawn.
            if wp.activity == 'helltide' then
                local attempt_t = tracker.warplan.helltide_tp_attempt_at
                if attempt_t and (now - attempt_t) > HELLTIDE_TP_VERIFY_S then
                    -- We tried, didn't land in a helltide zone -> failed.
                    if settings.debug_mode then
                        console.print(string.format(
                            '[WarMachine] helltide TP failed verify -- waiting %ds',
                            HELLTIDE_TP_RETRY_S))
                    end
                    tracker.warplan.helltide_tp_cooldown_until = now + HELLTIDE_TP_RETRY_S
                    tracker.warplan.helltide_tp_attempt_at = nil
                end
                if now < (tracker.warplan.helltide_tp_cooldown_until or 0) then
                    local left = tracker.warplan.helltide_tp_cooldown_until - now
                    task.status = string.format('helltide retry in %.0fs', left)
                    return
                end
            end
            if settings.warplan.auto_next_obj
               and now >= tracker.warplan.next_obj_cooldown_until then
                fire_next_obj('activity=' .. tostring(wp.activity) .. ' zone=' .. zc, wp.activity)
                task.status = 'tp -> ' .. tostring(wp.activity)
                return
            end
            task.status = 'wrong zone (auto_next_obj off or cooldown)'
            return
        end

        -- We landed in a helltide-correct zone -> clear the failed-TP
        -- attempt stamp so the verify path doesn't penalize us.
        if wp.activity == 'helltide' then
            tracker.warplan.helltide_tp_attempt_at = nil
        end

        -- In the correct zone for this activity
        if wp.activity == 'turnin' then
            if settings.warplan.auto_turn_in
               and now >= tracker.warplan.turn_in_cooldown_until then
                fire_turn_in()
                task.status = 'turn-in pending'
                return
            end
            task.status = 'at Tyrael (auto_turn_in off or cooldown)'
            return
        end

        -- nightmare/helltide/undercity/pit in correct zone -- supervisor
        -- handles sub-plugin enable/disable; entry tasks (enter_undercity,
        -- pit/enter) handle Temis-side obelisk/crafter clicks if needed.
        task.status = 'in ' .. tostring(wp.activity)
        return
    end

    -- No active war plan
    if zc == 'temis' then
        if in_loot_grace() then
            local left = LOOT_GRACE_S - (now - tracker.warplan.activity_completed_at)
            task.status = string.format('loot grace %.1fs', left)
            return
        end
        if settings.warplan.auto_cycle
           and now >= tracker.warplan.start_cycle_cooldown_until then
            fire_start_cycle()
            task.status = 'starting next cycle'
            return
        end
        task.status = 'idle in Temis (cycle off)'
    else
        if in_loot_grace() then
            local left = LOOT_GRACE_S - (now - tracker.warplan.activity_completed_at)
            task.status = string.format('loot grace %.1fs', left)
            return
        end
        if settings.warplan.auto_next_obj
           and now >= tracker.warplan.next_obj_cooldown_until then
            fire_next_obj('no warplan, tp home')
            task.status = 'tp home'
            return
        end
        task.status = 'no warplan, not home'
    end
end

return task
