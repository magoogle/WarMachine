-- ---------------------------------------------------------------------------
-- activities/nmd/tasks/cursed_shrine.lua
--
-- Cursed Shrine optional sub-event handler.
--
-- Behavior is gated by settings.do_cursed_shrines:
--
--   true  -> click any uninteracted Cursed Shrine in the actor stream.
--            Once clicked, the shrine spawns a mob wave; kill_monster
--            takes over and clears them.  When the event completes, a
--            CursedEventChest_* drops which loot_chest.lua picks up.
--            We also poll the quest log via quest_state.read_cursed_shrine
--            to latch tracker.cursed_started / cursed_complete for the
--            on-screen status overlay.
--
--   false -> never click cursed shrines.  If a shrine was already
--            activated by some other path (proximity trigger in some
--            seasons, or because the user manually clicked it), the
--            existing kill_monster + loot_chest pipeline still finishes
--            it -- we just don't INITIATE the event.
--
-- This task only INITIATES.  Combat + looting are handled by their
-- existing tasks; this one's job is the click-the-shrine step + quest
-- latches.
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local find        = require 'core.find'
local zone        = require 'core.zone'
local settings    = require 'activities.nmd.settings'
local tracker     = require 'activities.nmd.tracker'
local quest_state = require 'activities.nmd.quest_state'

local task = { name = 'cursed_shrine', status = 'idle' }

local INTERACT_RANGE  = 3.0
local SCAN_RADIUS_SQ  = 50 * 50

-- Substring patterns checked (case-insensitive) against actor skin name.
-- D4 cursed-shrine actor skins observed across seasons:
--   `CursedShrine_*`, `Curse_Shrine_*`, `CurseEvent_Shrine_*`.
-- Generous on purpose; we filter further by `is_interactable()`.
local SHRINE_PATTERNS = {
    'cursedshrine',
    'cursed_shrine',
    'curseevent_shrine',
    'curse_shrine',
}

-- Scan stream for an interactable cursed shrine we haven't clicked yet.
-- Returns the actor or nil.
local function find_shrine()
    return find.closest({
        patterns         = SHRINE_PATTERNS,
        require_interactable = true,
        source           = 'all',   -- destructibles / shrines live in get_all_actors
        max_dist_sq      = SCAN_RADIUS_SQ,
        visited          = tracker.visited,
        visited_prefix   = 'cursed',
    })
end

-- Update tracker latches based on the live quest log.  Cheap; called
-- from shouldExecute every pulse.
local function poll_quest_state()
    local q = quest_state.read_cursed_shrine()
    if q then
        tracker.cursed_started = true
        if q.all_complete and not tracker.cursed_complete then
            tracker.cursed_complete   = true
            tracker.cursed_complete_t = get_time_since_inject() or 0
            if settings.debug_mode then
                console.print('[NMD] cursed shrine event complete: ' .. (q.name or '?'))
            end
        end
    else
        -- Quest gone after we'd seen it active = event finished.
        if tracker.cursed_started and not tracker.cursed_complete then
            tracker.cursed_complete   = true
            tracker.cursed_complete_t = get_time_since_inject() or 0
            if settings.debug_mode then
                console.print('[NMD] cursed shrine quest gone -> event complete')
            end
        end
    end
end

task.shouldExecute = function ()
    if not zone.in_dungeon() then return false end
    -- Always poll latches so the overlay reflects state regardless of
    -- whether this task ends up claiming the pulse.
    poll_quest_state()
    -- Setting OFF: never INITIATE.  (Cleanup of an already-started
    -- event still happens via kill_monster + loot_chest.)
    if settings.do_cursed_shrines == false then return false end
    -- Already in/finished one: don't click another shrine on this run
    -- (D4 typically only spawns one cursed shrine per NMD; defensive
    -- guard against multi-shrine zones).
    if tracker.cursed_started and not tracker.cursed_complete then return false end
    return find_shrine() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local shrine = find_shrine()
    if not shrine then task.status = 'no shrine'; return end
    local p = shrine:get_position()
    if not p then return end

    local dx, dy = p:x() - pp:x(), p:y() - pp:y()
    local d = math.sqrt(dx*dx + dy*dy)
    local sn = shrine:get_skin_name() or '?'

    if d <= INTERACT_RANGE then
        -- Don't let orbwalker hijack the click into an attack.
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(shrine)
        -- Mark visited immediately so we don't re-click before the
        -- quest log catches up.
        tracker.visited = tracker.visited or {}
        tracker.visited[find.key_for('cursed', shrine, p)] = true
        if settings.debug_mode then
            console.print('[NMD] activated cursed shrine: ' .. sn)
        end
        task.status = 'activated ' .. sn
        return
    end

    move.to_actor(shrine)
    task.status = string.format('walking to cursed shrine (%.0fm)', d)
end

return task
