-- ---------------------------------------------------------------------------
-- core/whispers.lua
--
-- Tree of Whispers turn-in piggyback.
--
-- When the bot is idle in any town with whisper bounties ready, walk to
-- the Tree of Whispers NPC, interact, and accept the first reward.  This
-- lets the user collect Grim Favor caches without a dedicated trip --
-- the bot does it whenever it's in town for some other reason.
--
-- Design notes:
--   * Patterns below (Tree NPC skin, bounty quest names, reward-key
--     binding) are best-effort defaults.  The first time we have a real
--     whisper turn-in available, snapshot the live actor stream + quest
--     log via QQT and update the constants if anything's off.
--   * Default-disabled.  User must flip the GUI toggle to opt in --
--     keeps the feature dormant while we validate.
--   * Strictly piggyback: we DO NOT teleport to the Tree from elsewhere.
--     Only fires when the Tree NPC is already in the live actor stream.
-- ---------------------------------------------------------------------------

local find = require 'core.find'
local zone = require 'core.zone'

local M = {}

-- Town zones that actually host the bounty NPC.  Used by dispatch's
-- whispers_pending yield -- we don't want to keep the bot waiting in
-- Cerrigar forever just because whispers are ready; only yield in
-- towns where the Raven/Tree/Crow is known to spawn.
--
-- Live-validated: Skov_Temis hosts Temis_Bounty_Meta_Raven_NPC.
-- Defensive: Hawe_TreeOfWhispers is the legacy Tree-of-Whispers zone.
-- Other major towns (Cerrigar, Kyovashad, etc.) DO ship Crow NPCs in
-- some seasons -- if a future capture confirms the Crow is reliably
-- there, add the zone here.
local WHISPER_NPC_TOWN_ZONES = {
    ['Skov_Temis']          = true,
    ['Hawe_TreeOfWhispers'] = true,
}

-- True when current zone is a town known to host the bounty NPC.
M.in_whisper_town = function ()
    local z = zone.current()
    return z and WHISPER_NPC_TOWN_ZONES[z] == true or false
end

-- Whispers turn-in NPC skin patterns (substring, case-insensitive).
-- Live-validated S09 -- the user pinged me from `Skov_Temis` standing
-- next to a Raven and the actual interactable skin was:
--
--   Temis_Bounty_Meta_Raven_NPC     (Skov_Temis raven; primary)
--
-- Older content puts the actual Tree of Whispers in `Hawe_TreeOfWhispers`
-- (Hawezar) -- I haven't captured that skin live yet but it's almost
-- certainly a `TreeOfWhispers_*` variant.  Quest objective text from the
-- live capture: "Return to the Tree of Whispers or find a Crow of the
-- Tree in town" -- so D4 ships this as a tri-skin: Tree (Hawezar) +
-- Raven (Skov_Temis) + Crow (other major towns).
--
-- Patterns ordered most-specific first so even if a future season ships
-- additional variants, the bounty-meta substring catches them generically.
local TREE_NPC_PATTERNS = {
    'temis_bounty_meta_raven_npc',  -- Skov_Temis (S07+ home town); validated
    'bounty_meta_raven',            -- defensive: future towns, raven naming
    'bounty_meta_crow',             -- defensive: 'Crow of the Tree' variant
    'bounty_meta',                  -- catch-all: any future Bounty_Meta_* NPC
    'treeofwhispers',               -- actual Tree NPC in Hawezar (unverified)
    'tree_of_whispers',
    'crow_of_the_tree',
}

-- Whispers turn-in quest detection (live-validated S09).
--
-- D4 ships a single overarching quest `Bounty_Meta_Quest` (id 597351
-- observed) that drives the whispers loop.  When 10 Grim Favor are
-- accumulated, the quest objective text becomes:
--
--   "Return to the Tree of Whispers or find a Crow of the Tree in town"
--
-- ...with state = 16777216 (in-progress), not state == 1.  Earlier
-- assumption that "ready" = state==1 was wrong; bounties never tick to
-- state 1 from the player's perspective -- they go from "collect favor"
-- objective text to "return to Tree" objective text, then disappear
-- after turn-in.  We detect ready-state by matching the objective text.
local BOUNTY_QUEST_NAMES = {
    'Bounty_Meta_Quest',         -- S09 single canonical name
    'Bounty_Meta_',              -- defensive: prefix variant
    'Bounty_Tree_',              -- defensive: future-season rename guard
}

