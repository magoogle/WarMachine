-- ---------------------------------------------------------------------------
-- activities/pit/tasks/seek_progression.lua
--
-- Catalog-driven traversal.  Simple version:
--
--   1. Pick the closest non-stale, non-visited progression POI from the
--      WarPath catalog (pit_floor_portal / pit_exit / dungeon_entrance).
--   2. Set the walker's target to it; walker drives the actual movement
--      (host pathfinder + node-by-node walk + stuck detection).
--   3. If we've been chasing the same target for STUCK_TIMEOUT_S
--      seconds without arriving, that POI is probably unreachable
--      (closed event-door gating its room).  Mark it stale for
--      STALE_RETRY_S, pick the next closest.
--   4. kill_monster (higher in the runner chain) preempts whenever an
--      enemy is in kill_range -- so the bot kills mobs along the way,
--      which is what eventually opens the doors gating the stale POIs.
--
-- This task does NOT pre-validate reachability with the pathfinder --
-- doing that on every catalog entry every pulse is what crashed the
-- game in the previous version.  Instead we trust the walker, observe
-- whether we're making progress, and rotate targets on stall.
-- ---------------------------------------------------------------------------

local move    = require 'core.move'
local zone    = require 'core.zone'
local find    = require 'core.find'
local tracker = require 'activities.pit.tracker'

local task = { name = 'seek_progression', status = 'idle' }

local PROGRESSION_KINDS = {
    pit_floor_portal = true,
    pit_exit         = true,
    dungeon_entrance = true,
}
-- Fallback: when every progression POI is stale (all gated behind
-- closed doors), walk toward the closest catalogued enemy.  Killing
-- catalogued mobs is what eventually opens the doors.  Stuck-detect
-- still applies -- if walker can't reach this enemy either, we mark
-- it stale and try the next-closest.
local ENEMY_KINDS = {
    champion = true,
    elite    = true,
    boss     = true,
}

local INTERACT_RADIUS  = 4.0
-- 25y squared.  Live data showed the catalog's back-portal entry sits
-- ~11y from the player's post-descent spawn, just outside the old 10y
-- radius.  See floor_portal.lua for the same change + rationale.
local BACK_PORTAL_R_SQ = 625
local STUCK_TIMEOUT_S  = 10.0     -- chase a POI for this long before giving up
local STALE_RETRY_S    = 30.0     -- ignore a stale POI for this long
local PROGRESS_DELTA   = 4.0      -- min distance change in STUCK window to count as "moving"
-- "Arrived but no portal here this run" check radius.  Pit floors are
-- procedurally generated -- the catalog has MULTIPLE possible portal
-- coords from different runs, but only ONE actually spawns each run.
-- When we walk to a catalogued coord and there's no live portal within
-- this radius, mark that catalog entry stale and try the next probable
-- spot on the next pulse.
local LIVE_PORTAL_NEAR_R = 8.0
-- Live actor pattern that matches portal-of-any-flavor in the host's
-- actor stream.  Used by has_live_portal_nearby.
local LIVE_PORTAL_PATTERN = 'Portal_Dungeon'
-- Search radius -- intentionally tight per user direction.  25m keeps
-- candidates well within actor-stream range; further entries are
-- almost always noise from other rooms / floors / prior sessions in
-- the merged catalog.  Empirical: pit corridors are ~5-10y wide and
-- room diameters ~20-30y, so 25m covers the typical "next visible
-- progression target" while filtering long-distance backtracks.
local MAX_CANDIDATE_RANGE = 25.0

-- Per-POI stale timestamps: key -> wall_clock_when_marked_stale.  POIs
-- with stale_at + STALE_RETRY_S still in the future are skipped.
-- Lives at module scope (single-instance).
local _stale = {}

-- Current target tracking
local _target_key      = nil
local _target_set_t    = nil
local _last_arrived_check_t = 0
local _last_arrived_dist    = nil

local function poi_key(a)
    return string.format('%s:%d:%d',
        a.skin or '?',
        math.floor(a.x or 0),
        math.floor(a.y or 0))
end

local function in_back_portal_blacklist(a)
    local back = tracker.back_portal_pos
    if not back then return false end
    local dx = (a.x or 0) - back.x
    local dy = (a.y or 0) - back.y
    return (dx*dx + dy*dy) < BACK_PORTAL_R_SQ
end

-- Is there a live portal actor within `radius` of `pp`?  Used by the
-- "arrived but nothing here" detector.
local function has_live_portal_nearby(pp, radius)
    if not actors_manager or not actors_manager.get_all_actors then return false end
    local r2 = radius * radius
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if sn:find(LIVE_PORTAL_PATTERN, 1, true)
           and not sn:find('Light_NoShadows', 1, true)
        then
            local p = a:get_position()
            if p then
                local dx = p:x() - pp:x()
                local dy = p:y() - pp:y()
                if dx*dx + dy*dy <= r2 then return true end
            end
        end
    end
    return false
end

