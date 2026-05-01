-- ---------------------------------------------------------------------------
-- activities/nmd/tasks/loot_chest.lua
--
-- Loot Horadric (and similar) chests directly from the live actor stream.
--
-- Why a dedicated task instead of letting poi_priority handle it:
--   * NMD's poi_priority builds its queue from StaticPatherPlugin.get_actors(),
--     which reads the merged static zone catalog.  The Horadric chest skin
--     in S09 (`S09_Horadric_Common_Chest_02_Dyn`) is NOT classified by
--     WarMapRecorder/core/actor_capture.lua, so it's never recorded into
--     the catalog.  Result: the chest exists in the live stream but
--     poi_priority never sees it -> never looted.
--   * Recording new patterns into the catalog has a multi-hour cycle
--     (record -> upload -> server merge -> client sync).  That fix is
--     in flight (see actor_capture.lua), but this task gets the bot
--     looting RIGHT NOW from the live stream, no catalog needed.
--
-- Pattern list is generous on purpose: covers S09 specifically and any
-- future "Horadric" or "Tribute_Chest" / generic-loot variant the
-- recorder hasn't catalogued yet.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local find     = require 'core.find'
local zone     = require 'core.zone'
local settings = require 'activities.nmd.settings'
local tracker  = require 'activities.nmd.tracker'

local task = {
    name = 'loot_chest',
    status = 'idle',
    -- Per-target click state.  Cleared when the actor flips
    -- non-interactable (= opened) or we time out.
    target_key   = nil,
    last_click_t = nil,
    click_count  = 0,
    first_click_t = nil,
}

local INTERACT_RADIUS  = 3.0
local SCAN_RADIUS_SQ   = 60 * 60   -- only consider chests within 60y
local CLICK_COOLDOWN_S = 1.0       -- min gap between repeated clicks
local CLICK_TIMEOUT_S  = 8.0       -- give up + mark visited after this

-- Substring patterns (case-insensitive) checked against actor skin name.
-- If you add a pattern here, also consider adding it to
-- WarMapRecorder/core/actor_capture.lua so the static catalog catches up.
local CHEST_PATTERNS = {
    'horadric',          -- S09_Horadric_Common_Chest_02_Dyn etc.
    'tribute_chest',     -- pit-style tribute chest (just in case it shows up)
    'lootchest',         -- generic loot chests (already in actor_capture, but safe)
    'rewardchest',       -- generic reward chests
    'chest_generic',
    'cursedeventchest',  -- Cursed Shrine reward chest (drops on event complete)
    'cursedevent_chest', -- defensive variant
    'cursed_event_chest',
    'eventchest',        -- generic event-reward chest, e.g. EventChestRare
                         -- (drops on LE_/DE_/DSQ_ event completion).  We
                         -- watch the quest log for completion (quest gone
                         -- == event over) but always loot whatever
                         -- *EventChest* lands in stream.
    'event_chest',       -- defensive separator variant
    -- Broader catches added after live data showed
    -- Hatred_Prop_Chest_Rare_01_Dyn_TreasureRoom going unmatched.
    'prop_chest',        -- Hatred_Prop_Chest_*, Drowned_Prop_Chest_*, etc.
    'treasureroom',      -- *_TreasureRoom suffixes
    'treasure_room',     -- alt separator
    'common_chest',      -- *_Common_Chest_* (S09 variants)
    'rare_chest',        -- *_Rare_Chest_*
    'sacred_chest',      -- *_Sacred_Chest_*
    'silent_chest',      -- *_Silent_Chest_*
}

local function find_chest()
    -- 'all' not 'ally': D4 puts chests / lootables / interactable
    -- destructibles in get_all_actors() (the same list the recorder
    -- scans).  get_ally_actors() is for friendly NPCs and doesn't
    -- always include chests -- live data confirms Horadric chests
    -- show up in get_all_actors only.  Was the user-visible "walked
    -- to the chest but didn't open it" bug -- find_chest scanning
    -- ally_actors returned nil so loot_chest declined and interact_poi
    -- (which only sees catalog entries) went idle.
    return find.closest({
        patterns         = CHEST_PATTERNS,
        require_interactable = true,
        source           = 'all',
        max_dist_sq      = SCAN_RADIUS_SQ,
        visited          = tracker.visited,
        visited_prefix   = 'chest',
    })
