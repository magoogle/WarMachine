-- ---------------------------------------------------------------------------
-- activities/nmd/quest_state.lua
--
-- Reads the active Nightmare Dungeon quest from the host's get_quests()
-- API.  Used by exit.lua to detect run completion via the canonical game
-- signal -- the quest objective(s) flipping to state==1 -- instead of
-- inferring it from "boss dropped out of the actor stream + N seconds
-- of quiet" which gets confused by invuln phases, untargetable adds,
-- and dungeons whose objective is something other than a boss kill
-- (e.g. "Activate 3 pylons", "Cleanse the Heart", etc.).
--
-- D4's quest object has:
--   q:get_name()       -> internal name (e.g. "DRLG_QST_..." for NMD)
--   q:get_objectives() -> list of { text = string, state = number }
--
-- State encoding observed in S09:
--   state == 1                  -> objective complete
--   state == 16777216 (0x01000000) -> in-progress / not complete
-- Any non-1 state is treated as incomplete.
--
-- The NMD quest-name match is generous on purpose -- season prefixes
-- (S07/S09/...) come and go and Blizzard sometimes reskins the procedural-
-- dungeon quest backbone.  If a future season ships an NMD quest whose
-- name doesn't match these patterns, add it here.
-- ---------------------------------------------------------------------------

local M = {}

local STATE_COMPLETE = 1

