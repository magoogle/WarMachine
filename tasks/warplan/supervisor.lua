-- ---------------------------------------------------------------------------
-- tasks/warplan/supervisor.lua
--
-- Sub-plugin orchestrator. Replaces the old per-activity supervisor that
-- duplicated logic from SigilRunner / HelltideRevamped / WonderCity /
-- ArkhamAsylum. Now WarMachine simply enables the matching sub-plugin
-- when the player is in the activity zone, and disables it on transition.
--
-- Activity → sub-plugin map:
--   nightmare → SigilRunnerPlugin
--   helltide  → HelltideRevampedPlugin
--   undercity → WonderCityPlugin
--   pit       → ArkhamAsylumPlugin
--
-- Sub-plugins must be installed AND have their own main_toggle ON for
-- this to work. WarMachine's enable() flips their keybind_toggle on/off
-- (their facade does this internally).
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'

local task = { name = 'warplan_supervisor', status = nil }

-- ---------------------------------------------------------------------------
-- Activity → plugin tag → plugin-global lookup
-- ---------------------------------------------------------------------------

local PLUGIN_FOR_ACTIVITY = {
    nightmare = 'sigilrunner',
    helltide  = 'helltide',
    undercity = 'wondercity',
    pit       = 'arkhamasylum',
}

local function get_plugin(tag)
    if tag == 'sigilrunner'  then return SigilRunnerPlugin end
    if tag == 'helltide'     then return HelltideRevampedPlugin end
    if tag == 'wondercity'   then return WonderCityPlugin end
    if tag == 'arkhamasylum' then return ArkhamAsylumPlugin end
    return nil
end

local function classify_zone(zone)
    if not zone then return 'unknown' end
    if zone == 'Skov_Temis' then return 'temis' end
    if zone:match('^DGN_') then return 'dungeon' end
    if zone:match('^X1_Undercity_') then return 'undercity' end
    if zone:match('^PIT_') then return 'pit' end
    return 'overworld'
end

-- True only when player is FULLY inside the activity's runtime zone
-- (not in town / intermediate zones). Sub-plugins are safe to enable here.
local function in_activity_zone(zone, activity)
    local zc = classify_zone(zone)
    if activity == 'nightmare' then return zc == 'dungeon'   end
    if activity == 'undercity' then return zc == 'undercity' end
    if activity == 'helltide'  then return zc == 'overworld' end
    if activity == 'pit'       then return zc == 'pit'       end
    return false
end

-- ---------------------------------------------------------------------------
-- Plugin enable/disable with state tracking. Idempotent — only logs +
-- calls the facade when the active plugin actually changes.
-- ---------------------------------------------------------------------------

local function enable_plugin(tag)
    if tracker.warplan.active_sub_plugin == tag then return end
    -- Disable whatever was running before
    if tracker.warplan.active_sub_plugin then
        local old = get_plugin(tracker.warplan.active_sub_plugin)
        if old and old.disable then
            console.print('[WarMachine] disabling sub-plugin: ' .. tracker.warplan.active_sub_plugin)
            old.disable()
        end
    end
    -- Enable the new one
    if tag then
        local p = get_plugin(tag)
        if p and p.enable then
            console.print('[WarMachine] enabling sub-plugin: ' .. tag)
            p.enable()
        else
            console.print('[WarMachine] sub-plugin not loaded: ' .. tag)
        end
    end
    tracker.warplan.active_sub_plugin = tag
end

-- Public-style helper used by dispatch on warplan complete.
task.disable_all_sub_plugins = function ()
    enable_plugin(nil)
end

-- ---------------------------------------------------------------------------
-- Task contract
-- ---------------------------------------------------------------------------

task.shouldExecute = function ()
    if settings.mode ~= mode.WARPLAN then
        -- If we're not in War Plan mode but a sub-plugin is still on,
        -- disable it. Cleanup.
        if tracker.warplan.active_sub_plugin then
            enable_plugin(nil)
        end
        return false
    end

    -- Yield to any in-flight click/walk task
    if tracker.warplan.test.pending        then return false end
    if tracker.warplan.next_obj.pending    then return false end
    if tracker.warplan.turn_in.pending     then return false end
    if tracker.warplan.start_cycle.pending then return false end
    if tracker.undercity.enter.pending     then return false end

    return true   -- always run when no other task is active in War Plan mode
end

task.Execute = function ()
    local wp   = tracker.warplan.snapshot
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil

    -- No active warplan → no sub-plugin should be on
    if not (wp and wp.active and wp.quest) then
        if tracker.warplan.active_sub_plugin then
            enable_plugin(nil)
        end
        task.status = 'no warplan'
        return
    end

    -- Turn-in phase → no sub-plugin (WarMachine's turn_in task handles it)
    if wp.activity == 'turnin' then
        if tracker.warplan.active_sub_plugin then
            enable_plugin(nil)
        end
        task.status = 'turn-in pending'
        return
    end

    -- We have an active activity. Are we in its runtime zone?
    local target_tag = PLUGIN_FOR_ACTIVITY[wp.activity]
    if not target_tag then
        task.status = 'unknown activity ' .. tostring(wp.activity)
        return
    end

    if in_activity_zone(zone, wp.activity) then
        -- Hand off to the sub-plugin. For pit specifically, ArkhamAsylum
        -- stays enabled even after the boss dies so its upgrade_glyph task
        -- handles the gizmo. tasks/pit/post_boss waits for the gizmo to
        -- despawn (= upgrade complete), then disables the sub-plugin and
        -- fires Next-Obj for exit.
        enable_plugin(target_tag)
        task.status = 'sub-plugin: ' .. target_tag
    else
        -- Wrong zone for the activity. Sub-plugin must be off so it doesn't
        -- run from the wrong town (e.g. SigilRunner tries to consume a
        -- sigil if enabled in town with sigils — bad while in War Plan).
        if tracker.warplan.active_sub_plugin then
            enable_plugin(nil)
        end
        task.status = string.format('waiting for %s zone', wp.activity)
    end
end

return task
