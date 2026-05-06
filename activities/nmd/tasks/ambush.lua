-- ---------------------------------------------------------------------------
-- activities/nmd/tasks/ambush.lua
--
-- Lost-Ember Ambush sub-event handler.
--
-- Quest:   LE_Ambush_Standard (id 952963 observed in S09)
-- NPCs:    LE_Ambush_Step_NPC* -- interactable, "Speak to the survivors"
-- Phases:
--   1) Pre-trigger: NPC in stream, quest objective = "Speak to the survivors".
--      Walk to + interact with closest NPC.  Snapshot ambush_anchor.
--   2) Survive: objective text changes to "Survive the ambush"; mob waves
--      spawn around the anchor.  We MUST stay in the area or the event
--      fails.  This task asserts a "stay near anchor" position-hold
--      whenever no enemy is in range; kill_monster preempts when there
--      are mobs to fight.
--   3) Complete: quest disappears from the log.  CursedEventChest-style
--      reward (or a chest_horadric) drops; loot_chest grabs it.
--
-- Behavior is NOT user-toggleable -- once we see the quest active we
-- finish it; ignoring it strands the bot in a "must survive" state with
-- no way to leave the area.  (The user may add a setting later if they
-- want to skip the speak-to-NPC initiation entirely.)
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local find        = require 'core.find'
local zone        = require 'core.zone'
local settings    = require 'activities.nmd.settings'
local tracker     = require 'activities.nmd.tracker'
local quest_state = require 'activities.nmd.quest_state'

local task = { name = 'ambush', status = 'idle' }

local INTERACT_RANGE  = 3.0
local ANCHOR_HOLD_R   = 6.0       -- how close to the anchor we hold during survive
local SCAN_RADIUS_SQ  = 60 * 60

-- Substring patterns matched against actor skin name (case-insensitive).
local NPC_PATTERNS = {
    'le_ambush_step_npc',  -- canonical S09 skin
    'le_ambush_npc',       -- defensive
    'ambush_step_npc',     -- defensive
}

-- Find the closest interactable LE_Ambush survivor NPC.
local function find_npc()
    return find.closest({
        patterns = NPC_PATTERNS,
        require_interactable = true,
        source = 'ally',
        max_dist_sq = SCAN_RADIUS_SQ,
    })
end

-- Compute the "event family prefix" from a quest name -- the first two
-- underscore-separated tokens, lowercased, with a trailing underscore.
-- Examples:
--   DE_RitualofBlood_Demon         -> 'de_ritualofblood_'
--   LE_Ambush_Standard             -> 'le_ambush_'
--   DSQ_Naha_RuinedWild_02         -> 'dsq_naha_'   (matches DSQ_Naha_<*>)
-- The recorded interactable for an event has a skin that starts with
-- the family prefix (case-insensitive), e.g. DE_RitualOfBlood_BloodAltar_Statue
-- starts with 'de_ritualofblood_'.  We use this to find event-specific
-- click-to-progress objects without hardcoding per-event skin lists.
local function event_prefix(quest_name)
    if not quest_name or quest_name == '' then return nil end
    local lower = quest_name:lower()
    -- Find the second '_' separator and cut there.
    local first  = lower:find('_', 1, true)
    if not first then return nil end
    local second = lower:find('_', first + 1, true)
    if not second then return lower .. '_' end
    return lower:sub(1, second)
end

-- Find the closest interactable whose skin starts with the event's
-- family prefix.  Used to click "Investigate the Ritual Statues",
-- "Destroy the X" interactables, and any other generic event objects
-- without hardcoding per-event skin lists.
local function find_event_interactable(quest_name)
    local prefix = event_prefix(quest_name)
    if not prefix then return nil end
    -- find.closest pattern is a substring; we want a prefix match,
    -- but in practice substring works because no other actor skin in
    -- the zone happens to contain the same family prefix.
    return find.closest({
        patterns             = { prefix },
        require_interactable = true,
        source               = 'all',
        max_dist_sq          = SCAN_RADIUS_SQ,
        visited              = tracker.visited,
        visited_prefix       = 'event',
    })
