-- ---------------------------------------------------------------------------
-- activities/undercity/tracker.lua  --  per-run state.
-- ---------------------------------------------------------------------------

local tracker = {
    visited                  = {},

    -- Floor counter (zone stays X1_Undercity_*; world_id changes per floor)
    current_floor            = 1,
    last_world_id            = nil,

    -- Boss + chest state
    boss_seen                = false,
    boss_seen_at             = nil,    -- monotonic seconds when boss_seen first
                                       -- flipped true.  Used by kill_monster to
                                       -- hold auto-attack for boss_intro_delay
                                       -- so the boss-intro mechanics play out
                                       -- before we start swinging (mirrors the
                                       -- original WonderCity boss_delay gate).
    boss_killed_at           = nil,
    chest_looted             = false,
    chest_looted_t           = nil,    -- monotonic seconds when flipped done;
                                       -- exit gates on core.exit_grace from this.

    -- SpiritHearth_Switch interaction cap (vs unlimited beacons)
    hearth_count             = 0,

    -- Run lifecycle
    run_start_t              = nil,

    current_task             = { name = 'idle', status = 'idle' },
}

tracker.reset_run = function ()
    tracker.visited        = {}
    tracker.current_floor  = 1
    tracker.last_world_id  = nil
    tracker.boss_seen      = false
    tracker.boss_seen_at   = nil
    tracker.boss_killed_at = nil
    tracker.chest_looted   = false
    tracker.chest_looted_t = nil
    tracker.hearth_count   = 0
    tracker.run_start_t    = get_time_since_inject and get_time_since_inject() or 0
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
