-- ---------------------------------------------------------------------------
-- activities/nmd/tasks/campfire_event.lua
--
-- "Click to start" handler for ACD_ME_* Map Event actors (campfires and
-- similar world-event triggers).  These appear as interactable actors in
-- the stream; clicking one starts the event (mob waves spawn, objectives
-- appear in the quest log).
--
-- This task handles ONLY the pre-start interaction.  Once the actor is
-- no longer interactable the event has started and the ambush task takes
-- over for anchor-hold and survive-phase handling.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local find     = require 'core.find'
local zone     = require 'core.zone'
local settings = require 'activities.nmd.settings'
local tracker  = require 'activities.nmd.tracker'

local task = { name = 'campfire_event', status = 'idle' }

local INTERACT_RANGE = 3.0
local SCAN_RADIUS_SQ = 60 * 60

local CAMPFIRE_PATTERNS = {
    'acd_me_',    -- ACD_ME_Campfire and other Map Event interactables
}

local function find_campfire()
    return find.closest({
        patterns             = CAMPFIRE_PATTERNS,
        require_interactable = true,
        source               = 'all',
        max_dist_sq          = SCAN_RADIUS_SQ,
    })
end

task.shouldExecute = function ()
    if not zone.in_dungeon() then return false end
    if settings.do_events == false then return false end
    -- Yield to ambush survive phase once the event has been triggered.
    if tracker.ambush_started and not tracker.ambush_complete then return false end
    return find_campfire() ~= nil
end

task.Execute = function ()
    local actor = find_campfire()
    if not actor then task.status = 'no campfire actor'; return end
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local p = actor:get_position()
    if not p then return end
    local sn = actor:get_skin_name() or 'campfire'
    local dx, dy = p:x() - pp:x(), p:y() - pp:y()
    local d = math.sqrt(dx*dx + dy*dy)
    if d <= INTERACT_RANGE then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(actor)
        task.status = 'activating ' .. sn
        return
    end
    move.to_actor(actor)
    task.status = string.format('walking to %s (%.0fm)', sn, d)
end

return task
