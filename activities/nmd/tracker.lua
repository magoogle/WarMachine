-- activities/nmd/tracker.lua  --  per-run state.

local tracker = {
    visited        = {},
    current_floor  = 1,
    last_world_id  = nil,

    boss_seen      = false,
    boss_killed_at = nil,
    dungeon_done   = false,    -- objective fully cleared

    -- Boss-room anchor: snapshot of player position the moment we first
    -- spotted a boss in stream.  boss_room_hold task uses this to keep
    -- the bot inside the arena when the boss briefly leaves the stream
    -- (leap / summon / teleport phases) so freeroam_fallback doesn't
    -- pull us out the door and reset the encounter.
    boss_room_anchor = nil,
    -- get_time_since_inject() of when boss_room_hold first arrived at the
    -- anchor with no kill target nearby.  After ANCHOR_QUIET_S of quiet,
    -- boss_room_hold latches boss_killed_at = now (the boss is gone).
    -- Cleared every time kill_monster picks a target (combat resumes).
    hold_quiet_started_at = nil,

    -- Set when the standalone-mode exit task TPs us back to town.
    -- select_dungeon uses this as a floor for its own cooldown so we
    -- don't immediately re-fire a sigil before the zone change settles.
    tp_out_t = nil,
    -- get_time_since_inject() of the last sigil consume (select_dungeon).
    last_sigil_use_t = nil,

    -- Quest-log driven completion latch.  Set by exit.lua the first
    -- time it sees the active NMD quest (DPO_<zone>) -- once we've
    -- "seen" the quest, we know we're committed to a run, and a later
    -- transition to (quest gone) OR (all_complete) is the canonical
    -- run-done signal.
    nmd_quest_seen      = false,
    nmd_quest_complete  = false,
    -- Timestamp the moment quest completion is observed.  exit.lua uses
    -- this to apply a short post-complete grace so loot_chest has time
    -- to grab the Horadric reward before we TP out.
    nmd_quest_complete_t = nil,

    -- Cursed Shrine sub-event tracking (per-shrine, resets on each new
    -- shrine).  Latches:
    --   cursed_started   -- a cursed-shrine quest is in the log
    --                       (we either clicked one or one auto-started)
    --   cursed_complete  -- quest gone OR all objectives state==1
    --                       AND we previously saw it active
    --   cursed_complete_t -- timestamp of completion (used for short
    --                       loot grace before this latch is recycled)
    cursed_started     = false,
    cursed_complete    = false,
    cursed_complete_t  = nil,
    -- (Already-clicked-shrine dedup uses the general `visited` table
    -- via tracker.mark_visited / tracker.is_visited -- no separate
    -- field needed here.)

    -- Ambush event (LE_Ambush_Standard).
    --   ambush_started   -- LE_Ambush quest seen in log (we either spoke
    --                       to the survivor NPC or one auto-triggered)
    --   ambush_anchor    -- player position at the moment we engaged.
    --                       During in_survive_phase we MUST stay near
    --                       this anchor or the event fails.
    --   ambush_complete  -- quest gone OR all_complete after we'd seen
    --                       it active.  Reward chest in stream is looted
    --                       by the existing loot_chest task.
    ambush_started     = false,
    ambush_anchor      = nil,
    ambush_complete    = false,
    ambush_complete_t  = nil,

    run_start_t    = nil,

    current_task   = { name = 'idle', status = 'idle' },
}

tracker.reset_run = function ()
    tracker.visited        = {}
    tracker.current_floor  = 1
    tracker.last_world_id  = nil
    tracker.boss_seen             = false
    tracker.boss_killed_at        = nil
    tracker.dungeon_done          = false
    tracker.boss_room_anchor      = nil
    tracker.hold_quiet_started_at = nil
    tracker.tp_out_t              = nil
    tracker.last_sigil_use_t      = nil
    tracker.nmd_quest_seen        = false
    tracker.nmd_quest_complete    = false
    tracker.nmd_quest_complete_t  = nil
    tracker.cursed_started        = false
    tracker.cursed_complete       = false
    tracker.cursed_complete_t     = nil
    tracker.ambush_started        = false
    tracker.ambush_anchor         = nil
    tracker.ambush_complete       = false
    tracker.ambush_complete_t     = nil
    tracker.run_start_t           = get_time_since_inject and get_time_since_inject() or 0
    tracker.current_task   = { name = 'idle', status = 'idle' }
end

tracker.mark_visited = function (poi)
    if not poi then return end
    local key = string.format('%s:%d:%d',
        poi.skin or poi.kind or '?',
        math.floor(poi.x or 0),
        math.floor(poi.y or 0))
    tracker.visited[key] = true
end

tracker.is_visited = function (poi)
    if not poi then return false end
    local key = string.format('%s:%d:%d',
        poi.skin or poi.kind or '?',
        math.floor(poi.x or 0),
        math.floor(poi.y or 0))
    return tracker.visited[key] == true
end

return tracker
