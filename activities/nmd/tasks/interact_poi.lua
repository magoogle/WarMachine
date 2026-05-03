-- activities/nmd/tasks/interact_poi.lua
--
-- Catalog-driven POI clicker for nightmare dungeons.  Walks to the
-- highest-priority reachable target from poi_priority's queue and
-- interacts with it.  Most of the heavy lifting is in shared core/
-- modules now -- this file is just NMD-specific glue.
--
-- Shared primitives used:
--   core/poi_pick.lua    reachability-filtered queue picker (A*-budget
--                        + soft-stale ledger; ditches catalog entries
--                        the host pathfinder can't currently route to)
--   core/live_actor.lua  catalog-skin-to-live-actor matcher (dual-scan,
--                        skin-core substring -- handles _Dyn suffix
--                        variants)
--
-- NMD-specific behavior layered on top:
--   * Restrict to in-dungeon zones (skip when in town)
--   * Wait WAIT_INTERACTABLE_TIMEOUT_S for "found but not interactable
--     yet" before stale-marking; matches NMD's gating pattern where
--     the boss-room reward chest is in stream early but only becomes
--     interactable after the boss dies.

local move        = require 'core.move'
local zone        = require 'core.zone'
local poi_pick    = require 'core.poi_pick'
local live_actor  = require 'core.live_actor'
local tracker     = require 'activities.nmd.tracker'
local settings    = require 'activities.nmd.settings'
local poi_priority = require 'activities.nmd.poi_priority'

local INTERACT_RADIUS = 3.0

-- How long to wait on a "found but not interactable yet" POI before
-- declaring it stale.  Some POIs (boss-room reward chest) become
-- interactable later in the run; others (consumed Receptacle, used
-- shrine) NEVER become interactable again.  After the timeout we
-- stale-mark either way.
local WAIT_INTERACTABLE_TIMEOUT_S = 6.0

-- Per-task picker instance -- own soft-stale ledger so unreachable
-- entries marked here don't bleed into other activities.
local picker = poi_pick.make_picker({
    budget        = 4,
    short_stale_s = 6.0,
})

local task = {
    name             = 'interact_poi',
    status           = 'idle',
    waiting_key      = nil,
    waiting_first_t  = nil,
}

task.shouldExecute = function ()
    -- POI scoring uses the WarPath actor catalog which returns the
    -- current zone's catalog.  In town that'd be town objectives /
    -- chests / shrines, none of which we want to interact with from
    -- the NMD activity.  Restrict to DGN_*.
    if not zone.in_dungeon() then return false end
    -- Cheap pre-check (no reach test, no player-pos requirement) --
    -- the picker returns the first non-stale candidate when called
    -- without a player_pos.
    local q = poi_priority.build(tracker, settings)
    return picker.pick(q) ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local q = poi_priority.build(tracker, settings)
    local target = picker.pick(q, { player_pos = pp })
    if not target then
        -- Nothing currently reachable.  Yield so kill_monster /
        -- freeroam takes the pulse and the bot explores until the
        -- path opens up.
        task.status = 'no reachable POI (exploring)'
        return
    end

    local dx = target.x - pp:x()
    local dy = target.y - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    if d > INTERACT_RADIUS then
        local actor = live_actor.find(target)
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

    -- In interact range.
    local actor = live_actor.find(target)
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
        -- waiting; stale-mark after the timeout so kill_monster / next
        -- POI gets a turn.
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
