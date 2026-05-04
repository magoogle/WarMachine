-- ---------------------------------------------------------------------------
-- activities/pit/tasks/seek_progression.lua
--
-- Pick the next progression POI from the WarPath catalog (pit_floor_portal /
-- pit_exit / dungeon_entrance) and walk toward it via Batmobile.  When no
-- catalog candidate is reachable, yield -- runner.lua's freeroam fallback
-- (core/explorer.lua -> move.explore) drives Batmobile's own exploration
-- until a portal comes into stream and interact_poi / floor_portal grabs it.
-- ---------------------------------------------------------------------------

local move    = require 'core.move'
local zone    = require 'core.zone'
local find    = require 'core.find'
local reach   = require 'core.reach'
local tracker = require 'activities.pit.tracker'

local task = { name = 'seek_progression', status = 'idle' }

local PROGRESSION_KINDS = {
    pit_floor_portal = true,
    pit_exit         = true,
    dungeon_entrance = true,
}
local ENEMY_KINDS = {
    champion = true,
    elite    = true,
    boss     = true,
}
local INTERACT_RADIUS  = 4.0
-- Back-portal blacklist radius (5y squared).  Pit floor descents spawn the
-- player ON TOP of the back portal; without this filter we'd pick it as
-- the closest progression POI and try to re-enter the previous floor.
local BACK_PORTAL_R_SQ = 25
local STUCK_TIMEOUT_S  = 10.0
local STALE_RETRY_S    = 30.0
local PROGRESS_DELTA   = 4.0
local LIVE_PORTAL_NEAR_R = 8.0
local LIVE_PORTAL_PATTERN = 'Portal_Dungeon'
local MAX_CANDIDATE_RANGE = 25.0

-- Reachability budget: cap A* calls per pulse so a long candidate list can't
-- pin the game thread.
local SEEK_REACH_BUDGET = 4

local _stale = {}
local _target_key      = nil
local _target_set_t    = nil
local _last_arrived_dist = nil

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

-- Pick the closest reachable catalog actor matching `kind_set`.
local function pick_closest_kind(pp, now, kind_set)
    local plug = rawget(_G, 'WarPathPlugin') or rawget(_G, 'StaticPatherPlugin')
    if not plug or not plug.get_actors then return nil end
    local ok, actors = pcall(plug.get_actors)
    if not ok or not actors then return nil end

    local candidates = {}
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
                if d <= MAX_CANDIDATE_RANGE then
                    local walkable = true
                    if utility and utility.is_point_walkeable then
                        local probe = vec3:new(a.x or 0, a.y or 0, a.z or pp:z())
                        local sok, w = pcall(utility.is_point_walkeable, probe)
                        walkable = sok and w == true
                    end
                    if walkable then
                        candidates[#candidates + 1] = { actor = a, dist = d, key = key }
                    end
                end
            end
        end
    end
    table.sort(candidates, function (u, v) return u.dist < v.dist end)
    if #candidates == 0 then return nil, math.huge end

    local picked, picked_idx = reach.first_reachable(
        candidates,
        function (c)
            return vec3:new(c.actor.x or 0, c.actor.y or 0, c.actor.z or pp:z())
        end,
        { player_pos = pp, budget = SEEK_REACH_BUDGET }
    )
    if not picked then return nil, math.huge end

    for i = 1, (picked_idx or 0) - 1 do
        _stale[candidates[i].key] = now
    end
    return picked.actor, picked.dist
end

local function pick_closest(pp, now)
    local poi, d = pick_closest_kind(pp, now, PROGRESSION_KINDS)
    if poi then return poi, d end
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

    if _target_key ~= key then
        _target_key            = key
        _target_set_t          = now
        _last_arrived_dist     = task._d
    end

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
        _target_set_t      = now
        _last_arrived_dist = task._d
    end

    move.to_pos({ x = poi.x, y = poi.y, z = poi.z or pp:z() },
                { arrive_radius = INTERACT_RADIUS })
    task.status = string.format('walking to %s @ (%.0f,%.0f) %.0fm',
        poi.kind or '?', poi.x or 0, poi.y or 0, task._d)
end

return task
