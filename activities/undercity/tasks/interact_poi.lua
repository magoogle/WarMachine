-- activities/undercity/tasks/interact_poi.lua

local move         = require 'core.move'
local tracker      = require 'activities.undercity.tracker'
local settings     = require 'activities.undercity.settings'
local poi_priority = require 'activities.undercity.poi_priority'

local INTERACT_RADIUS  = 3.0
-- Live-actor search radius around the catalog point.  Recorded coords
-- can drift several meters from the runtime spawn (beacon physics,
-- pathing nudges, catalog Z snapping) so we accept a generous window
-- before declaring "no actor here."
local LIVE_ACTOR_R     = 12.0
local LIVE_ACTOR_R_SQ  = LIVE_ACTOR_R * LIVE_ACTOR_R
-- Grace window after we arrive in INTERACT_RADIUS of a catalog POI
-- before we declare it stale.  Some enticements load their interactable
-- proxy a beat after the visual prop streams in -- if we instantly
-- mark stale on first arrival we burn through the catalog.
local STALE_GRACE_S    = 2.5

-- Strip dynamic suffixes the recorder sometimes captures (and sometimes
-- doesn't) so a catalog `..._Spirit_Beacon` still matches a runtime
-- `..._Spirit_Beacon_01_Dyn`.  Returns the lowercase trimmed core.
local function skin_core(s)
    if not s then return nil end
    local lower = s:lower()
    -- Drop trailing _<digits> and _dyn suffixes (any number of pairs).
    while true do
        local trimmed = lower:gsub('_dyn$', ''):gsub('_%d+$', '')
        if trimmed == lower then break end
        lower = trimmed
    end
    return lower
end

-- Find the live game actor that corresponds to a catalog POI.
-- Strategy:
--   1. Search both `get_ally_actors` and `get_all_actors` (the recorder
--      doesn't always classify an interactable into the same bucket the
--      runtime puts it in -- live data shows undercity beacons in
--      get_all_actors only).
--   2. Pattern-match on the skin's stable "core" so dynamic _01_Dyn
--      suffixes don't break the match.
--   3. Pick the closest match within LIVE_ACTOR_R of the catalog point.
local function live_actor_for(poi)
    if not actors_manager then return nil end
    local target_core = skin_core(poi.skin)
    if not target_core then return nil end
    local best, best_d2 = nil, math.huge
    local function scan(list)
        if not list then return end
        for _, a in pairs(list) do
            local sn = a.get_skin_name and a:get_skin_name() or nil
            if sn then
                local core = skin_core(sn)
                -- Match either direction: catalog core is a substring of
                -- live skin (catalog had a stripped name) OR live core is
                -- a substring of catalog skin.
                if core and (core:find(target_core, 1, true)
                          or target_core:find(core, 1, true)) then
                    local p = a.get_position and a:get_position() or nil
                    if p then
                        local dx = p:x() - (poi.x or 0)
                        local dy = p:y() - (poi.y or 0)
                        local d2 = dx*dx + dy*dy
                        if d2 < LIVE_ACTOR_R_SQ and d2 < best_d2 then
                            best, best_d2 = a, d2
                        end
                    end
                end
            end
        end
    end
    if actors_manager.get_ally_actors then
        scan(actors_manager:get_ally_actors())
    end
    if actors_manager.get_all_actors then
        scan(actors_manager:get_all_actors())
    end
    return best
end

local task = {
    name = 'interact_poi', status = 'idle',
    interact_t = nil,
    target_key = nil,
    arrive_t   = nil,        -- timestamp when we first reached INTERACT_RADIUS
}

local function next_target()
    local q = poi_priority.build(tracker, settings)
    for _, p in ipairs(q) do
        if p.kind ~= 'undercity_exit' then return p end
    end
    return nil
end

task.shouldExecute = function ()
    return next_target() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local target = next_target()
    if not target then task.status = 'no targets'; return end
    local target_key = string.format('%s:%d:%d',
        target.skin or '?', math.floor(target.x or 0), math.floor(target.y or 0))

    -- Restart timer if target changed
    if task.target_key ~= target_key then
        task.target_key = target_key
        task.interact_t = nil
        task.arrive_t   = nil
    end

    local dx = target.x - pp:x()
    local dy = target.y - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    if d > INTERACT_RADIUS then
        -- Reset arrive timer when we step out of range (e.g. evade
        -- pushed us back) so the grace window restarts on re-arrival.
        task.arrive_t = nil
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

    -- In range.  Click + start timeout.  Enticements have a fixed wait
    -- window after click before we treat them as "done".
    local now = get_time_since_inject() or 0
    if not task.arrive_t then task.arrive_t = now end
    local actor = live_actor_for(target)
    if not actor then
        -- Grace window: live actor sometimes streams in a moment after
        -- we arrive (proxy spawn lag).  Wait a couple seconds before
        -- declaring the catalog entry stale -- otherwise we burn through
        -- the entire enticement list on transient stream gaps.
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
            -- Done waiting; mark visited + bump hearth_count if it was a hearth
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
