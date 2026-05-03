-- ---------------------------------------------------------------------------
-- activities/undercity/tasks/interact_poi.lua
--
-- Catalog-driven POI clicker for Undercity runs.  Walks to the
-- highest-priority reachable target from poi_priority's queue and
-- interacts with it.  Most plumbing is in shared core/ modules now;
-- this file is just Undercity-specific glue.
--
-- Shared primitives:
--   core/poi_pick.lua    reachability-filtered queue picker
--   core/live_actor.lua  catalog-skin-to-live-actor matcher
--
-- Undercity-specific behavior layered on top:
--   * Combat yield -- enticement clicks spawn mob waves; yield to
--     kill_monster while hostiles are within 15y so the bot fights
--     instead of marching through them to the next catalog POI.
--   * Skip kind='undercity_exit' here -- exit.lua owns that.
--   * STALE_GRACE_S window after arrival before declaring a POI
--     stale -- some interactable proxies stream in a beat after the
--     visual prop, and instant stale-marking burns through the catalog.
--   * Enticement-specific click+wait flow (settings.enticement_timeout
--     bridges the click-to-mob-wave window before we declare done).
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local find        = require 'core.find'    -- any_enemy_in_range for combat yield
local poi_pick    = require 'core.poi_pick'
local live_actor  = require 'core.live_actor'
local tracker     = require 'activities.undercity.tracker'
local settings    = require 'activities.undercity.settings'
local poi_priority = require 'activities.undercity.poi_priority'

local INTERACT_RADIUS = 3.0

-- Live-actor search radius (12m).  Recorded coords drift several
-- meters from runtime spawns due to physics nudges + Z snapping.
local LIVE_ACTOR_R     = 12.0
local LIVE_ACTOR_R_SQ  = LIVE_ACTOR_R * LIVE_ACTOR_R

-- Grace window after arrival before declaring a POI stale.
local STALE_GRACE_S = 2.5

-- Combat-yield range -- yield to kill_monster while hostiles are this
-- close so we engage mobs instead of walking past them.
local COMBAT_YIELD_RANGE_M = 15.0

local picker = poi_pick.make_picker({
    budget        = 4,
    short_stale_s = 6.0,
})

-- Filter out the exit kind here; exit.lua owns that flow.
local function exit_excluded(poi)
    return poi.kind ~= 'undercity_exit'
end

-- Wrap picker.pick with the exit-kind filter.  poi_pick's kind_filter
-- is a whitelist; we want a blacklist of one kind, easiest to do by
-- pre-filtering the queue.
local function build_filtered_queue()
    local q = poi_priority.build(tracker, settings)
    if not q then return nil end
    local out = {}
    for _, p in ipairs(q) do
        if exit_excluded(p) then out[#out + 1] = p end
    end
    return out
end

-- Live-actor lookup tuned for Undercity beacons / hearths -- those
-- live in get_all_actors only, and the recorder strips _Dyn suffixes
-- so we need the 'core' substring match.  12m search radius.
local function find_undercity_actor(poi)
    return live_actor.find(poi, {
        scan_lists  = 'both',
        match_mode  = 'core',
        max_dist_sq = LIVE_ACTOR_R_SQ,
    })
end

local task = {
    name        = 'interact_poi',
    status      = 'idle',
    interact_t  = nil,
    target_key  = nil,
    arrive_t    = nil,        -- timestamp when we first reached INTERACT_RADIUS
}

task.shouldExecute = function ()
    -- Combat yield first.
    if find.any_enemy_in_range(COMBAT_YIELD_RANGE_M) then return false end
    -- Cheap pre-check (no reach test) -- the picker returns the first
    -- non-stale candidate when called without a player_pos.
    local q = build_filtered_queue()
    return picker.pick(q) ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local q = build_filtered_queue()
    local target = picker.pick(q, { player_pos = pp })
    if not target then
        task.status = 'no reachable POI (exploring)'
        return
    end

    local target_key = string.format('%s:%d:%d',
        target.skin or '?', math.floor(target.x or 0), math.floor(target.y or 0))
    if task.target_key ~= target_key then
        task.target_key = target_key
        task.interact_t = nil
        task.arrive_t   = nil
    end

    local dx = target.x - pp:x()
    local dy = target.y - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    if d > INTERACT_RADIUS then
        task.arrive_t = nil
        local actor = find_undercity_actor(target)
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

    -- In range.
    local now = get_time_since_inject() or 0
    if not task.arrive_t then task.arrive_t = now end
    local actor = find_undercity_actor(target)
    if not actor then
        -- Grace window: live actor sometimes streams in a beat after
        -- we arrive.  Wait STALE_GRACE_S before declaring stale.
        if (now - task.arrive_t) < STALE_GRACE_S then
            task.status = string.format('waiting for %s (%.1fs)',
                target.kind, STALE_GRACE_S - (now - task.arrive_t))
            return
        end
        if settings.debug_mode then
            console.print(string.format(
                '[Undercity] stale POI: kind=%s skin=%s pos=(%.1f,%.1f) -- no live actor within %dm after %.1fs',
                tostring(target.kind), tostring(target.skin),
                target.x or 0, target.y or 0,
                LIVE_ACTOR_R, STALE_GRACE_S))
        end
        tracker.mark_visited(target)
        task.target_key = nil
        task.interact_t = nil
        task.arrive_t   = nil
        task.status = 'stale POI cleared'
        return
    end

    if target.kind == 'enticement' then
        if not task.interact_t then
            task.interact_t = now
            if actor.is_interactable and actor:is_interactable() then
                if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
                interact_object(actor)
            end
            task.status = 'interacting (enticement)'
            return
        end
        if (now - task.interact_t) >= settings.enticement_timeout then
            if target.skin and target.skin:find('SpiritHearth_Switch', 1, true) then
                tracker.hearth_count = tracker.hearth_count + 1
            end
            tracker.mark_visited(target)
            task.target_key = nil
            task.interact_t = nil
            if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(true) end
            task.status = 'enticement done'
            return
        end
        task.status = string.format('waiting %.1fs', settings.enticement_timeout - (now - task.interact_t))
        return
    end

    -- Generic interactable (chest / shrine / etc.)
    if actor.is_interactable and actor:is_interactable() then
        if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
        interact_object(actor)
        tracker.mark_visited(target)
        task.target_key = nil
        task.status = 'interacted: ' .. target.kind
    else
        task.status = 'POI not interactable yet'
    end
end

return task
