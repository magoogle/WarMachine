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

local task = { name = 'warplan_dispatch', status = nil }

local NEXT_OBJ_COOLDOWN_S    = 8.0    -- after issuing tp, don't retry for this long
local TURN_IN_COOLDOWN_S     = 5.0
local START_CYCLE_COOLDOWN_S = 5.0
local LOOT_GRACE_S           = 10.0   -- wait this long after activity completes
                                       -- before firing next_obj so the player
                                       -- can pick up floor loot

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

local function fire_next_obj(reason)
    local now = get_time_since_inject()
    local s = tracker.warplan.next_obj
    s.pending       = true
    s.step          = 0
    s.timer         = now
    s.baseline_zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    s.result        = nil
    tracker.warplan.next_obj_cooldown_until = now + NEXT_OBJ_COOLDOWN_S
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
            if settings.warplan.auto_next_obj
               and now >= tracker.warplan.next_obj_cooldown_until then
                fire_next_obj('activity=' .. tostring(wp.activity) .. ' zone=' .. zc)
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
