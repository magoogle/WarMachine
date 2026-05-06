-- ---------------------------------------------------------------------------
-- activities/helltide/tracker.lua  --  per-run state.
--
-- Reset by api.activate() at the start of each helltide session.  Everything
-- mutable lives here so api.deactivate() can wipe it cleanly.
-- ---------------------------------------------------------------------------

local tracker = {
    -- POI dedup: { ["<skin>:<rx>:<ry>"] = true }.  Entries are added when we
    -- successfully interact with a POI so the priority queue stops returning
    -- it.  Reset per-run so chests we couldn't afford last hour are
    -- re-evaluated this hour.
    visited            = {},

    -- Tortured Gift memory: { ["<skin>:<rx>:<ry>"] = { skin, x, y, z } }.
    -- Populated by the live actor scan whenever we see a Tortured Gift,
    -- regardless of affordability.  poi_priority.build re-scores these
    -- every cycle, so a Gift the bot walked past at 50/150 cinders gets
    -- re-queued the moment cinders cross 150.  Entries are pruned when
    -- the bot opens the Gift (visited set takes over).  Reset per-run.
    remembered_gifts   = {},

    -- Maiden state.  Latches when we see the brazier/pyres lit; clears when
    -- we move out of the maiden zone.
    in_maiden          = false,
    maiden_brazier_pos = nil,    -- vec3 of the brazier we're committed to

    -- Throttle for spawn-fetcher / poi-list rebuild
    last_poi_rebuild_t = -math.huge,
    poi_cache          = nil,    -- last priority queue result; reused for ~1s

    -- Active task introspection (set by tasks/init.lua's runner)
    current_task       = { name = 'idle', status = 'idle' },
}

tracker.reset_run = function ()
    tracker.visited            = {}
    tracker.remembered_gifts   = {}
    tracker.in_maiden          = false
    tracker.maiden_brazier_pos = nil
    tracker.last_poi_rebuild_t = -math.huge
    tracker.poi_cache          = nil
    tracker.current_task       = { name = 'idle', status = 'idle' }
end

-- Stamp a Tortured Gift sighting so the priority queue re-scores it on
-- subsequent pulses.  Idempotent on (skin, rounded x/y); already-visited
-- gifts are not re-remembered.
tracker.remember_gift = function (poi)
    if not poi or not poi.skin then return end
    local key = string.format('%s:%d:%d',
        poi.skin,
        math.floor(poi.x or 0),
        math.floor(poi.y or 0))
    if tracker.visited[key] then return end
    tracker.remembered_gifts[key] = {
        skin = poi.skin, x = poi.x, y = poi.y, z = poi.z,
    }
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
