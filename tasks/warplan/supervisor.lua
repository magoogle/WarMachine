-- ---------------------------------------------------------------------------
-- tasks/warplan/supervisor.lua
--
-- In-zone supervisor for War Plan mode (Phase 5 v0.1).
-- Dispatches to per-activity logic based on the active war plan.
--
-- Fires when:
--   • mode == War Plan
--   • An activity-type WarPlans_QST_* is active (not turnin)
--   • Player is FULLY in the right zone for that activity
--
-- Per-activity behavior:
--   nightmare  → Batmobile auto-explore
--   undercity  → Batmobile auto-explore
--   helltide   → seek nearest Helltide_RewardChest_* if cinders >= 75,
--                otherwise auto-explore
--
-- Combat is handled by the user's rotation plugin in parallel.
-- ---------------------------------------------------------------------------

local settings         = require 'core.settings'
local tracker          = require 'core.tracker'
local mode             = require 'core.mode'
local objective_actors = require 'data.objective_actors'

local plugin_label = 'warmachine'

local task = { name = 'warplan_supervisor', status = nil }

-- ---------------------------------------------------------------------------
-- Zone classifier
-- ---------------------------------------------------------------------------

local function classify_zone(zone)
    if not zone then return 'unknown' end
    if zone == 'Skov_Temis' then return 'temis' end
    if zone:match('^DGN_') then return 'dungeon' end
    if zone:match('^X1_Undercity_') then return 'undercity' end
    return 'overworld'
end

local function strict_zone_match(zone, activity)
    local zc = classify_zone(zone)
    if activity == 'nightmare' then return zc == 'dungeon'   end
    if activity == 'undercity' then return zc == 'undercity' end
    if activity == 'helltide'  then return zc == 'overworld' end
    return false
end

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

local INTERACT_RANGE       = 6.0     -- close enough that interact_object opens
local OBJECTIVE_SEARCH_RANGE = 200.0 -- actor stream radius

local function distance_xy(a, b)
    if not a or not b then return math.huge end
    local dx = a:x() - b:x()
    local dy = a:y() - b:y()
    return math.sqrt(dx*dx + dy*dy)
end

-- Find the closest interactable actor whose skin name matches any of the
-- given Lua patterns. Returns (actor, distance) or nil.
local function find_closest_interactable(player_pos, patterns)
    if not actors_manager or not player_pos then return nil end
    local list = actors_manager:get_all_actors()
    local best, best_dist
    for _, a in pairs(list) do
        if a:is_interactable() then
            local name = a:get_skin_name()
            local matched = false
            for _, pat in ipairs(patterns) do
                if name:find(pat) then matched = true; break end
            end
            if matched then
                local ap = a:get_position()
                if ap then
                    local d = distance_xy(player_pos, ap)
                    if d <= OBJECTIVE_SEARCH_RANGE and (not best_dist or d < best_dist) then
                        best, best_dist = a, d
                    end
                end
            end
        end
    end
    return best, best_dist
end

-- Walk to or interact with `target` actor. Returns the same status strings
-- the helltide/undercity/nightmare steps emit so they can format their own
-- task.status line.
local function pursue(target, dist)
    if dist <= INTERACT_RANGE then
        BatmobilePlugin.clear_target(plugin_label)
        interact_object(target)
        return 'interact'
    else
        BatmobilePlugin.pause(plugin_label)
        BatmobilePlugin.update(plugin_label)
        BatmobilePlugin.set_target(plugin_label, target)
        BatmobilePlugin.move(plugin_label)
        return 'walk'
    end
end

local function autoexplore_step()
    BatmobilePlugin.resume(plugin_label)
    BatmobilePlugin.update(plugin_label)
    BatmobilePlugin.move(plugin_label)
end

-- ---------------------------------------------------------------------------
-- Helltide navigation
-- ---------------------------------------------------------------------------

local TORTURED_GIFT_MIN_CINDERS = 75    -- enough to open a tier-1 chest

-- Find closest interactable Helltide chest. Returns (actor, distance).
local function find_closest_helltide_chest(player_pos)
    return find_closest_interactable(player_pos, { 'Helltide_RewardChest' })
end

