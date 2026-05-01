-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/return_to_zone.lua
--
-- Get the bot INTO the helltide ring.  Three navigation sources, in
-- preference order:
--
--   1) `tracker.last_in_zone_pos` -- recovery from inside the ring;
--      we wandered out and lost the buff.  Walk back to the last
--      confirmed-inside position.
--
--   2) Maiden path (data/maiden_paths.lua) -- WarPlan typically TPs
--      us to a town WAYPOINT near the helltide region (the user's
--      expected behavior: "We always start in a town near the
--      helltide when we teleport").  Each helltide-adjacent town
--      has a recorded waypoint sequence that walks out of town to
--      the maiden ritual; we replay it waypoint-by-waypoint.  Path
--      data ships with the legacy HelltideRevamped plugin and is
--      loaded at runtime if available.
--
--   3) Closest catalogued helltide POI (StaticPatherPlugin.get_actors)
--      -- last resort when we don't have a recorded path AND we're
--      already in the helltide overworld zone (just outside the ring).
-- ---------------------------------------------------------------------------

local move          = require 'core.move'
local zone          = require 'core.zone'
local tracker       = require 'activities.helltide.tracker'
local maiden_paths  = require 'activities.helltide.data.maiden_paths'

local task = {
    name           = 'return_to_zone',
    status         = 'idle',
    -- Path-following state (option 2).  Cleared when we leave the town
    -- zone or arrive at the end of the path.
    path           = nil,         -- the loaded vec3 array
    path_idx       = 1,           -- current waypoint index
    path_zone      = nil,         -- zone name the path was loaded for
}

-- POI kinds that signal "this is in the helltide ring" (option 3).
local HELLTIDE_POI_KINDS = {
    chest_helltide_random   = true,
    chest_helltide_targeted = true,
    chest_helltide_silent   = true,
    pyre                    = true,
    portal_helltide         = true,
    objective               = true,
}

local WAYPOINT_ARRIVE_R = 4.0     -- when this close, advance to next waypoint

local function is_in_helltide()
    local lp = get_local_player()
    if not lp or not lp.get_buffs then return false end
    for _, b in ipairs(lp:get_buffs() or {}) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash())
        if hash == 1066539 then return true end
    end
    return false
end

local function helltide_active_hour()
    local minute = tonumber(os.date('%M')) or 0
    return minute < 55
end

local function closest_catalog_poi()
    if not StaticPatherPlugin or not StaticPatherPlugin.get_actors then return nil end
    local ok, actors = pcall(StaticPatherPlugin.get_actors)
    if not ok or not actors then return nil end
    local lp = get_local_player()
    if not lp then return nil end
    local pp = lp:get_position()
    if not pp then return nil end
    local px, py = pp:x(), pp:y()
    local best, best_d2 = nil, math.huge
    for _, a in ipairs(actors) do
        if HELLTIDE_POI_KINDS[a.kind or ''] then
            local dx = (a.x or 0) - px
            local dy = (a.y or 0) - py
            local d2 = dx*dx + dy*dy
            if d2 < best_d2 then best, best_d2 = a, d2 end
        end
    end
    return best
end

-- Try to (re-)load the maiden path for the current zone.  Caches the
-- result in task.path so we don't re-require every pulse.  Returns the
-- path table, or nil if no mapping / require failed / not in a path-
-- equipped town zone.
local function ensure_path_for_current_zone()
    local cur = zone.current()
    if not cur then return nil end
    if task.path_zone ~= cur then
        task.path     = maiden_paths.path_for_zone(cur)
        task.path_zone = cur
        task.path_idx = 1
    end
    return task.path
end

task.shouldExecute = function ()
    if is_in_helltide() then
        -- Inside the ring: snapshot the anchor every pulse.
        local lp = get_local_player()
        if lp then tracker.last_in_zone_pos = lp:get_position() end
        -- Also drop any path-following state -- we don't need it inside.
        task.path     = nil
        task.path_zone = nil
        return false
    end
    if not helltide_active_hour() then return false end
    if tracker.last_in_zone_pos then return true end
    if ensure_path_for_current_zone() then return true end
    return closest_catalog_poi() ~= nil
end

task.Execute = function ()
    -- Option 1: recovery anchor (we've been inside, walk back).
    if tracker.last_in_zone_pos then
        move.to_pos(tracker.last_in_zone_pos, { arrive_radius = 5 })
        task.status = 'returning to last in-zone pos'
        return
    end

    -- Option 2: maiden path replay.
    local path = ensure_path_for_current_zone()
    if path then
        local lp = get_local_player()
        local pp = lp and lp:get_position() or nil
        if pp then
            -- Advance through the path: skip waypoints we've already
            -- passed (within WAYPOINT_ARRIVE_R).
            while task.path_idx <= #path do
                local wp = path[task.path_idx]
                local dx = wp:x() - pp:x()
                local dy = wp:y() - pp:y()
                local d  = math.sqrt(dx*dx + dy*dy)
                if d > WAYPOINT_ARRIVE_R then
                    move.to_pos(wp, { arrive_radius = WAYPOINT_ARRIVE_R })
                    task.status = string.format('maiden path %d/%d (%.0fm)',
                        task.path_idx, #path, d)
                    return
                end
                task.path_idx = task.path_idx + 1
            end
            -- Reached end of path.  By now we should be inside the ring;
            -- if not, fall through to catalog seed.
            task.path     = nil
            task.path_zone = nil
        end
    end

    -- Option 3: catalogued helltide POI seed.
    local poi = closest_catalog_poi()
    if not poi then
        task.status = 'no nav seed available'
        return
    end
    local lp = get_local_player()
    local pp = lp and lp:get_position() or nil
    local goal = {
        x = poi.x,
        y = poi.y,
        z = poi.z or (pp and pp:z()) or 0,
    }
    move.to_pos(goal, { arrive_radius = 5 })
    if pp then
        local dx = poi.x - pp:x()
        local dy = poi.y - pp:y()
        local d  = math.sqrt(dx*dx + dy*dy)
        task.status = string.format('seeding to %s (%.0fm)', poi.kind or '?', d)
    else
        task.status = 'seeding to catalog POI'
    end
end

return task
