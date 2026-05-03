-- ---------------------------------------------------------------------------
-- activities/pit/tracker.lua  --  per-run state.
--
-- Reset by api.activate().  Mostly mirrors the helltide tracker shape; the
-- pit-specific bits are floor counter + back-portal blacklist (so we don't
-- re-take the portal we just came through after a floor descent).
-- ---------------------------------------------------------------------------

local tracker = {
    -- Per-run dedup: { ["<skin>:<rx>:<ry>"] = true }.  Reset on activate.
    visited            = {},

    -- Floor counter.  Pit floors don't change zone names (zone stays
    -- 'PIT_Subzone'), only world_id; we increment this on each portal
    -- traversal so logs and the priority-queue can scope per-floor.
    current_floor      = 1,
    last_world_id      = nil,
    last_world_change_t = nil,

    -- Back-portal blacklist.  After we teleport to a new floor the player
    -- spawns ON TOP of the portal we just came through.  Without a guard,
    -- the bot would step right back onto it.  We snapshot the spawn
    -- position on each world change and exclude any portal within 10y.
    back_portal_pos    = nil,
    portal_just_used   = false,
    portal_used_t      = nil,

    -- Boss + glyph state
    boss_seen          = false,    -- boss appeared in stream this floor
    boss_killed_at     = nil,      -- get_time_since_inject() of the kill
    glyph_done         = false,    -- final-floor glyph upgrade processed
    glyph_done_t       = nil,      -- monotonic seconds when flipped done;
                                   -- exit gates on core.exit_grace from this.

    -- Run lifecycle
    run_start_t        = nil,
    chest_looted       = false,    -- end-of-run reward chest
    chest_looted_t     = nil,      -- monotonic seconds when flipped done.

    -- Active task introspection (set by tasks/runner.lua)
    current_task       = { name = 'idle', status = 'idle' },
}

tracker.reset_run = function ()
    tracker.visited            = {}
    tracker.current_floor      = 1
    tracker.last_world_id      = nil
    tracker.last_world_change_t = nil
    tracker.back_portal_pos    = nil
    tracker.portal_just_used   = false
    tracker.portal_used_t      = nil
    tracker.boss_seen          = false
    tracker.boss_killed_at     = nil
    tracker.glyph_done         = false
    tracker.glyph_done_t       = nil
    tracker.run_start_t        = get_time_since_inject and get_time_since_inject() or 0
    tracker.chest_looted       = false
    tracker.chest_looted_t     = nil
    tracker.current_task       = { name = 'idle', status = 'idle' }
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
