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

local GLYPH_GIZMO_SKIN = 'Gizmo_Paragon_Glyph_Upgrade'

local task = {
    name                  = 'upgrade_glyph',
    status                = 'idle',
    last_interact_t       = -math.huge,
    blacklist             = {},
    last_attempted_glyph  = nil,
    failed_count          = 0,
    glyph_trigger_t       = nil,
}

-- Tunables (could be made user-settings later)
local UPGRADE_THRESHOLD     = 5    -- min upgrade chance % to attempt (matches Arkham default)
local UPGRADE_LEGENDARY     = false -- attempt level-45 glyphs (legendary)
local INTERACT_COOLDOWN     = 2.0
local MAX_FAILED_BEFORE_BL  = 5

local function find_gizmo()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_ally_actors()) do
        if a:get_skin_name() == GLYPH_GIZMO_SKIN then return a end
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
    -- can_upgrade() is bugged for level 45; only honor it for non-max
    local lvl = g:get_level()
    local chance_pct = math.floor((g:get_upgrade_chance() + 0.005) * 100)
    if chance_pct < UPGRADE_THRESHOLD then return false end
    if lvl == 45 then return UPGRADE_LEGENDARY end
    return g:can_upgrade()
end

local function attempt_upgrade()
    local glyphs = get_glyphs and get_glyphs() or nil
    if not glyphs or glyphs:size() == 0 then
        tracker.glyph_done = true
        task.status = 'no glyphs to upgrade'
        return
    end
    if task.last_interact_t + INTERACT_COOLDOWN > get_time_since_inject() then
        return
    end
    -- Pick highest-level upgradable glyph
    for i = 1, glyphs:size() do
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
