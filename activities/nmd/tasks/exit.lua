-- ---------------------------------------------------------------------------
-- activities/nmd/tasks/exit.lua
--
-- End-of-run exit handler.  NEVER calls reset_all_dungeons -- that resets
-- the dungeon's state in place (mobs respawn, boss respawns) without
-- moving the player out, which made the bot loop forever inside the same
-- NMD.  Instead we leave properly: teleport to town.  Once we're back in
-- town, select_dungeon.lua picks up a sigil and consumes it to start the
-- next run.
--
-- Completion detection -- the canonical signal is the QUEST LOG.  D4 ships
-- one `DPO_<zone>` quest per nightmare dungeon; its objective(s) flip to
-- state==1 the moment the run is mechanically complete (boss dead AND any
-- prerequisites satisfied).  Boss-death + N-second-quiet inference is
-- unreliable for NMDs whose objective is something other than a boss
-- kill ("Activate 3 pylons", "Cleanse the Heart", multi-stage objectives,
-- etc.) so we read the quest log every pulse via quest_state.read_active.
--
-- We also keep boss_killed_at as a defensive fallback: if the quest API
-- ever returns nil mid-run (host glitch, zone load lag), we still TP out
-- a few seconds after the boss dies rather than hanging in the dungeon.
--
-- Two modes of operation:
--
--   1) WarPlan mode -- DOES NOT TP.  WarPlan owns transit; its supervisor
--      teleports us out via Next-Obj as soon as the WarPlan quest counter
--      ticks.  We still update tracker latches so the get_status overlay
--      reflects completion, but we never call teleport_to_waypoint here.
--
--   2) Standalone Nightmare mode -- TPs to a town waypoint after the
--      quest log says complete + chest grace elapses.  Once the zone
--      change to a non-DGN_* zone lands, we reset_run() so the next
--      dungeon entry starts clean.
-- ---------------------------------------------------------------------------

local settings    = require 'activities.nmd.settings'
local tracker     = require 'activities.nmd.tracker'
local quest_state = require 'activities.nmd.quest_state'
local exit_grace  = require 'core.exit_grace'
local waypoints   = require 'data.waypoints'
local zone        = require 'core.zone'
local core_mode   = require 'core.mode'

local task = { name = 'exit', status = 'idle', tp_fired_t = nil }

-- Grace period between detected completion and TP -- gives the
-- horadric chest time to spawn + loot_chest a window to grab it +
-- ground-drop loot a chance to land.  Sourced from core.exit_grace
-- so every activity uses the same value (currently 15s per user
-- spec).
local CHEST_GRACE_S        = exit_grace.MIN_GRACE_S
local TP_DEBOUNCE_S        = 6   -- don't re-fire TP while the zone is loading
-- Boss-death fallback fires only if the quest API never reported
-- complete.  Must stay >= CHEST_GRACE_S so the no-quest-signal path
-- doesn't accidentally bypass the loot-grace floor.
local BOSS_DEAD_FALLBACK_S = math.max(CHEST_GRACE_S + 4, 19)

-- Update quest-log latches.  Called every shouldExecute pulse.
-- Latches are sticky: once nmd_quest_seen flips on, it stays on until
-- reset_run; once nmd_quest_complete flips on, it stays on (the quest
-- can disappear from get_quests() the instant it completes).
local function poll_quest_state()
    local q = quest_state.read_active()
    if q then
        tracker.nmd_quest_seen = true
        if q.all_complete and not tracker.nmd_quest_complete then
            tracker.nmd_quest_complete   = true
            tracker.nmd_quest_complete_t = get_time_since_inject() or 0
            if settings.debug_mode then
                console.print('[NMD] quest complete: ' .. (q.name or '?'))
            end
        end
    else
        -- Quest gone from the log entirely AFTER we'd seen it = done.
        if tracker.nmd_quest_seen and not tracker.nmd_quest_complete then
            tracker.nmd_quest_complete   = true
            tracker.nmd_quest_complete_t = get_time_since_inject() or 0
            if settings.debug_mode then
                console.print('[NMD] quest gone from log -> run complete')
            end
        end
    end
end

-- True when we're past the post-complete grace window.
local function past_completion_grace()
    if tracker.nmd_quest_complete and tracker.nmd_quest_complete_t then
        local now = get_time_since_inject() or 0
        return (now - tracker.nmd_quest_complete_t) >= CHEST_GRACE_S
    end
    return false
end

-- Boss-death fallback (only fires if the quest signal never arrives).
local function past_boss_death_fallback()
    if tracker.nmd_quest_complete then return false end   -- quest path won
    if not tracker.boss_killed_at then return false end
    local now = get_time_since_inject() or 0
    return (now - tracker.boss_killed_at) >= BOSS_DEAD_FALLBACK_S
end

task.shouldExecute = function ()
    -- Always poll the quest log first so latches stay current regardless
    -- of mode -- WarPlan path uses them for status display, standalone
    -- path uses them to gate TP.
    poll_quest_state()

    if core_mode.is_warplan() then
        -- WarPlan owns transit.  Just keep latches fresh and reset state
        -- if WarPlan has already TP'd us out of the dungeon.
        if not zone.in_dungeon() and (tracker.boss_killed_at or tracker.boss_seen or tracker.nmd_quest_seen) then
            tracker.reset_run()
        end
        return false
    end

    -- Standalone path.
    if not zone.in_dungeon() then
        if tracker.boss_killed_at or tracker.boss_seen or tracker.tp_out_t or tracker.nmd_quest_seen then
            tracker.reset_run()
        end
        return false
    end

    -- We're inside a DGN_*.  Fire TP if EITHER:
    --   * the quest log says complete and the chest grace elapsed, OR
    --   * the boss-death fallback timer elapsed (quest API was silent)
    if past_completion_grace() then return true end
    if past_boss_death_fallback() then return true end
    return false
end

task.Execute = function ()
    local now = get_time_since_inject() or 0
    if task.tp_fired_t and (now - task.tp_fired_t) < TP_DEBOUNCE_S then
        task.status = 'TP issued, waiting for zone change'
        return
    end

    if not teleport_to_waypoint then
        task.status = 'no teleport_to_waypoint host fn'
        return
    end

    if settings.debug_mode then
        console.print('[NMD] exit -> teleport_to_waypoint(CERRIGAR)')
    end
    teleport_to_waypoint(waypoints.CERRIGAR)
    task.tp_fired_t   = now
    tracker.tp_out_t  = now
    task.status       = 'teleporting to town'
end

return task