local function is_stale(key, now)
    local t = _stale[key]
    if not t then return false end
    if (now - t) >= STALE_RETRY_S then
        _stale[key] = nil
        return false
    end
    return true
end

-- Closest non-stale, non-visited, non-back-blacklisted catalog entry
-- of any kind in `kind_set`.  Single-pass O(n) over the catalog; no
-- pathfinder calls (those caused the previous crash).
local function pick_closest_kind(pp, now, kind_set)
    if not StaticPatherPlugin or not StaticPatherPlugin.get_actors then return nil end
    local ok, actors = pcall(StaticPatherPlugin.get_actors)
    if not ok or not actors then return nil end
    local best, best_d = nil, math.huge
    for _, a in ipairs(actors) do
        if kind_set[a.kind or ''] then
            local key = poi_key(a)
            if not (tracker.visited and tracker.visited[key])
               and not in_back_portal_blacklist(a)
               and not is_stale(key, now)
            then
                local dx = (a.x or 0) - pp:x()
                local dy = (a.y or 0) - pp:y()
                local d  = math.sqrt(dx*dx + dy*dy)
                -- Filter out far-off entries (out-of-room noise) and
                -- entries whose recorded position isn't actually walkable
                -- terrain (e.g. a portal stub recorded near a wall, or
                -- a stale entry whose Z snapped weirdly).  is_point_walkeable
                -- is the cheap O(1) test the recorder uses; safe to call
                -- per-candidate every pulse.
                if d <= MAX_CANDIDATE_RANGE and d < best_d then
                    local walkable = true
                    if utility and utility.is_point_walkeable then
                        local probe = vec3:new(a.x or 0, a.y or 0, a.z or pp:z())
                        local ok, w = pcall(utility.is_point_walkeable, probe)
                        walkable = ok and w == true
                    end
                    if walkable then best, best_d = a, d end
                end
            end
        end
    end
    return best, best_d
end

-- Two-pass picker: progression POIs first; enemies as fallback.
local function pick_closest(pp, now)
    local poi, d = pick_closest_kind(pp, now, PROGRESSION_KINDS)
    if poi then return poi, d end
    -- Every progression target is stale or filtered -- walk toward the
    -- nearest catalogued enemy so we can fight it and unlock the door
    -- gating the next portal.
    return pick_closest_kind(pp, now, ENEMY_KINDS)
end

task.shouldExecute = function ()
    if not zone.in_pit() then return false end
    if find.any_enemy_in_range(25) then return false end   -- yield to combat
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end
    local now = get_time_since_inject() or 0
    local poi, d = pick_closest(pp, now)
    if not poi then return false end
    if d <= INTERACT_RADIUS then
        -- ARRIVED but the in-stream portal-click task (floor_portal)
        -- didn't preempt -- meaning there's no live portal at this
        -- catalog coord this run.  Mark this catalog entry stale and
        -- let the next pulse pick the next probable spot.  Without
        -- this, we'd just decline, the same catalog entry would be
        -- closest again next pulse, and we'd hover at a dead spot.
        if not has_live_portal_nearby(pp, LIVE_PORTAL_NEAR_R) then
            _stale[poi_key(poi)] = now
        end
        return false
    end
    task._poi = poi
    task._d   = d
    return true
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local now = get_time_since_inject() or 0
    local poi = task._poi
    if not poi then task.status = 'no POI'; return end
    local key = poi_key(poi)

    -- Target switch detection: when the picked POI changes, reset the
    -- stuck-detect window.  Same logic on first acquire.
    if _target_key ~= key then
        _target_key            = key
        _target_set_t          = now
        _last_arrived_check_t  = now
        _last_arrived_dist     = task._d
    end

    -- Stuck detection: if we've been pursuing this POI for STUCK_TIMEOUT_S
    -- AND we haven't closed at least PROGRESS_DELTA yards toward it,
    -- mark it stale (probably behind a closed door) and try a different
    -- POI on the next pulse.  The "next pulse" path will re-pick via
    -- pick_closest skipping the stale entry.
    local elapsed = now - (_target_set_t or now)
    if elapsed >= STUCK_TIMEOUT_S then
        local progressed = _last_arrived_dist and (_last_arrived_dist - task._d) >= PROGRESS_DELTA
        if not progressed then
            _stale[key] = now
            _target_key = nil
            move.clear()
            task.status = string.format('stale %s @ (%.0f,%.0f) -- retry in %ds',
                poi.kind or '?', poi.x or 0, poi.y or 0, STALE_RETRY_S)
            return
        end
        -- We DID make progress -- reset the window so we keep going.
        _target_set_t          = now
        _last_arrived_dist     = task._d
    end

    move.to_pos({ x = poi.x, y = poi.y, z = poi.z or pp:z() },
                { arrive_radius = INTERACT_RADIUS })
    task.status = string.format('walking to %s @ (%.0f,%.0f) %.0fm',
        poi.kind or '?', poi.x or 0, poi.y or 0, task._d)
end

return task
