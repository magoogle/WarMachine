-- ---------------------------------------------------------------------------
-- tasks/pit/post_boss.lua
--
-- Pit-clear post-boss handler for WarPlan mode.
--
-- Walks to the glyph upgrade gizmo, runs the upgrade sequence directly
-- (no ArkhamAsylum delegation), then fires Next-Obj to advance the WarPlan.
--
-- State machine:
--   1. Gizmo in stream → walk to it
--   2. Within interact range → interact to open the upgrade UI
--   3. ~1s later → call upgrade_glyph() for each eligible glyph
--   4. No eligible glyphs remain → fire Next-Obj exit
--
-- Reset: tracker.pit.glyph_gizmo_seen is cleared by enter.lua on each new
-- run entry, which causes this task to re-arm for the next pit.
-- ---------------------------------------------------------------------------

local settings     = require 'core.settings'
local tracker      = require 'core.tracker'
local mode         = require 'core.mode'
local pit_settings = require 'activities.pit.settings'
local move         = require 'core.move'
local find         = require 'core.find'

-- Skins for the glyph upgrade pedestal across seasons/variants.
local GLYPH_GIZMO_PATTERNS = {
    'Gizmo_Paragon_Glyph_Upgrade',
    'EGD_MSWK_GlyphUpgrade',
    'Pit_Glyph',
}

local GIZMO_SEARCH_RANGE_SQ = 50 * 50   -- only scan within 50m
local INTERACT_RANGE        = 2.0
local INTERACT_COOLDOWN     = 2.0
local MAX_FAILED_BEFORE_BL  = 5

local task = {
    name                 = 'pit_post_boss',
    status               = nil,
    -- Per-activation state (reset when glyph_gizmo_seen flips false→true)
    glyph_trigger_t      = nil,
    last_interact_t      = -math.huge,
    blacklist            = {},
    last_attempted_glyph = nil,
    -- Per-glyph fail counts (keyed by glyph_name_hash).  See the matching
    -- comment in activities/pit/tasks/upgrade_glyph.lua -- a single
    -- shared failed_count reset to 0 every time the iterator looked at
    -- a different glyph, which is why glyph_done sometimes never flipped.
    failed_counts        = {},
}

-- Module-level done flag.  Reset inside Execute when a new run's gizmo appears.
local _glyph_done = false

-- Latch nav-pause state so we don't keep clicking the gizmo (re-toggling
-- the menu) when the click-walk overshoots and the bot drifts d>2 again.
-- Same pattern + reasoning as activities/pit/tasks/upgrade_glyph.lua.
local _nav_paused = false
local DANGER_RADIUS = 6.0

local function release_nav()
    if _nav_paused then
        move.resume()
        _nav_paused = false
    end
end

local function in_danger()
    return find and find.any_enemy_in_range and find.any_enemy_in_range(DANGER_RADIUS) or false
end

local function in_pit()
    local w = get_current_world()
    if not w then return false end
    local n = w:get_name()
    return n ~= nil and n:match('^PIT_') ~= nil
end

-- Use get_all_actors() -- glyph gizmos are NOT in get_ally_actors() in D4.
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

local function should_upgrade(g)
    local last = task.last_attempted_glyph
    local hash = g.glyph_name_hash
    if last
       and last.glyph_name_hash == hash
       and last:get_level() == g:get_level()
    then
        local n = (task.failed_counts[hash] or 0) + 1
        if g:get_level() == 45 or n >= MAX_FAILED_BEFORE_BL then
            task.blacklist[hash]     = true
            task.failed_counts[hash] = nil
        else
            task.failed_counts[hash] = n
        end
    elseif last and last.glyph_name_hash == hash then
        -- Same glyph, level changed -> upgrade succeeded; clear count.
        task.failed_counts[hash] = nil
    end
    if task.blacklist[hash] then return false end
    local lvl = g:get_level()
    if lvl < (pit_settings.glyph_min_level or 1)   then return false end
    if lvl > (pit_settings.glyph_max_level or 100) then return false end
    local chance_pct = math.floor((g:get_upgrade_chance() + 0.005) * 100)
    if chance_pct < (pit_settings.glyph_upgrade_threshold or 1) then return false end
    if lvl == 45 then return pit_settings.glyph_upgrade_legendary == true end
    return g:can_upgrade()
end

