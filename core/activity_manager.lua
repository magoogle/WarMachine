-- ---------------------------------------------------------------------------
-- core/activity_manager.lua
--
-- Replaces the cross-plugin handoff that used to live in tasks/warplan/
-- supervisor.lua (which toggled ArkhamAsylumPlugin / WonderCityPlugin /
-- HelltideRevampedPlugin / SigilRunnerPlugin / InfernalHordesPlugin).
-- Now everything is in-process inside WarMachine: each `activities/<name>/`
-- folder exports an api.lua with a uniform contract, and this module picks
-- which one runs each pulse based on settings.mode + the current zone +
-- (for warplan) the live WarPlans_QST_* quest.
--
-- Activity module contract (every activities/<name>/api.lua exports):
--
--   M.tag             string      -- 'pit' | 'undercity' | 'helltide' | 'nmd' | 'hordes'
--   M.label           string      -- 'Pit', 'Undercity', etc.
--   M.is_loaded()     bool        -- module is wired up + has its tasks ready
--   M.shouldExecute() bool        -- should we run this activity right now?
--                                    (e.g. player is in the right zone, has
--                                    sigils for nmd, helltide is active, etc.)
--   M.pulse()         nil         -- one tick of the activity's task list
--   M.get_status()    { task, status, ... }  -- for the on-screen overlay +
--                                              cross-plugin status reads
--   M.activate()      nil         -- called when this activity becomes the
--                                    chosen one (state transitions, fresh
--                                    tracker reset, etc.)
--   M.deactivate()    nil         -- called when we transition away from
--                                    this activity (cleanup, stop walking,
--                                    drop state)
--
-- Until each activity is actually ported (one per round), the registry
-- holds nil placeholders and activity_manager just no-ops.
-- ---------------------------------------------------------------------------

local mode    = require 'core.mode'
local tracker = require 'core.tracker'

local M = {}

-- ---------------------------------------------------------------------------
-- Registry.  Each activity module registers itself via load_activity()
-- below; missing modules get silently skipped (so the user can drop a
-- module into activities/ and it lights up automatically).
-- ---------------------------------------------------------------------------
local registry = {}    -- tag -> activity table

local function try_require(path)
    local ok, m = pcall(require, path)
    if ok then return m end
    return nil
end

-- ---------------------------------------------------------------------------
-- Load all known activity modules at WarMachine startup.  Each module that
-- isn't yet ported gracefully reports `is_loaded() = false` so the GUI can
-- grey out its mode in the dropdown.
-- ---------------------------------------------------------------------------
local KNOWN_ACTIVITIES = { 'pit', 'undercity', 'helltide', 'nmd', 'hordes', 'boss' }

local function load_all()
    for _, tag in ipairs(KNOWN_ACTIVITIES) do
        local mod = try_require('activities.' .. tag .. '.api')
        if mod then
            mod.tag = mod.tag or tag
            registry[tag] = mod
        end
    end
end
load_all()

M.is_activity_loaded = function (tag)
    local m = registry[tag]
    if not m then return false end
    if m.is_loaded then return m.is_loaded() and true or false end
    return true
end

M.get_activity = function (tag)
    return registry[tag]
end

M.list_activities = function ()
    return KNOWN_ACTIVITIES
end

-- ---------------------------------------------------------------------------
-- Pick the activity that should run THIS pulse based on:
--   * settings.mode (Idle / WarPlan / Nightmare / Undercity / Pit / Hordes / Helltide)
--   * for WarPlan: the live WarPlans_QST_* quest's activity tag
--
-- Returns the activity tag string, or nil if none should run (Idle, no
-- warplan in WarPlan mode, etc.).
-- ---------------------------------------------------------------------------
M.pick_activity = function (settings_mode)
    if settings_mode == mode.IDLE then return nil end

    -- Standalone modes: trivially mapped.
    local direct = mode.activity_for(settings_mode)
    if direct then return direct end

    -- WarPlan: read the live quest snapshot and use whatever activity it dictates.
    if settings_mode == mode.WARPLAN then
        local wp = tracker.warplan and tracker.warplan.snapshot
        if not (wp and wp.active and wp.activity) then return nil end
        if wp.activity == 'turnin' then return nil end
        -- Translate WarPlan's quest-classification strings to the
        -- activity module's tag.  WarPlan uses 'nightmare' (matching
        -- the WarPlans_QST_NightmareDungeon quest name); the
        -- activities/nmd/ module is registered under tag 'nmd'.
        -- All other activity strings already match their module tag.
        if wp.activity == 'nightmare' then return 'nmd' end
        return wp.activity
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Pulse: dispatch to the picked activity.
--
-- Handles activate/deactivate transitions automatically -- if the picked
-- activity changed since last pulse, we deactivate the old one and
-- activate the new one before pulsing.  Cheap when nothing changes
-- (registry lookup + table compare + one shouldExecute call).
-- ---------------------------------------------------------------------------
local current_active_tag = nil

local function set_active(tag)
    if current_active_tag == tag then return end
    if current_active_tag then
        local prev = registry[current_active_tag]
        if prev and prev.deactivate then pcall(prev.deactivate) end
    end
    current_active_tag = tag
    if tag then
        local cur = registry[tag]
        if cur and cur.activate then pcall(cur.activate) end
    end
end

M.pulse = function (settings_mode)
    local tag = M.pick_activity(settings_mode)
    set_active(tag)
    if not tag then return end
    local act = registry[tag]
    if not act then return end
    if act.shouldExecute and not act.shouldExecute() then return end
    if act.pulse then pcall(act.pulse) end
end

-- ---------------------------------------------------------------------------
-- Read the current active activity's status (for overlay rendering and
-- cross-plugin status reads via WarMachinePlugin.get_status()).
-- ---------------------------------------------------------------------------
M.get_active_tag = function () return current_active_tag end

M.get_status = function ()
    if not current_active_tag then return { tag = nil } end
    local act = registry[current_active_tag]
    if not act then return { tag = current_active_tag } end
    local out = { tag = current_active_tag, label = act.label }
    if act.get_status then
        local ok, s = pcall(act.get_status)
        if ok and type(s) == 'table' then
            out.task   = s.task
            out.status = s.status
            for k, v in pairs(s) do
                if out[k] == nil then out[k] = v end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Force a deactivate of the current activity.  Used when WarMachine itself
-- gets disabled (main_toggle off) or when the user changes mode.
--
-- Force a clean stop of all navigation when WarMachine shuts down.
-- ---------------------------------------------------------------------------
M.shutdown = function ()
    set_active(nil)
    -- Hard-stop the internal walker so any in-flight path doesn't keep
    -- driving the player after WarMachine flips off.  walker.stop also
    -- clears the host pathfinder's stored path so the player goes idle
    -- on the next pulse.
    local wok, walker = pcall(require, 'core.walker')
    if wok and walker and walker.stop then walker.stop() end
    -- Clear cross-plugin signals so a stale travel flag doesn't outlive
    -- WarMachine.  Cheap; safe to call when the bridge isn't loaded.
    local rok, rb = pcall(require, 'core.rotation_bridge')
    if rok and rb and rb.clear then rb.clear() end
end

return M
