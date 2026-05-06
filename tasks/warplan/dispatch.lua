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
-- Helltide-specific failed-TP handling.  Two failure modes covered:
--   1. Helltide moved zones between when we read its location and when
--      we landed -- player stuck in an empty overworld zone, no buff.
--      Fix: re-teleport up to MAX_RETRIES times, each attempt waits
--      VERIFY_S for the buff before counting as failed.
--   2. Helltide is between cycles (the ~5-min gap that happens hourly)
--      -- no helltide is active anywhere; retrying just wastes pulses.
--      Fix: after MAX_RETRIES consecutive failures, suspend retries
--      for RETRY_S so the next cycle has time to spawn.
local HELLTIDE_TP_VERIFY_S    = 30.0
local HELLTIDE_TP_RETRY_S     = 300.0  -- 5 min suspension after MAX_RETRIES
local HELLTIDE_TP_MAX_RETRIES = 3

-- Helltide buff probe.  Prefers the host's is_in_helltide() global if
-- available; falls back to scanning the local player's buff list for
-- the helltide zone-aura hash (1066539) to remain compatible with
-- older host builds.
local function has_helltide_buff()
    if rawget(_G, 'is_in_helltide') then
        local ok, ret = pcall(_G.is_in_helltide)
        if ok and ret == true then return true end
        if ok then return false end
    end
    local lp = get_local_player()
    if not lp or not lp.get_buffs then return false end
    for _, b in ipairs(lp:get_buffs() or {}) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash())
        if hash == 1066539 then return true end
    end
    return false
end

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
    -- Safety fallback: if the quest name wasn't recognized (activity='unknown')
    -- but we're already in an activity zone, stay put rather than teleporting.
    -- Prevents a classify_activity miss from causing a teleport loop.
    if activity == 'unknown' and zc ~= 'temis' and zc ~= 'overworld' then
        return true
    end
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

-- Pit post-boss guard.  The pit WarPlan quest completes the moment the
-- boss dies, but tasks/pit/post_boss.lua still needs to walk to the
-- glyph gizmo and run the upgrade sequence.  Without this guard dispatch
-- would see "zone=pit, activity=<next>" and immediately fire next_obj,
-- teleporting us out before glyphs are upgraded.
-- Release once activities.pit.tracker.glyph_done is set (or interact_glyph
-- is disabled in settings).
local function pit_post_boss_pending()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    if not zone or not zone:match('^PIT_') then return false end
    -- tasks/pit/post_boss.lua sets glyph_gizmo_seen=true on first gizmo sight
    -- and resets it to false inside fire_next_obj_exit() once the upgrade is
    -- complete and the exit next_obj is already pending.  That window is the
    -- exact slice we want to block here.
    if not (tracker.pit and tracker.pit.glyph_gizmo_seen) then return false end
    local ok, pit_set = pcall(require, 'activities.pit.settings')
    if ok and pit_set and pit_set.interact_glyph == false then return false end
    return true
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
    -- Yield to pit glyph upgrade: boss dead but glyph sequence not done yet.
    if pit_post_boss_pending() then return false end
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

        -- Helltide TP-verify: covers the "moved zones" case where
        -- match=true (we're in an overworld zone) but the helltide
        -- buff never lands -- helltide rotated to a different zone
        -- between the next-obj read and our arrival.  Without this,
        -- the dispatcher cleared the attempt stamp on landing and
        -- the bot wandered around an empty overworld zone forever.
        --
        -- Logic:
        --   buff present -> success; clear attempt + reset attempt
        --   counter so the next 'wrong zone' warrants a fresh chain.
        --   buff missing + within VERIFY_S -> still in transit, keep
        --   waiting (the player might be walking to the ring).
        --   buff missing + over VERIFY_S + attempts < MAX -> mark
        --   the attempt stamp nil so the wrong-zone branch re-fires
        --   next-obj, increment the counter.
        --   buff missing + over VERIFY_S + attempts >= MAX -> declare
        --   helltide unavailable, suspend retries for RETRY_S.
        if wp.activity == 'helltide' then
            local attempt_t = tracker.warplan.helltide_tp_attempt_at
            if has_helltide_buff() then
                if attempt_t or (tracker.warplan.helltide_tp_attempts or 0) > 0 then
                    if settings.debug_mode then
                        console.print('[WarMachine] helltide buff acquired -- clearing retry state')
                    end
                end
                tracker.warplan.helltide_tp_attempt_at = nil
                tracker.warplan.helltide_tp_attempts   = 0
            elseif attempt_t and (now - attempt_t) > HELLTIDE_TP_VERIFY_S then
                local attempts = (tracker.warplan.helltide_tp_attempts or 0) + 1
                tracker.warplan.helltide_tp_attempts   = attempts
                tracker.warplan.helltide_tp_attempt_at = nil   -- allow next-obj to re-fire
                if attempts >= HELLTIDE_TP_MAX_RETRIES then
                    if settings.debug_mode then
                        console.print(string.format(
                            '[WarMachine] helltide TP failed %dx -- suspending %ds',
                            attempts, HELLTIDE_TP_RETRY_S))
                    end
                    tracker.warplan.helltide_tp_cooldown_until = now + HELLTIDE_TP_RETRY_S
                    tracker.warplan.helltide_tp_attempts       = 0   -- reset for after the cooldown
                else
                    if settings.debug_mode then
                        console.print(string.format(
                            '[WarMachine] helltide TP no-buff after %.0fs -- retry %d/%d',
                            HELLTIDE_TP_VERIFY_S, attempts, HELLTIDE_TP_MAX_RETRIES))
                    end
                    -- Treat as "wrong zone" so the branch below re-fires next-obj.
                    match = false
                end
            end
            if now < (tracker.warplan.helltide_tp_cooldown_until or 0) then
                local left = tracker.warplan.helltide_tp_cooldown_until - now
                task.status = string.format('helltide retry in %.0fs', left)
                return
            end
        end

        if not match then
            -- Wrong zone for active activity -> tp (after loot grace)
            if in_loot_grace() then
                local left = LOOT_GRACE_S - (now - tracker.warplan.activity_completed_at)
                task.status = string.format('loot grace %.1fs', left)
                return
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