local function helltide_step(now)
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()

    local cinders = 0
    if get_helltide_coin_cinders then
        local ok, c = pcall(get_helltide_coin_cinders)
        if ok then cinders = c or 0 end
    end

    -- Seek a chest only when we have enough cinders to open one
    if cinders >= TORTURED_GIFT_MIN_CINDERS then
        local chest, dist = find_closest_helltide_chest(pp)
        if chest and dist then
            local r = pursue(chest, dist)
            task.status = string.format('%s helltide chest (%.0fy, cinders %d)',
                r == 'interact' and 'open' or 'walk to', dist, cinders)
            return
        end
    end

    -- No chest target — collect more cinders via auto-explore + rotation
    autoexplore_step()
    task.status = string.format('explore for cinders (%d/%d)',
        cinders, TORTURED_GIFT_MIN_CINDERS)
end

-- ---------------------------------------------------------------------------
-- Undercity navigation
-- ---------------------------------------------------------------------------

-- Priority list lifted from data/objective_actors.lua (undercity).
-- Order: chest > spirit beacons > hearth switches > portal.
local UNDERCITY_OBJECTIVES = objective_actors.undercity

local function undercity_step(now)
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()

    local target, dist = find_closest_interactable(pp, UNDERCITY_OBJECTIVES)
    if target and dist then
        local r = pursue(target, dist)
        task.status = string.format('%s %s (%.0fy)',
            r == 'interact' and 'open' or 'walk to', target:get_skin_name(), dist)
        return
    end

    autoexplore_step()
    task.status = 'auto-explore (undercity)'
end

-- ---------------------------------------------------------------------------
-- Nightmare navigation
-- ---------------------------------------------------------------------------

-- Priority list lifted from data/objective_actors.lua (general priority).
-- Includes war plan reward chests, observed objective patterns
-- (Cultist_SacrificePillar, DRLG_Structure_Spider_Cocoon), DGNAFX, doors,
-- chests, activate/cleanse/carry/seal patterns, animus, destroy targets.
local NIGHTMARE_OBJECTIVES = objective_actors.priority

local function nightmare_step(now)
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()

    local target, dist = find_closest_interactable(pp, NIGHTMARE_OBJECTIVES)
    if target and dist then
        local r = pursue(target, dist)
        task.status = string.format('%s %s (%.0fy)',
            r == 'interact' and 'open' or 'walk to', target:get_skin_name(), dist)
        return
    end

    autoexplore_step()
    task.status = 'auto-explore (nightmare)'
end

-- ---------------------------------------------------------------------------
-- Task contract
-- ---------------------------------------------------------------------------

-- Map (mode, zone) → which step to run.
-- Returns the activity tag the per-zone step expects, or nil if no match.
local function activity_for_state()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil

    if settings.mode == mode.WARPLAN then
        local wp = tracker.warplan.snapshot
        if not (wp and wp.active and wp.quest) then return nil end
        if wp.activity == 'turnin' or wp.activity == 'unknown' then return nil end
        if not strict_zone_match(zone, wp.activity) then return nil end
        return wp.activity
    end

    -- Standalone modes: trigger only when in the matching zone class
    if settings.mode == mode.NIGHTMARE and strict_zone_match(zone, 'nightmare') then
        return 'nightmare'
    end
    if settings.mode == mode.UNDERCITY and strict_zone_match(zone, 'undercity') then
        return 'undercity'
    end
    if settings.mode == mode.HELLTIDE and strict_zone_match(zone, 'helltide') then
        return 'helltide'
    end
    return nil
end

task.shouldExecute = function ()
    -- Yield to any in-flight click/walk task
    if tracker.warplan.test.pending        then return false end
    if tracker.warplan.next_obj.pending    then return false end
    if tracker.warplan.turn_in.pending     then return false end
    if tracker.warplan.start_cycle.pending then return false end
    if tracker.undercity.enter.pending     then return false end
    if tracker.nmd.use_sigil.pending       then return false end

    return activity_for_state() ~= nil
end

task.Execute = function ()
    local now = get_time_since_inject()
    local activity = activity_for_state()

    if activity == 'helltide' then
        helltide_step(now)
    elseif activity == 'undercity' then
        undercity_step(now)
    elseif activity == 'nightmare' then
        nightmare_step(now)
    else
        autoexplore_step()
        task.status = 'auto-explore (' .. tostring(activity) .. ')'
    end
end

return task