end

task.shouldExecute = function ()
    if settings.do_chests == false then return false end   -- nil = default on
    -- Only loot inside dungeons.  In town this task would happily walk
    -- the bot to every armory / stash / bench because their skins also
    -- contain 'LootChest' / 'GizmoLootChest'.
    if not zone.in_dungeon() then return false end
    return find_chest() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local chest = find_chest()
    if not chest then
        -- find_chest filters out visited entries, so if it's nil we
        -- have nothing to loot in range.  Reset per-target state.
        task.target_key   = nil
        task.last_click_t = nil
        task.click_count  = 0
        task.first_click_t = nil
        task.status = 'no chest'
        return
    end

    local p = chest:get_position()
    if not p then return end
    local dx, dy = p:x() - pp:x(), p:y() - pp:y()
    local d = math.sqrt(dx*dx + dy*dy)
    local sn = chest:get_skin_name() or '?'
    local now = get_time_since_inject() or 0
    local key = find.key_for('chest', chest, p)

    -- Reset click counters when the target changes (new chest).
    if task.target_key ~= key then
        task.target_key    = key
        task.last_click_t  = nil
        task.click_count   = 0
        task.first_click_t = nil
    end

    if d > INTERACT_RADIUS then
        move.to_actor(chest)
        task.status = string.format('walking to %s (%.0fm)', sn, d)
        return
    end

    -- In range.  Retry clicks on cooldown until the actor flips
    -- non-interactable (= opened/looted).  D4's interact_object is
    -- best-effort -- a single click sometimes doesn't register,
    -- especially when the player is still settling into position
    -- after the walk-up.  This was the user-reported "walked to it
    -- but didn't open it" symptom.

    -- Success detection: if the live actor is no longer interactable,
    -- the chest is open.  Mark visited and clear state.
    if not (chest.is_interactable and chest:is_interactable()) then
        tracker.visited = tracker.visited or {}
        tracker.visited[key] = true
        if settings.debug_mode then
            console.print(string.format(
                '[NMD] chest opened: %s (%d clicks)', sn, task.click_count or 0))
        end
        task.target_key    = nil
        task.last_click_t  = nil
        task.click_count   = 0
        task.first_click_t = nil
        task.status = 'opened ' .. sn
        return
    end

    -- Timeout: been clicking for CLICK_TIMEOUT_S without success.
    -- Mark visited (to skip on next pulse) and move on.  The chest
    -- might be unreachable due to some host-side issue.
    if task.first_click_t and (now - task.first_click_t) >= CLICK_TIMEOUT_S then
        tracker.visited = tracker.visited or {}
        tracker.visited[key] = true
        if settings.debug_mode then
            console.print(string.format(
                '[NMD] chest click timeout, skipping: %s (%d clicks)',
                sn, task.click_count or 0))
        end
        task.target_key    = nil
        task.last_click_t  = nil
        task.click_count   = 0
        task.first_click_t = nil
        task.status = 'timeout ' .. sn
        return
    end

    -- Cooldown gate: click again every CLICK_COOLDOWN_S until success
    -- or timeout.
    if not task.last_click_t or (now - task.last_click_t) >= CLICK_COOLDOWN_S then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(chest)
        task.last_click_t  = now
        task.click_count   = (task.click_count or 0) + 1
        task.first_click_t = task.first_click_t or now
        if settings.debug_mode then
            console.print(string.format(
                '[NMD] click #%d on %s', task.click_count, sn))
        end
    end
    task.status = string.format('clicking %s (#%d)', sn, task.click_count or 0)
end

return task
