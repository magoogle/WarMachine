-- activities/hordes/tracker.lua

local tracker = {
    visited         = {},
    current_wave    = 0,
    in_wave         = false,    -- true when monsters are spawning; false at choice phase
    last_pylon_pick = nil,
    run_start_t     = nil,
    -- Run-state flags driving the end-of-run handoff.  Set by their
    -- respective tasks; consumed by exit.lua + WarPlan supervisor.
    boss_killed     = false,    -- detected when a boss-tier actor disappears post-engage
    chest_opened    = false,    -- set after open_chest fires interact_object on the first chest
    run_done        = false,    -- triggers exit task (standalone) / WarPlan Next-Obj
    current_task    = { name = 'idle', status = 'idle' },
}

tracker.reset_run = function ()
    tracker.visited         = {}
    tracker.current_wave    = 0
    tracker.in_wave         = false
    tracker.last_pylon_pick = nil
    tracker.boss_killed     = false
    tracker.chest_opened    = false
    tracker.run_done        = false
    tracker.run_start_t     = get_time_since_inject and get_time_since_inject() or 0
    tracker.current_task    = { name = 'idle', status = 'idle' }
end

tracker.mark_visited = function (poi)
    if not poi then return end
    local key = string.format('%s:%d:%d',
        poi.skin or poi.kind or '?',
        math.floor(poi.x or 0),
        math.floor(poi.y or 0))
    tracker.visited[key] = true
end

return tracker