-- Substrings (case-insensitive) inside an active objective that mean
-- "turn-in is in progress" -- either we've accumulated 10 favor and
-- the marker is up, OR we've already opened the reward panel and are
-- mid-selection.
--
-- Live-validated objective transitions on Bounty_Meta_Quest:
--   "Collect Grim Favor (N/10)"   <- accumulating; not a turn-in
--   "Return to the Tree of Whispers or find a Crow of the Tree in town"
--                                 <- ready, panel closed
--   "Choose your reward"          <- panel open mid-selection
--   (quest disappears from log)   <- successfully turned in
--
-- We must keep dispatch yielding (and whisper_turnin claiming the
-- pulse) for ALL of the in-progress objective texts -- if we don't
-- match "Choose your reward", the moment the panel opens dispatch
-- thinks whispers are done and fires next_obj, ripping the bot away
-- mid-click-sequence.
local TURN_IN_OBJECTIVE_HINTS = {
    'tree of whispers',
    'crow of the tree',
    'choose your reward',
    'choose a reward',     -- defensive variant
    'select your reward',  -- defensive variant
}

-- Quest name set used by is_bounty_quest_present.  Same list as
-- BOUNTY_QUEST_NAMES below but kept in a separate constant because
-- it'd cause a forward-reference if I tried to inline it.
local BOUNTY_QUEST_NAME_SET = {
    ['Bounty_Meta_Quest'] = true,
}

-- The reward window is mouse-only -- VK_1 / Enter / Space do NOT select
-- a cache (live-validated S09: keypress probe did nothing while the
-- user had the panel open).  Two clicks are required:
--
--   1) Reward card     -- the leftmost of 3 cache cards, lower-middle
--   2) Accept button   -- below the cards, bottom-center
--
-- Both click points are expressed as fractional screen coordinates (0..1)
-- so the same settings work across resolutions.  Defaults are tuned for
-- typical 16:9 layout; user can override via GUI sliders if UI scale
-- shifts the panel.  An overlay (settings.warplan.show_whisper_points)
-- draws crosshairs at the configured spots so the user can dial in
-- without consuming a turn-in.
local DEFAULT_REWARD_CLICK_X_FRAC = 0.40
local DEFAULT_REWARD_CLICK_Y_FRAC = 0.55
local DEFAULT_ACCEPT_CLICK_X_FRAC = 0.50
local DEFAULT_ACCEPT_CLICK_Y_FRAC = 0.85

-- True when current zone is one of the recognized town zones.
-- Delegates to core.zone so the town list lives in one place.
M.is_in_town = zone.in_town