-- Substring patterns (case-insensitive on the quest name) that identify
-- a Nightmare Dungeon quest.  Captured from a live NMD run via QQT eval:
--   'DPO_Step_CarrionFields'        <- per-dungeon procedural objective.
--                                      One per zone, prefix `DPO_<zone>`.
--                                      THIS is the canonical run-progress
--                                      quest -- objectives flip to state==1
--                                      as the dungeon's tasks complete.
--   'DOV_Nightmare_RareMaterial'    <- season Nightmare overlay quest.
--   'Warplans_Controller_QST_NMD'   <- WarPlan controller (no objectives).
--
-- We prefer DPO (the actual dungeon's quest) when multiple match.  The
-- other patterns are kept as a defensive net for season variants.
local NMD_QUEST_PATTERNS = {
    'dpo_',              -- Dungeon Procedural Objective (PRIMARY)
    'drlg_qst',          -- defensive: backbone quest in some seasons
    'nightmare',         -- DOV_Nightmare_* season overlays
    'nmd_qst',           -- defensive: future renamings
    'qst_dungeon_',      -- defensive
}

-- Returns (true, priority_index) if the quest name matches, where lower
-- index = higher priority (e.g. 'dpo_' beats 'nightmare').  Used by
-- read_active to pick the most-specific NMD quest when multiple match.
local function match_priority(name)
    if not name then return false end
    local lname = name:lower()
    for i, pat in ipairs(NMD_QUEST_PATTERNS) do
        if lname:find(pat, 1, true) then return true, i end
    end
    return false
end

-- Returns a snapshot of the currently-active NMD quest, or nil.
--   {
--     name         = string,
--     id           = number?,
--     objectives   = { { text, state }, ... },
--     all_complete = bool,        -- every objective state == 1
--     any_complete = bool,        -- at least one objective state == 1
--   }
-- ---------------------------------------------------------------------------
-- Cursed Shrine sub-event detection.
--
-- D4 Cursed Shrines are an optional NMD sub-event: click the shrine,
-- mob waves spawn, killing them all completes the event and drops a
-- `CursedEventChest_*` reward.  The shrine click adds a sub-quest to
-- the player's log; we use that quest's presence to know we're "in"
-- the event, and its disappearance (or all-objectives-complete) plus
-- the reward chest in stream to know it's done.
--
-- Quest-name patterns are inferred from D4 conventions -- captured
-- examples (S07-S09): `Curses_QST_<id>`, `CurseEvent_QST_*`, plus
-- generic `_Curse_` / `_CursedShrine_` substrings.  Generous on purpose
-- because Blizzard occasionally renames event quests across seasons.
-- ---------------------------------------------------------------------------
local CURSED_QUEST_PATTERNS = {
    'curses_qst',     -- observed: `Curses_QST_<n>`
    'curse_qst',      -- defensive variant
    'curseevent',     -- alt prefix
    'cursedshrine',
    'cursed_shrine',
    '_curse_',        -- substring catch-all
}

local function match_cursed(name)
    if not name then return false end
    local l = name:lower()
    for _, pat in ipairs(CURSED_QUEST_PATTERNS) do
        if l:find(pat, 1, true) then return true end
    end
    return false
end

-- Returns a snapshot of the active cursed-shrine quest, or nil:
--   { name, objectives = { {text, state}, ... }, all_complete }
-- "Active but no objectives yet" returns all_complete = false (the
-- quest exists in the log but D4 hasn't populated objectives yet --
-- usually a 1-frame state right after click).
-- ---------------------------------------------------------------------------
-- Ambush event detection (LE_Ambush_Standard).
--
-- D4 Lost-Ember Ambush sub-events spawn inside some NMD floors with NPC
-- actors named `LE_Ambush_Step_NPC*`.  The quest is named
-- `LE_Ambush_Standard` (id 952963 observed); first objective text is
-- "Speak to the survivors" until interaction, then changes to "Survive
-- the ambush" while waves spawn.  Player cannot leave the area without
-- failing the event.  When the quest disappears we know the event is
-- complete and any reward chest can be looted.
-- ---------------------------------------------------------------------------
-- D4 events register under several quest-name prefixes.  Live captures
-- so far (S09):
--   LE_Ambush_Standard         <- "Local Event" Ambush (NPC-led: speak
--                                  to survivors, then survive waves)
--   DE_RitualofBlood_Demon     <- "Dungeon Event" (trigger-area: walk
--                                  in, mobs spawn, kill them all)
--   DSQ_<zone>_<n>             <- "Dungeon Side Quest" (variable;
--                                  some are events, some are
--                                  scripted bosses)
--
-- We treat all three as "events" for the purpose of the do_events
-- toggle + the anchor-and-kill behavior.  LE_Ambush gets the
-- additional NPC-click initiation step; DE_* / DSQ_* skip straight
-- to the anchor phase since the player is already inside the trigger
-- zone when the quest appears.
--
-- IMPORTANT: these are ANCHORED PREFIXES (matched at position 1 of
-- the lowercased quest name), NOT substrings.  The previous build
-- used substring matching which caused 'de_' to fire on any quest
-- name containing the substring `de_` -- e.g. anything with `Side_`
-- (lowercase `side_` contains `de_`!), which is essentially every
-- NMD with a season side-quest in the log.  Result: the ambush task
-- triggered the instant the bot loaded into a nightmare -- the
-- user-reported "why does it think we are in an ambush event?  i
-- just walked into a nightmare" symptom.
local EVENT_QUEST_PREFIXES = {
    'le_ambush',        -- LE_Ambush_Standard etc.  (NPC initiation)
    'de_',              -- DE_<EventName>_<Variant>
    'dsq_',             -- DSQ_<zone>_<n>
    'me_',              -- ME_<EventName> Map Events (campfire, etc.)
    'localevent_',      -- defensive
    'worldevent_',      -- overworld events (mostly helltide, but harmless here)
}

-- Substring catches for ambush-family quests whose names don't start
-- with `le_ambush` (e.g. season-prefixed variants `S09_LE_Ambush_*`).
-- Kept narrow on purpose -- both terms are uniquely identifying.
local EVENT_QUEST_SUBSTRINGS = {
    '_le_ambush',
    'ambush_qst',
}

-- Quest-name prefixes that REQUIRE an NPC click to initiate (the
-- ambush "Speak to the survivors" pattern).  Other event types
-- self-trigger when the player walks into the trigger area.
local EVENT_NEEDS_NPC = {
    'le_ambush',
    '_ambush_',
}

local function match_event(name)
    if not name then return false end
    local l = name:lower()
    for _, pat in ipairs(EVENT_QUEST_PREFIXES) do
        if l:sub(1, #pat) == pat then return true end
    end
    for _, pat in ipairs(EVENT_QUEST_SUBSTRINGS) do
        if l:find(pat, 1, true) then return true end
    end
    return false
end

local function event_needs_npc(name)
    if not name then return false end
    local l = name:lower()
    for _, pat in ipairs(EVENT_NEEDS_NPC) do
        if l:find(pat, 1, true) then return true end
    end
    return false
end

-- Backward-compat alias so any caller still using the old name keeps
-- working.  Prefer match_event in new code.
local match_ambush = match_event

-- Returns a snapshot of the active local-event quest, or nil:
--   { name, objectives, all_complete, in_survive_phase, needs_npc }
-- in_survive_phase is true once the objective text contains 'survive'
-- (or similar in-progress hints) -- means we've triggered the event
-- and must STAY in the area to complete it.
-- needs_npc is true for LE_Ambush-style events that require clicking
-- an NPC first; false for DE_*/DSQ_*-style trigger-area events.
--
-- Aliased as `M.read_ambush` for backward compat with existing callers.
M.read_event = function ()
    if not get_quests then return nil end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return nil end
    for _, q in pairs(quests) do
        if q and q.get_name then
            local nok, name = pcall(function () return q:get_name() end)
            if nok and match_ambush(name) then
                local objs = nil
                if q.get_objectives then
                    local ook, list = pcall(function () return q:get_objectives() end)
                    if ook then objs = list end
                end
                local objectives, all_done = {}, true
                local in_survive = false
                for _, o in ipairs(objs or {}) do
                    objectives[#objectives + 1] = { text = o.text, state = o.state }
                    if o.state ~= STATE_COMPLETE then all_done = false end
                    if o.text and o.text:lower():find('survive', 1, true) then
                        in_survive = true
                    end
                end
                if #objectives == 0 then all_done = false end
                return {
                    name              = name,
                    objectives        = objectives,
                    all_complete      = all_done,
                    in_survive_phase  = in_survive,
                    needs_npc         = event_needs_npc(name),
                }
            end
        end
    end
    return nil
end

-- Backward-compat alias.  Prefer M.read_event in new code.
M.read_ambush = M.read_event

M.read_cursed_shrine = function ()
    if not get_quests then return nil end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return nil end
    for _, q in pairs(quests) do
        if q and q.get_name then
            local nok, name = pcall(function () return q:get_name() end)
            if nok and match_cursed(name) then
                local objs = nil
                if q.get_objectives then
                    local ook, list = pcall(function () return q:get_objectives() end)
                    if ook then objs = list end
                end
                local objectives, all_done = {}, true
                for _, o in ipairs(objs or {}) do
                    objectives[#objectives + 1] = { text = o.text, state = o.state }
                    if o.state ~= STATE_COMPLETE then all_done = false end
                end
                if #objectives == 0 then all_done = false end
                return {
                    name         = name,
                    objectives   = objectives,
                    all_complete = all_done,
                }
            end
        end
    end
    return nil
end

M.read_active = function ()
    if not get_quests then return nil end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return nil end

    -- Collect all NMD-pattern matches, then pick the highest-priority one.
    -- pairs() iteration order is undefined in Lua so we can't rely on the
    -- first match being the "right" quest -- e.g. DOV_Nightmare_* (the
    -- season overlay) and DPO_<zone> (the actual dungeon progress quest)
    -- both match, but DPO is the one whose objectives mean "run done."
    --
    -- Filter out matches with zero objectives.  DOV_Nightmare_RareMaterial
    -- and similar season-scaffolding quests sit in the log forever with
    -- empty objectives -- if we treated them as "the active NMD quest"
    -- we'd:
    --   * latch tracker.nmd_quest_seen = true on next-run entry BEFORE
    --     the real DPO quest spawns, and
    --   * never observe completion (DOV never disappears, all_complete
    --     can't be true with 0 objectives).
    -- Quests with no objectives can't tell us run-progress, so they're
    -- effectively no-matches for our purposes.
    local best, best_prio = nil, math.huge
    for _, q in pairs(quests) do
        if q and q.get_name then
            local nok, name = pcall(function () return q:get_name() end)
            if nok then
                local hit, prio = match_priority(name)
                if hit and prio < best_prio then
                    local id = nil
                    if q.get_id then
                        local iok, qid = pcall(function () return q:get_id() end)
                        if iok then id = qid end
                    end
                    local objs = nil
                    if q.get_objectives then
                        local ook, list = pcall(function () return q:get_objectives() end)
                        if ook then objs = list end
                    end
                    local objectives, all_done, any_done = {}, true, false
                    for _, o in ipairs(objs or {}) do
                        objectives[#objectives + 1] = { text = o.text, state = o.state }
                        if o.state == STATE_COMPLETE then
                            any_done = true
                        else
                            all_done = false
                        end
                    end
                    -- Skip empty-objectives matches (see comment above).
                    if #objectives > 0 then
                        best = {
                            name         = name,
                            id           = id,
                            objectives   = objectives,
                            all_complete = all_done,
                            any_complete = any_done,
                        }
                        best_prio = prio
                    end
                end
            end
        end
    end
    return best
end

return M
