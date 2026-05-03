-- ---------------------------------------------------------------------------
-- activities/pit/tasks/upgrade_glyph.lua
--
-- Final-floor post-boss flow: walk to the Gizmo_Paragon_Glyph_Upgrade,
-- click it, iterate get_glyphs() and call upgrade_glyph(g) for each
-- upgradable glyph until none remain (tracker.glyph_done = true).
--
-- Ported from ArkhamAsylum/tasks/upgrade_glyph.lua.  Differences:
--   * BatmobilePlugin movement replaced with move.to_actor (D4 click-walk)
--   * Per-glyph blacklist + failed-count logic preserved verbatim --
--     can_upgrade() is bugged for level-45 glyphs; the original retry
--     handling avoids spinning forever.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
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
    failed_count          = 0,
    glyph_trigger_t       = nil,
}

-- Non-user-facing tunables.  The user-facing knobs live in
-- activities/pit/settings.lua (glyph_upgrade*, glyph_min/max_level)
-- and get read inline below so the user can adjust mid-run.
local INTERACT_COOLDOWN     = 2.0
local MAX_FAILED_BEFORE_BL  = 5

local function find_gizmo()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_ally_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn then
            for _, pat in ipairs(GLYPH_GIZMO_PATTERNS) do
                if sn:find(pat, 1, true) then return a end
            end
        end
    end
    return nil
end

local function should_upgrade(g, last)
    -- Replay last-attempt state -- if same glyph + same level, count as failure
    if last
       and last.glyph_name_hash == g.glyph_name_hash
       and last:get_level() == g:get_level()
    then
        if g:get_level() == 45 or task.failed_count >= MAX_FAILED_BEFORE_BL then
            task.blacklist[g.glyph_name_hash] = true
            task.failed_count = 0
        else
            task.failed_count = task.failed_count + 1
        end
    else
        task.failed_count = 0
    end
    if task.blacklist[g.glyph_name_hash] then return false end
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
    if not settings.interact_glyph then return false end
    if tracker.glyph_done then return false end
    return find_gizmo() ~= nil
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

    if d > 2 then
        move.to_actor(gizmo)
        task.status = string.format('walking to glyph gizmo (%.0fm)', d)
        return
    end

    -- At gizmo.  Open the UI on first arrival, then iterate upgrades.
    if not task.glyph_trigger_t then
        task.glyph_trigger_t       = get_time_since_inject()
        task.last_interact_t       = -math.huge
        task.blacklist             = {}
        task.last_attempted_glyph  = nil
        task.failed_count          = 0
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
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
