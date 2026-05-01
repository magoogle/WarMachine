-- activities/nmd/tasks/interact_poi.lua

local move         = require 'core.move'
local tracker      = require 'activities.nmd.tracker'
local settings     = require 'activities.nmd.settings'
local poi_priority = require 'activities.nmd.poi_priority'

local INTERACT_RADIUS = 3.0

local function live_actor_for(poi)
    if not actors_manager or not actors_manager.get_ally_actors then return nil end
    local best, best_d = nil, math.huge
    for _, a in pairs(actors_manager:get_ally_actors()) do
        local sn = a:get_skin_name()
        if sn == poi.skin then
            local p = a:get_position()
            if p then
                local dx = p:x() - (poi.x or 0)
                local dy = p:y() - (poi.y or 0)
                local d2 = dx*dx + dy*dy
                if d2 < 64 and d2 < best_d then best, best_d = a, d2 end
            end
        end
    end
    return best
end

local zone = require 'core.zone'

-- How long to wait on a "found but not interactable yet" POI before
-- declaring it stale.  Some POIs (boss-room reward chest) become
-- interactable later in the run; others (consumed Receptacle, used
-- shrine) NEVER become interactable again.  We wait this long, then
-- stale-mark either way -- if the POI was supposed to become
-- interactable later, we'll re-encounter it on a future pulse after
-- visited-dedup expiration (or it'll become a fresh POI when the
-- catalog entry's coordinates change).
local WAIT_INTERACTABLE_TIMEOUT_S = 6.0

local task = {
    name             = 'interact_poi',
    status           = 'idle',
    -- Tracks (target_key, first_seen_t) for "waiting on interactable"
    -- timeout. Reset when the picked target changes.
    waiting_key      = nil,
    waiting_first_t  = nil,
}

task.shouldExecute = function ()
    -- POI scoring uses StaticPatherPlugin.get_actors() which returns the
    -- current zone's catalog.  In town that'd be town objectives /
    -- chests / shrines, none of which we want to interact with from
    -- the NMD activity.  Restrict to DGN_*.
    if not zone.in_dungeon() then return false end
    return #poi_priority.build(tracker, settings) > 0
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local q = poi_priority.build(tracker, settings)
    local target = q[1]
    if not target then task.status = 'no targets'; return end

    local dx = target.x - pp:x()
    local dy = target.y - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    if d > INTERACT_RADIUS then
        local actor = live_actor_for(target)
        if actor then
            move.to_actor(actor)
            task.status = string.format('walking to %s (%.0fm)', target.kind, d)
        else
            local goal = vec3:new(target.x, target.y, target.z or pp:z())
            move.to_pos(goal, INTERACT_RADIUS)
            task.status = string.format('routing to %s (%.0fm)', target.kind, d)
        end
        return
    end

    local actor = live_actor_for(target)
    if not actor then
        tracker.mark_visited(target)
        task.status = 'stale POI cleared'
        return
    end
    if actor.is_interactable and actor:is_interactable() then
        if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
        interact_object(actor)
        tracker.mark_visited(target)
        task.waiting_key     = nil
        task.waiting_first_t = nil
        task.status = 'interacted: ' .. target.kind
    else
        -- Found but not interactable yet.  Track how long we've been
        -- waiting; if the POI never becomes interactable (consumed
        -- Receptacle, used shrine, etc.) we stale-mark it after the
        -- timeout so the runner can move on.  Without this, a single
        -- consumed receptacle would block all subsequent tasks
        -- (kill_monster never gets a turn).
        local now = get_time_since_inject() or 0
        local key = string.format('%s:%d:%d',
            target.skin or target.kind or '?',
            math.floor(target.x or 0),
            math.floor(target.y or 0))
        if task.waiting_key ~= key then
            task.waiting_key     = key
            task.waiting_first_t = now
        end
        local elapsed = now - (task.waiting_first_t or now)
        if elapsed >= WAIT_INTERACTABLE_TIMEOUT_S then
            tracker.mark_visited(target)
            task.waiting_key     = nil
            task.waiting_first_t = nil
            task.status = 'stale (never became interactable): ' .. target.kind
        else
            task.status = string.format('waiting interactable (%.1fs): %s',
                WAIT_INTERACTABLE_TIMEOUT_S - elapsed, target.kind)
        end
    end
end

return task
