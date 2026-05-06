-- ---------------------------------------------------------------------------
-- activities/pit/tasks/upgrade_glyph.lua
--
-- Final-floor post-boss flow: walk to the Gizmo_Paragon_Glyph_Upgrade,
-- click it, iterate get_glyphs() and call upgrade_glyph(g) for each
-- upgradable glyph until none remain (tracker.glyph_done = true).
--
-- Ported from ArkhamAsylum/tasks/upgrade_glyph.lua.  Differences:
--   * Uses move.to_actor (D4 click-walk) for movement
--   * Per-glyph blacklist + failed-count logic preserved verbatim --
--     can_upgrade() is bugged for level-45 glyphs; the original retry
--     handling avoids spinning forever.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local find     = require 'core.find'
local tracker  = require 'activities.pit.tracker'
local settings = require 'activities.pit.settings'

-- The glyph-upgrade gizmo ships under several different skin names
-- depending on which pit-floor / season / ProtoDun variant the player is
-- on.  WarMapRecorder/core/actor_capture.lua already catalogues all three;
-- mirror its pattern list here.  Substring match -- season-prefixed
-- variants like `S09_Pit_Glyph_Foo` should still hit `Pit_Glyph`.
local GLYPH_GIZMO_PATTERNS = {
    'Gizmo_Paragon_Glyph_Upgrade',
    'EGD_MSWK_GlyphUpgrade',
    'Pit_Glyph',
}

local task = {
    name                  = 'upgrade_glyph',
    status                = 'idle',
    last_interact_t       = -math.huge,
    blacklist             = {},
    last_attempted_glyph  = nil,
    -- Per-glyph fail counts (keyed by glyph_name_hash) -- the original
    -- single shared `failed_count` reset to 0 every time the iterator
    -- looked at a different glyph, so a stuck glyph never accumulated
    -- 5 failures and the loop never advanced to set glyph_done.
    failed_counts         = {},
    glyph_trigger_t       = nil,
}

-- Non-user-facing tunables.  The user-facing knobs live in
-- activities/pit/settings.lua (glyph_upgrade*, glyph_min/max_level)
-- and get read inline below so the user can adjust mid-run.
local INTERACT_COOLDOWN     = 2.0
local MAX_FAILED_BEFORE_BL  = 5
-- Glyph gizmos appear in get_all_actors, not get_ally_actors.
-- Cap the search range so the scan doesn't drag on a crowded floor.
local GIZMO_SEARCH_RANGE_SQ = 50 * 50
-- "At gizmo" threshold; nav pauses once player is within this radius.
local GIZMO_INTERACT_R      = 2.0
-- "In danger" radius for combat preemption while the glyph UI is up.
-- Tuned for melee + close-ranged threats; wider radii would let elites
-- waiting at edge of screen interrupt the upgrade unnecessarily.
local DANGER_RADIUS         = 6.0

-- Latch: nav paused while the bot is engaged with the glyph gizmo.
-- Without this the bot drifts past the gizmo (engine click-walk
-- overshoots / explorer picks an exploration target the moment d
-- crosses GIZMO_INTERACT_R), the d > 2 branch re-fires move.to_actor,
-- which re-toggles interact_object on the gizmo -- visible to the
-- user as the glyph menu opening/closing/opening on a loop.  The
-- latch must be released whenever shouldExecute returns false (task
-- is done / disabled) so the runner's next task can drive nav.
local _nav_paused = false

local function release_nav()
    if _nav_paused then
        move.resume()
        _nav_paused = false
    end
end

-- Is an enemy in melee/close-range threat right now?  Used to gate
-- orbwalker auto-attacks during the glyph UI: keep it silent by
-- default so the menu doesn't get interrupted, but allow defensive
-- counter-attacks when something gets right on top of the player.
local function in_danger()
    return find and find.any_enemy_in_range and find.any_enemy_in_range(DANGER_RADIUS) or false
end