end

-- Pick the best anchor position for the active event.
-- Prefer: closest event-interactable (e.g. the cluster of Ritual Statues).
-- Fallback: player position (so we at least stay in the trigger zone).
local function compute_anchor(quest_name)
    local obj = quest_name and find_event_interactable(quest_name) or nil
    if obj then
        local p = obj:get_position()
        if p then return { x = p:x(), y = p:y() }, obj end
    end
    local lp = get_local_player()
    local pp = lp and lp:get_position() or nil
    if pp then return { x = pp:x(), y = pp:y() }, nil end
    return nil, nil
end

-- Update tracker latches based on the live quest log.  Called each
-- shouldExecute pulse.
local function poll_quest_state()
    local q = quest_state.read_ambush()
    if q then
        if not tracker.ambush_started then
            tracker.ambush_started = true
            -- Snapshot anchor at first sighting.  Prefer the event's
            -- interactable cluster (e.g. Ritual Statue group) so the
            -- anchor sits at the action point rather than the random
            -- spot where the player tripped the trigger zone.
            local anchor, obj = compute_anchor(q.name)
            if anchor then
                tracker.ambush_anchor = anchor
            end
            if settings.debug_mode then
                console.print(string.format(
                    '[NMD] ambush event started: quest=%s anchor=(%.1f,%.1f) at_object=%s',
                    tostring(q.name),
                    anchor and anchor.x or 0,
                    anchor and anchor.y or 0,
                    obj and (obj:get_skin_name() or '?') or 'no'))
            end
        else
            -- Refresh anchor each pulse if a fresh interactable shows
            -- up closer than the original anchor.  Keeps us tied to the
            -- live action point as more statues stream in.
            local obj = find_event_interactable(q.name)
            if obj then
                local p = obj:get_position()
                if p and tracker.ambush_anchor then
                    tracker.ambush_anchor.x = p:x()
                    tracker.ambush_anchor.y = p:y()
                end
            end
        end
        if q.all_complete and not tracker.ambush_complete then
            tracker.ambush_complete   = true
            tracker.ambush_complete_t = get_time_since_inject() or 0
            if settings.debug_mode then
                console.print('[NMD] ambush all-objectives-complete')
            end
        end
    else
        -- Quest gone after we'd seen it active -> event completed.
        if tracker.ambush_started and not tracker.ambush_complete then
            tracker.ambush_complete   = true
            tracker.ambush_complete_t = get_time_since_inject() or 0
            if settings.debug_mode then
                console.print('[NMD] ambush quest gone -> event complete')
            end
        end
    end
end

task.shouldExecute = function ()
    if not zone.in_dungeon() then return false end
    -- Master toggle for events.  When off, this task never fires --
    -- LE_Ambush survivors aren't approached, DE_*/DSQ_* trigger
    -- areas aren't anchored, kill_monster handles whatever's in
    -- range as normal but no special positioning is enforced.
    if settings.do_events == false then return false end
    poll_quest_state()
    -- Pre-trigger: NPC in stream, no quest active yet.  Walk to + click.
    -- ONLY for event types that have an NPC initiation step (LE_Ambush).
    -- DE_*/DSQ_* trigger-area events don't have an NPC -- the quest
    -- appears the moment the player walks into the trigger zone.
    if not tracker.ambush_started then
        return find_npc() ~= nil
    end
    -- During survive phase: hold the anchor IF nothing else needs us
    -- (kill_monster has higher priority and will preempt for mobs).
    if not tracker.ambush_complete then
        if find.any_enemy_in_range(settings.kill_range or 25) then return false end
        -- Only assert anchor-hold for events that have a real survive/wave
        -- phase (objective text contains "survive").  DSQ_* investigation
        -- quests (e.g. ForgottenRemains: examine corpses) have no waves;
        -- yielding here lets interact_poi/kill_monster drive them naturally.
        local q = quest_state.read_event()
        if not q or not q.in_survive_phase then return false end
        return tracker.ambush_anchor ~= nil
    end
    return false