-- Returns the number of whispers turn-ins that are ready RIGHT NOW.
-- Detects via the objective text on the bounty meta-quest: when the
-- player has accumulated 10 Grim Favor, the active objective changes
-- to "Return to the Tree of Whispers or find a Crow of the Tree in
-- town."  Until then it tracks favor accumulation and isn't a turn-in
-- candidate.
--
-- Returns 1 (ready) or 0 (not ready) -- D4 only ever has one whispers
-- turn-in pending at a time.  Stays an integer for symmetry with the
-- task's `count_ready_bounties() > 0` gate.
M.count_ready_bounties = function ()
    if not get_quests then return 0 end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return 0 end

    for _, q in pairs(quests) do
        local n = q.get_name and q:get_name() or ''
        local matches_name = false
        for _, want in ipairs(BOUNTY_QUEST_NAMES) do
            if n:sub(1, #want) == want then matches_name = true; break end
        end
        if matches_name then
            local objs_ok, objs = pcall(function () return q:get_objectives() end)
            if objs_ok and objs then
                for _, o in ipairs(objs) do
                    local text = (o.text or ''):lower()
                    for _, hint in ipairs(TURN_IN_OBJECTIVE_HINTS) do
                        if text:find(hint, 1, true) then return 1 end
                    end
                end
            end
        end
    end
    return 0
end

-- True when the bounty meta-quest is still in the log at all,
-- regardless of objective text.  Used by whisper_turnin's VERIFY step
-- as the canonical "did the turn-in succeed?" signal.  Old VERIFY
-- check used count_ready_bounties == 0 which gave false positives
-- the moment the panel opened (objective text changed) -- the bot
-- declared success before the reward was actually claimed and latched
-- the zone, never retrying.
M.is_bounty_quest_present = function ()
    if not get_quests then return false end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return false end
    for _, q in pairs(quests) do
        local n = q.get_name and q:get_name() or ''
        if BOUNTY_QUEST_NAME_SET[n] then return true end
        for _, want in ipairs(BOUNTY_QUEST_NAMES) do
            if n:sub(1, #want) == want then return true end
        end
    end
    return false
end

-- Returns the Tree-of-Whispers NPC actor in the live stream, or nil.
M.find_tree_npc = function ()
    local actor = find.closest({
        patterns = TREE_NPC_PATTERNS,
        require_interactable = true,
        source = 'ally',
    })
    return actor
end

-- Returns the catalogued NPC position from WarPath / StaticPather, or
-- nil.  The recorder classifies the bounty NPC as kind='bounty_npc'
-- (see WarMapRecorder/core/actor_capture.lua) so we just scan the
-- catalog for the first bounty_npc entry in the current zone.
--
-- Used by whisper_turnin to walk the bot toward the NPC's known spot
-- BEFORE the live actor stream populates -- the actor takes a few
-- frames to enter stream after a zone change, and dispatch can fire
-- next_obj in that window if we don't have a position to walk toward.
M.find_tree_position = function ()
    if not StaticPatherPlugin or not StaticPatherPlugin.get_actors then
        return nil
    end
    local ok, actors = pcall(StaticPatherPlugin.get_actors)
    if not ok or not actors then return nil end

    -- Prefer matches that share BOTH our skin patterns AND the
    -- 'bounty_npc' kind tag; fall back to skin-pattern only if the
    -- recorder didn't classify the entry yet.
    local fallback = nil
    for _, a in ipairs(actors) do
        local skin = (a.skin or ''):lower()
        local matches = false
        for _, pat in ipairs(TREE_NPC_PATTERNS) do
            if skin:find(pat, 1, true) then matches = true; break end
        end
        if matches then
            if a.kind == 'bounty_npc' then
                return { x = a.x, y = a.y, z = a.z, skin = a.skin }
            end
            fallback = fallback or { x = a.x, y = a.y, z = a.z, skin = a.skin }
        elseif a.kind == 'bounty_npc' and not fallback then
            -- Catalogued bounty NPC even if its skin doesn't match our
            -- pattern list -- defensive against future-season skins.
            fallback = { x = a.x, y = a.y, z = a.z, skin = a.skin }
        end
    end
    return fallback
end

M.DEFAULT_REWARD_CLICK_X_FRAC = DEFAULT_REWARD_CLICK_X_FRAC
M.DEFAULT_REWARD_CLICK_Y_FRAC = DEFAULT_REWARD_CLICK_Y_FRAC
M.DEFAULT_ACCEPT_CLICK_X_FRAC = DEFAULT_ACCEPT_CLICK_X_FRAC
M.DEFAULT_ACCEPT_CLICK_Y_FRAC = DEFAULT_ACCEPT_CLICK_Y_FRAC

-- Resolve fractional screen coords to pixel coords using the live
-- screen size.  Returns nil when the host doesn't expose screen-size
-- helpers (defensive; should always be present on D4 hosts).
M.frac_to_pixels = function (x_frac, y_frac)
    if not get_screen_width or not get_screen_height then return nil, nil end
    local sw, sh = get_screen_width(), get_screen_height()
    return math.floor(sw * x_frac), math.floor(sh * y_frac)
end

-- Click at fractional screen coordinates.  Wraps utility.send_mouse_click
-- with a frac->pixel conversion.  Returns true if the click fired.
M.click_at_frac = function (x_frac, y_frac)
    if not utility or not utility.send_mouse_click then return false end
    local x, y = M.frac_to_pixels(x_frac, y_frac)
    if not x then return false end
    utility.send_mouse_click(x, y)
    return true
end

return M
