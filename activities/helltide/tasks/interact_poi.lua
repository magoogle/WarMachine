-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/interact_poi.lua
--
-- The main task: walk to the highest-priority POI in the queue and click it.
--
-- "POI" = anything from poi_priority.lua's score_poi -- chests, ores, herbs,
-- shrines, pyres, world events.  Movement uses move.lua's 3-tier fallback so
-- we get D4 click-to-walk when the actor's in stream, StaticPather routing
-- when it isn't but its position is known, and Batmobile freeroam when
-- neither tier has data.
-- ---------------------------------------------------------------------------

local move         = require 'core.move'
local tracker      = require 'activities.helltide.tracker'
local settings     = require 'activities.helltide.settings'
local poi_priority = require 'activities.helltide.poi_priority'

local task = { name = 'interact_poi', status = 'idle' }

-- Distance at which we switch from "walking toward" to "trying to click".
local INTERACT_RADIUS = 3.0

-- Find the live actor matching a POI table (so we can call interact_object
-- on the actual game object instead of a stale position).  Match by skin
-- name first, fall back to nearest of same kind within a small radius.
local function live_actor_for(poi)
    if not actors_manager or not actors_manager.get_ally_actors then return nil end
    local candidates = {}
    for _, a in pairs(actors_manager:get_ally_actors()) do
        local sn = a:get_skin_name()
        if sn and (sn == poi.skin or (poi.kind == 'pyre' and sn:find('Pyre_Helltide')))
        then
            local p = a:get_position()
            if p then
                local dx = p:x() - (poi.x or 0)
                local dy = p:y() - (poi.y or 0)
                local d2 = dx*dx + dy*dy
                if d2 < 64 then   -- within 8m of the cataloged position
                    candidates[#candidates + 1] = { a = a, d2 = d2 }
                end
            end
        end
    end
    table.sort(candidates, function (x, y) return x.d2 < y.d2 end)
    if candidates[1] then return candidates[1].a end
    return nil
end

task.shouldExecute = function ()
    -- Yield to higher-priority tasks; this fires whenever we have ANY POI
    -- in the queue (which is most of the time during a helltide hour).
    local q = poi_priority.build(tracker, settings, tracker.in_maiden)
    return q and #q > 0
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local q = poi_priority.build(tracker, settings, tracker.in_maiden)
    local target = q[1]
    if not target then
        task.status = 'no targets'
        return
    end

    local dx = target.x - pp:x()
    local dy = target.y - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    -- Out-of-range: route there.  D4 click-to-walk handles short hops once
    -- the actor's in stream; for cross-zone distances, move.lua uses
    -- StaticPather + host pathfinder, falling back to Batmobile.
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

    -- Within interact radius.  Click if a live actor exists; otherwise the
    -- POI was a stale catalog entry (already opened, wandered off, etc.) --
    -- mark it visited and let the next pulse pick a new target.
    local actor = live_actor_for(target)
    if not actor then
        if settings.debug_mode then
            console.print(string.format(
                '[Helltide] POI %s @(%.1f,%.1f) had no live actor -- marking visited',
                target.kind, target.x, target.y))
        end
        tracker.mark_visited(target)
        task.status = 'stale POI cleared'
        return
    end

    if actor.is_interactable and actor:is_interactable() then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(actor)
        tracker.mark_visited(target)
        task.status = 'interacted: ' .. target.kind
    else
        task.status = 'POI not interactable yet'
    end
end

return task
