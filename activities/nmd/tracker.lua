-- activities/nmd/tracker.lua  --  per-run state.

local tracker = {
    visited        = {},
    current_floor  = 1,
    last_world_id  = nil,

    boss_seen      = false,
    boss_killed_at = nil,
    dungeon_done   = false,    -- objective fully cleared

    run_start_t    = nil,

    current_task   = { name = 'idle', status = 'idle' },
}

tracker.reset_run = function ()
    tracker.visited        = {}
    tracker.current_floor  = 1
    tracker.last_world_id  = nil
    tracker.boss_seen      = false
    tracker.boss_killed_at = nil
    tracker.dungeon_done   = false
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