local function set_glyph_done()
    _glyph_done = true
    -- Signal the shared activities pit tracker so dispatch's guard releases.
    local ok, pt = pcall(require, 'activities.pit.tracker')
    if ok and pt then pt.glyph_done = true end
end

local function attempt_upgrade()
    local glyphs = get_glyphs and get_glyphs() or nil
    if not glyphs or glyphs:size() == 0 then
        set_glyph_done()
        task.status = 'no glyphs to upgrade'
        return
    end
    local now = get_time_since_inject() or 0
    if task.last_interact_t + INTERACT_COOLDOWN > now then return end

    local order = {}
    for i = 1, glyphs:size() do order[#order + 1] = i end
    if pit_settings.glyph_upgrade_mode == 2 then
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
        if should_upgrade(g) then
            task.last_attempted_glyph = g
            upgrade_glyph(g)
            task.last_interact_t = now
            task.status = 'upgrading glyph ' .. tostring(g.glyph_name_hash)
            return
        end
    end
    _glyph_done = true
    task.status = 'glyph upgrade complete'
end

local function fire_next_obj_exit(now)
    if tracker.warplan.next_obj.pending then return end
    local s = tracker.warplan.next_obj
    s.pending           = true
    s.step              = 0
    s.timer             = now
    s.verify_started_at = nil
    s.baseline_zone     = get_current_world() and get_current_world():get_current_zone_name() or nil
    s.baseline_pos_x    = nil
    s.baseline_pos_y    = nil
    local lp = get_local_player()
    if lp then
        local p = lp:get_position()
        if p then
            s.baseline_pos_x = p:x()
            s.baseline_pos_y = p:y()
        end
    end
    s.result = nil
    console.print('[WarMachine] pit: glyph upgrade done -- triggering Next-Obj exit')
    task.status = 'exit via Next-Obj'
    tracker.pit.glyph_gizmo_seen = false
    tracker.pit.glyph_interacted_at = nil
end

task.shouldExecute = function ()
    if settings.mode ~= mode.WARPLAN          then release_nav(); return false end
    if not in_pit()                           then release_nav(); return false end
    if tracker.warplan.next_obj.pending       then release_nav(); return false end
    local active = find_gizmo() ~= nil
        or (tracker.pit.glyph_gizmo_seen and not _glyph_done)
    if not active then release_nav() end
    return active
end

task.Execute = function ()
    pit_settings.update()
    local now   = get_time_since_inject() or 0
    local gizmo = find_gizmo()

    -- New run: reset per-activation state when the gizmo first appears.
    if gizmo and not tracker.pit.glyph_gizmo_seen then
        tracker.pit.glyph_gizmo_seen = true
        _glyph_done              = false
        task.glyph_trigger_t     = nil
        task.last_interact_t     = -math.huge
        task.blacklist           = {}
        task.last_attempted_glyph = nil
        task.failed_counts       = {}
        console.print('[WarMachine] pit: glyph gizmo appeared -- upgrading')
    end

    -- Glyph upgrade disabled or already done → advance WarPlan.
    if _glyph_done or not pit_settings.interact_glyph then
        release_nav()
        fire_next_obj_exit(now)
        return
    end

    if not gizmo then
        task.status = 'waiting for glyph gizmo'
        return
    end

    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local gp = gizmo:get_position()
    if not gp then return end

    local dx = gp:x() - pp:x()
    local dy = gp:y() - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    if d > INTERACT_RANGE then
        release_nav()
        move.to_actor(gizmo)
        task.status = string.format('walking to glyph gizmo (%.0fm)', d)
        return
    end

    -- At gizmo: pause nav so the bot stays put through the upgrade
    -- sequence -- without this the click-walk overshoots, the menu
    -- auto-closes, and the d>2 branch re-clicks (re-opens), producing
    -- the open/close rubber-band the user reported.
    if not _nav_paused then
        move.clear()
        move.pause()
        _nav_paused = true
    end

    -- Default silent; allow defensive auto-attack only when an enemy
    -- gets close enough to interrupt the UI anyway.
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(in_danger())
    end

    -- Within range: open UI on first arrival, then drive upgrades.
    if not task.glyph_trigger_t then
        task.glyph_trigger_t = now
        interact_object(gizmo)
        task.status = 'opening glyph UI'
        return
    end

    if task.glyph_trigger_t + 1 < now then
        attempt_upgrade()
    else
        task.status = 'waiting for glyph UI'
    end
end

return task
