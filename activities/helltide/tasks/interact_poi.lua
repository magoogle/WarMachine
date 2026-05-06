-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/interact_poi.lua
--
-- Walk to + click the highest-priority POI in the queue: chests,
-- ores, herbs, shrines, pyres, world-event triggers.
--
-- Movement is delegated to core.move (nav).  At interact range we
-- pause nav so the bot stands still long enough for D4 to register
-- the click and play the open animation -- without pausing, nav's
-- heartbeat keeps walking the player away mid-interact and the chest
-- never opens.
--
-- The POI is only marked visited once the live actor reports
-- is_interactable() == false (chest opened) or disappears from the
-- stream.  Marking visited on the FIRST interact_object call removed
-- the POI from the queue immediately, the picker handed back the next
-- target, and nav started walking away before D4 finished the
-- click.
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local poi_pick    = require 'core.poi_pick'
local live_actor  = require 'core.live_actor'
local tracker     = require 'activities.helltide.tracker'
local settings    = require 'activities.helltide.settings'
local poi_priority = require 'activities.helltide.poi_priority'

local HELLTIDE_BUFF_HASH = 1066539

local function is_in_helltide()
    local lp = get_local_player()
    if not lp or not lp.get_buffs then return false end
    for _, b in ipairs(lp:get_buffs() or {}) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash())
        if hash == HELLTIDE_BUFF_HASH then return true end
    end
    return false
end

local task = { name = 'interact_poi', status = 'idle' }

local INTERACT_RADIUS    = 3.0
local INTERACT_COOLDOWN  = 1.5    -- min seconds between interact_object calls
local INTERACT_GRACE_S   = 4.0    -- give up on this POI after this long without confirmation

local picker = poi_pick.make_picker({
    budget        = 4,
    short_stale_s = 6.0,
})

-- Per-target interact state.  Reset when the picker hands back a new POI.
local _engaged_key       = nil
local _last_interact_t   = -math.huge
local _engage_started_t  = -math.huge

local function poi_key(p)
    return string.format('%s:%d:%d',
        p.skin or p.kind or '?',
        math.floor(p.x or 0),
        math.floor(p.y or 0))
end

-- Helltide-specific live-actor extra-match.  When the catalog says
-- kind='pyre' but the runtime skin is some Pyre_Helltide_* variant
-- the recorder didn't capture verbatim, accept any skin substring-
-- matching 'Pyre_Helltide'.
local function helltide_pyre_fallback(live_skin, poi)
    if poi.kind ~= 'pyre' then return false end
    return live_skin and live_skin:find('Pyre_Helltide', 1, true) ~= nil
end

local function find_helltide_actor(poi)
    return live_actor.find(poi, {
        scan_lists  = 'ally',
        match_mode  = 'exact',
        extra_match = helltide_pyre_fallback,
    })
end

local function reset_engagement()
    if _engaged_key then move.resume() end
    _engaged_key      = nil
    _last_interact_t  = -math.huge
    _engage_started_t = -math.huge
end

-- Yield to combat when adds are close.  Without this, interact_poi
-- (top of helltide's task list, above kill_monster) keeps walking the
-- player past Hellborne / Tortured Gift waves that just spawned, and
-- the bot looks like it "ignored the ambush."  When an enemy is within
-- this radius we return false from shouldExecute; kill_monster then
-- claims the pulse, engages, and as soon as the area clears
-- interact_poi takes back over for the walk.  Engagement-phase
-- (within INTERACT_RADIUS of the POI) keeps priority since move.pause
-- has already been called and we want the chest open animation to
-- finish.
local YIELD_RADIUS = 12.0   -- yards; covers melee + close ranged threats

local function combat_nearby()
    if not target_selector or not target_selector.get_near_target_list then
        return false
    end
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end
    local enemies = target_selector.get_near_target_list(pp, YIELD_RADIUS)
    return enemies and next(enemies) ~= nil
end

task.shouldExecute = function ()
    local q = poi_priority.build(tracker, settings, tracker.in_maiden)
    local target = picker.pick(q)
    if not target then return false end
    -- Mid-engagement (already at the POI, paused, animating) -- don't
    -- yield, kill_monster's preempt would just stutter the open.
    if _engaged_key then return true end
    -- Walking phase: yield to nearby combat so kill_monster anchors us.
    if combat_nearby() then return false end
    return true
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local q = poi_priority.build(tracker, settings, tracker.in_maiden)
    local target = picker.pick(q, { player_pos = pp })
    if not target then
        reset_engagement()
        task.status = 'no reachable POI (exploring)'
        return
    end

    local key = poi_key(target)

    -- New target picked -> drop any prior engagement state.
    if _engaged_key and _engaged_key ~= key then
        reset_engagement()
    end

    local dx = target.x - pp:x()
    local dy = target.y - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    -- Walking phase: deliver the player within INTERACT_RADIUS of the POI.
    if d > INTERACT_RADIUS then
        if _engaged_key == key then reset_engagement() end
        -- Buff dropped while walking: POI is outside the current ring.
        -- Mark it visited so the picker doesn't keep sending us there.
        if not is_in_helltide() then
            tracker.mark_visited(target)
            task.status = target.kind .. ' outside ring -- skipped'
            return
        end
        local actor = find_helltide_actor(target)
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

    -- Within interact radius.
    local actor = find_helltide_actor(target)
    if not actor then
        -- Live actor gone -> the chest was either opened by us a moment
        -- ago (confirms successful interact) or never had a live actor
        -- to begin with (catalog stamp from a prior session).  Either way
        -- mark visited and move on.
        tracker.mark_visited(target)
        reset_engagement()
        task.status = target.kind .. ' opened/cleared'
        return
    end

    -- Begin engagement: pause nav so the bot stands still through
    -- the open animation.  Stamp the engagement timer so we can give up
    -- if the chest never opens (anti-stuck).
    if _engaged_key ~= key then
        _engaged_key      = key
        _engage_started_t = get_time_since_inject() or 0
        _last_interact_t  = -math.huge   -- allow first interact this pulse
        move.pause()
    end

    local now = get_time_since_inject() or 0

    -- Chest opened (or transitioned to non-interactable for any reason).
    -- Mark visited and clean up.
    if not (actor.is_interactable and actor:is_interactable()) then
        tracker.mark_visited(target)
        reset_engagement()
        task.status = target.kind .. ' opened'
        return
    end

    -- Anti-stuck: bot has been at this POI for > INTERACT_GRACE_S without
    -- the chest going non-interactable.  Mark visited, resume, move on.
    if (now - _engage_started_t) > INTERACT_GRACE_S then
        if settings.debug_mode then
            console.print(string.format(
                '[Helltide] %s @ (%.1f,%.1f) interact grace expired',
                target.kind, target.x, target.y))
        end
        tracker.mark_visited(target)
        reset_engagement()
        task.status = target.kind .. ' grace timeout'
        return
    end

    -- Throttled interact.  D4 needs the player to settle before the click
    -- registers; spamming interact_object every pulse reproduces the
    -- "rapid-fire then walk away" symptom.
    if (now - _last_interact_t) >= INTERACT_COOLDOWN then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(actor)
        _last_interact_t = now
        task.status = 'opening ' .. target.kind
    else
        task.status = 'waiting for ' .. target.kind .. ' to open'
    end
end

return task