local function find_gizmo()
    if not actors_manager then return nil end
    local lp = get_local_player()
    local pp = lp and lp:get_position()
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn then
            for _, pat in ipairs(GLYPH_GIZMO_PATTERNS) do
                if sn:find(pat, 1, true) then
                    if not pp then return a end
                    local ap = a:get_position()
                    if ap then
                        local dx = ap:x() - pp:x()
                        local dy = ap:y() - pp:y()
                        if dx*dx + dy*dy <= GIZMO_SEARCH_RANGE_SQ then
                            return a
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function should_upgrade(g, last)
    -- Replay last-attempt state -- if same glyph + same level, count
    -- as a failure for THIS glyph (per-hash so iterating across
    -- multiple glyphs doesn't reset the count).
    local hash = g.glyph_name_hash
    if last
       and last.glyph_name_hash == hash
       and last:get_level() == g:get_level()
    then
        local n = (task.failed_counts[hash] or 0) + 1
        if g:get_level() == 45 or n >= MAX_FAILED_BEFORE_BL then
            task.blacklist[hash]      = true
            task.failed_counts[hash]  = nil
        else
            task.failed_counts[hash] = n
        end
    elseif last and last.glyph_name_hash == hash then
        -- Same glyph but level changed -> upgrade succeeded; clear count.
        task.failed_counts[hash] = nil
    end
    if task.blacklist[hash] then return false end
    local lvl = g:get_level()
    -- User-facing min/max level filter (Arkham parity)
    if lvl < (settings.glyph_min_level or 1)   then return false end
    if lvl > (settings.glyph_max_level or 100) then return false end
    -- User-facing chance threshold
    local chance_pct = math.floor((g:get_upgrade_chance() + 0.005) * 100)
    if chance_pct < (settings.glyph_upgrade_threshold or 1) then return false end
    -- Level-45 = legendary path; can_upgrade() is bugged at 45
    if lvl == 45 then return settings.glyph_upgrade_legendary == true end
    return g:can_upgrade()
end

local function attempt_upgrade()
    local glyphs = get_glyphs and get_glyphs() or nil
    if not glyphs or glyphs:size() == 0 then
        tracker.glyph_done = true
    tracker.glyph_done_t = tracker.glyph_done_t or (get_time_since_inject() or 0)
        task.status = 'no glyphs to upgrade'
        return
    end
    if task.last_interact_t + INTERACT_COOLDOWN > get_time_since_inject() then
        return
    end
    -- Iteration order honors user's upgrade_mode setting:
    --   1 = highest-to-lowest level (default; matches Arkham)
    --   2 = lowest-to-highest level
    -- We resolve the order once per call by sorting indices.
    local order = {}
    for i = 1, glyphs:size() do order[#order + 1] = i end
    if settings.glyph_upgrade_mode == 2 then
        table.sort(order, function (a, b)
            return glyphs:get(a):get_level() < glyphs:get(b):get_level()
        end)
    else
        table.sort(order, function (a, b)
            return glyphs:get(a):get_level() > glyphs:get(b):get_level()
        end)
    end
    for _, i in ipairs(order) do
        local g = glyphs:get(i)
        if should_upgrade(g, task.last_attempted_glyph) then
            task.last_attempted_glyph = g
            upgrade_glyph(g)
            task.last_interact_t = get_time_since_inject()
            task.status = 'upgrading glyph ' .. tostring(g.glyph_name_hash)
            return
        end
    end
    -- Nothing upgradable left
    tracker.glyph_done = true
    tracker.glyph_done_t = tracker.glyph_done_t or (get_time_since_inject() or 0)
    task.status = 'idle'
end

task.shouldExecute = function ()
    if not settings.interact_glyph then release_nav(); return false end
    if tracker.glyph_done           then release_nav(); return false end
    if find_gizmo() == nil          then release_nav(); return false end
    return true
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local gizmo = find_gizmo()
    if not gizmo then task.status = 'no gizmo'; return end

    local pp = lp:get_position()
    local gp = gizmo:get_position()
    local dx = gp:x() - pp:x()
    local dy = gp:y() - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    -- Walking phase: nav drives the player toward the gizmo.  Make sure
    -- we're not still holding the at-gizmo nav pause from a previous
    -- engagement (e.g. the bot was knocked back past the threshold).
    if d > GIZMO_INTERACT_R then
        release_nav()
        move.to_actor(gizmo)
        task.status = string.format('walking to glyph gizmo (%.0fm)', d)
        return
    end

    -- At gizmo.  Pause nav so the bot stays put through the upgrade
    -- sequence -- without this the explorer or click-walk overshoot
    -- pulls the player past the gizmo, the menu auto-closes, the d>2
    -- branch re-clicks (re-opens the menu), and we end up in the
    -- open/close rubber-band the user reported.
    if not _nav_paused then
        move.clear()
        move.pause()
        _nav_paused = true
    end

    -- Default: keep orbwalker silent so basic-attack auto-fire doesn't
    -- close the glyph UI mid-upgrade.  Override only when an enemy is
    -- in melee/close-range threat -- defensive counter-attacks are
    -- worth interrupting the upgrade for.
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(in_danger())
    end

    -- First arrival: stamp engagement + open the UI.
    if not task.glyph_trigger_t then
        task.glyph_trigger_t       = get_time_since_inject()
        task.last_interact_t       = -math.huge
        task.blacklist             = {}
        task.last_attempted_glyph  = nil
        task.failed_counts         = {}
        interact_object(gizmo)
        task.status = 'opening glyph UI'
        return
    end

    -- ~1s after first interact, the UI is open and get_glyphs() returns
    -- the live list.  Iterate upgrades.
    if task.glyph_trigger_t + 1 < get_time_since_inject() then
        attempt_upgrade()
    else
        task.status = 'waiting for glyph UI'
    end
end

return task