end

task.Execute = function ()
    -- Pre-trigger path: walk to NPC + interact
    if not tracker.ambush_started then
        local npc = find_npc()
        if not npc then task.status = 'no NPC'; return end
        local lp = get_local_player()
        if not lp then return end
        local pp = lp:get_position()
        if not pp then return end
        local p = npc:get_position()
        if not p then return end
        local dx, dy = p:x() - pp:x(), p:y() - pp:y()
        local d = math.sqrt(dx*dx + dy*dy)
        if d <= INTERACT_RANGE then
            if orbwalker and orbwalker.set_clear_toggle then
                orbwalker.set_clear_toggle(false)
            end
            interact_object(npc)
            -- ambush_started + anchor set on next pulse via poll_quest_state.
            task.status = 'speaking to ' .. (npc:get_skin_name() or 'survivor')
            return
        end
        move.to_actor(npc)
        task.status = string.format('walking to survivor (%.0fm)', d)
        return
    end

    -- Survive-phase path.
    --
    -- FIRST priority: any interactable event object nearby (the
    -- "Investigate the Ritual Statues" / "Destroy the X" / "Activate
    -- the Y" mechanics that PROGRESS the event quest).  We detect
    -- these by skin-prefix match against the active event quest's
    -- name (event_prefix + find_event_interactable).
    --
    -- If an event interactable is in stream, walk to + click it.  Each
    -- click marks the actor visited so we cycle through all of them
    -- (typically 3-5 ritual statues / corpse piles / etc.) until the
    -- quest's first objective ticks complete.
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local q = quest_state.read_event()
    local quest_name = q and q.name or nil
    local event_obj = quest_name and find_event_interactable(quest_name) or nil
    if settings.debug_mode then
        local prefix = quest_name and event_prefix(quest_name) or 'nil'
        console.print(string.format(
            '[NMD] ambush survive: quest=%s prefix=%s event_obj=%s',
            tostring(quest_name), tostring(prefix),
            event_obj and (event_obj:get_skin_name() or '?') or 'nil'))
    end
    if event_obj then
        local p = event_obj:get_position()
        if p then
            local dx, dy = p:x() - pp:x(), p:y() - pp:y()
            local d = math.sqrt(dx*dx + dy*dy)
            local sn = event_obj:get_skin_name() or '?'
            if d <= INTERACT_RANGE then
                if orbwalker and orbwalker.set_clear_toggle then
                    orbwalker.set_clear_toggle(false)
                end
                interact_object(event_obj)
                -- Mark visited so we cycle to the next one next pulse.
                tracker.visited = tracker.visited or {}
                tracker.visited[find.key_for('event', event_obj, p)] = true
                task.status = 'investigating ' .. sn
                if settings.debug_mode then
                    console.print('[NMD] event interact: ' .. sn)
                end
                return
            end
            move.to_actor(event_obj)
            task.status = string.format('walking to %s (%.0fm)', sn, d)
            return
        end
    end

    -- No event interactable in stream -> fall back to anchor-hold.
    -- Stop the walker so it doesn't try to wander out of the trigger
    -- zone while we're surviving.
    local wok, walker = pcall(require, 'core.walker')
    if wok and walker and walker.stop then walker.stop() end
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end

    local a = tracker.ambush_anchor
    if not a then return end
    local dx, dy = pp:x() - a.x, pp:y() - a.y
    local d = math.sqrt(dx*dx + dy*dy)
    -- Always assert the anchor as the move target.  move.to_pos returns
    -- 'arrived' and calls move.clear() when d <= arrive_radius, stopping
    -- any residual nav path left over from a previous task.
    move.to_pos({ x = a.x, y = a.y, z = pp:z() }, { arrive_radius = ANCHOR_HOLD_R })
    if d <= ANCHOR_HOLD_R then
        task.status = 'holding ambush anchor'
    else
        task.status = string.format('returning to anchor (%.1fm)', d)
    end
end

return task
