-- ---------------------------------------------------------------------------
-- tasks/warplan/supervisor.lua
--
-- Sub-plugin orchestrator. Replaces the old per-activity supervisor that
-- duplicated logic from SigilRunner / HelltideRevamped / WonderCity /
-- ArkhamAsylum. Now WarMachine simply enables the matching sub-plugin
-- when the player is in the activity zone, and disables it on transition.
--
-- Activity -> sub-plugin map:
--   nightmare -> SigilRunnerPlugin
--   helltide  -> HelltideRevampedPlugin
--   undercity -> WonderCityPlugin
--   pit       -> ArkhamAsylumPlugin
--   hordes    -> InfernalHordesPlugin (HordeDev)
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
-- Post-boss pit guard.
--
-- The pit WarPlan quest completes the moment the boss dies (the host
-- removes it from the quest log).  That makes wp.active flip false before
-- tasks/pit/post_boss.lua has walked to the glyph gizmo + run its upgrade
-- UI.  Without this guard the supervisor would see "wp inactive -> disable
-- sub-plugin" and dispatch would immediately fire next_obj, teleporting us
-- to the next WarPlan objective before any glyphs are upgraded.
--
-- Guard: while we're in PIT_*, tracker.pit.glyph_gizmo_seen is true (set
-- by post_boss.lua on first gizmo sight, cleared when it fires next_obj),
-- refuse to fire any sub-plugin transitions or dispatch.
-- ---------------------------------------------------------------------------
local function in_pit_zone()
    local w = get_current_world()
    local z = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    return z and z:match('^PIT_') ~= nil
end

local function pit_post_boss_pending()
    if not in_pit_zone() then return false end
    -- post_boss.lua sets glyph_gizmo_seen=true when the gizmo first appears and
    -- resets it to false inside fire_next_obj_exit() when the upgrade is done.
    -- That window is exactly what we need to block here.
    if not (tracker.pit and tracker.pit.glyph_gizmo_seen) then return false end
    local ok, pit_set = pcall(require, 'activities.pit.settings')
    if ok and pit_set and pit_set.interact_glyph == false then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- Hordes post-boss guard: stops dispatch from firing Next-Obj once the
-- boss has been killed but the chest-opening phase isn't done.  The
-- WarPlan objective ticks the moment the boss dies, so wp.activity can
-- flip to 'turnin' (or change to a different activity in a multi-step
-- plan) while the bot is still in S05_BSK_*.  Without this guard
-- dispatch happily teleports us out of the arena before we touch a
-- single chest.
--
-- Triggers: in a hordes zone, and the hordes activity set boss_killed
-- but not yet run_done.  exit.lua sets run_done when the chest pass
-- finishes (chest_opened && no chest visible) -- see exit.lua.
-- ---------------------------------------------------------------------------
local function in_hordes_zone()
    local w = get_current_world()
    local z = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if not z then return false end
    return z == 'S05_BSK_Prototype02' or z:match('^S05_BSK_') ~= nil
end

local function hordes_post_boss_pending()
    if not in_hordes_zone() then return false end
    local ok, ht = pcall(require, 'activities.hordes.tracker')
    if not ok or not ht then return false end
    -- Only engage once boss_killed (otherwise this would block the entire
    -- run setup, including the initial wave start).  Release once exit.lua
    -- flips run_done.
    return ht.boss_killed and not ht.run_done
end

-- ---------------------------------------------------------------------------
-- Activity -> plugin tag -> plugin-global lookup
-- ---------------------------------------------------------------------------

local PLUGIN_FOR_ACTIVITY = {
    nightmare = 'sigilrunner',
    helltide  = 'helltide',
    undercity = 'wondercity',
    pit       = 'arkhamasylum',
    hordes    = 'hordedev',
    boss      = 'reaper',
}

local function get_plugin(tag)
    if tag == 'sigilrunner'  then return SigilRunnerPlugin end
    if tag == 'helltide'     then return HelltideRevampedPlugin end
    if tag == 'wondercity'   then return WonderCityPlugin end
    if tag == 'arkhamasylum' then return ArkhamAsylumPlugin end
    if tag == 'hordedev'     then return InfernalHordesPlugin end
    if tag == 'reaper'       then return ReaperPlugin end
    return nil
end

-- ---------------------------------------------------------------------------
-- Internal-module check: when WarMachine's own activities/<tag>/api.lua is
-- loaded for the warplan activity, the legacy external plugin (Arkham,
-- WonderCity, etc.) should NOT be toggled on -- the internal module
-- handles in-zone gameplay via activity_manager.pulse(WARPLAN).
-- This lets the two coexist gracefully during the transition: external
-- plugins still installed get correctly disabled by us; once they're
-- uninstalled (cleanup phase), this just becomes a no-op.
-- ---------------------------------------------------------------------------
local function activity_has_internal_module(wp_activity)
    -- Map warplan activity name -> activity_manager tag
    local tag = wp_activity
    if wp_activity == 'nightmare' then tag = 'nmd' end
    if not tag then return false end
    local ok, am = pcall(require, 'core.activity_manager')
    if not ok or not am or not am.is_activity_loaded then return false end
    return am.is_activity_loaded(tag)
end

local function classify_zone(zone)
    if not zone then return 'unknown' end
    if zone == 'Skov_Temis' then return 'temis' end
    if zone:match('^DGN_') then return 'dungeon' end
    if zone:match('^X1_Undercity_') then return 'undercity' end
    if zone:match('^PIT_') then return 'pit' end
    -- Infernal Hordes arena (S05_BSK_Prototype02 historically; if the host
    -- ever splits Hordes into multiple zone names, prefix-match here).
    if zone == 'S05_BSK_Prototype02' or zone:match('^S05_BSK_') then return 'hordes' end
    -- Boss-altar zones (Andariel/Duriel/Varshan/Grigoire/Zir/Beast/Harbinger
    -- /Urivar/Belial/Butcher).  Mirrors dispatch.classify_zone.
    if zone:match('^Boss_') or zone:match('^S12_Boss_') or zone:find('_Varshan', 1, true) then
        return 'boss'
    end
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
    if activity == 'hordes'    then return zc == 'hordes'    end
    if activity == 'boss'      then return zc == 'boss'      end
    -- Safety fallback: unrecognized quest name -> stay put in any non-hub zone.
    if activity == 'unknown' and zc ~= 'temis' and zc ~= 'overworld' then
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Plugin enable/disable with state tracking. Idempotent -- only logs +
-- calls the facade when the active plugin actually changes.
-- ---------------------------------------------------------------------------

local function enable_plugin(tag)
    if tracker.warplan.active_sub_plugin == tag then return end
    -- Disable whatever was running before. pcall so a buggy disable() in
    -- one sub-plugin doesn't prevent us from updating active_sub_plugin
    -- and trap WarMachine in a thrash loop.
    if tracker.warplan.active_sub_plugin then
        local old = get_plugin(tracker.warplan.active_sub_plugin)
        if old and old.disable then
            console.print('[WarMachine] disabling sub-plugin: ' .. tracker.warplan.active_sub_plugin)
            local ok, err = pcall(old.disable)
            if not ok then
                console.print('[WarMachine] disable error (' ..
                    tracker.warplan.active_sub_plugin .. '): ' .. tostring(err))
            end
        end
    end
    -- Enable the new one (also pcall'd for the same reason).
    if tag then
        local p = get_plugin(tag)
        if p and p.enable then
            console.print('[WarMachine] enabling sub-plugin: ' .. tag)
            local ok, err = pcall(p.enable)
            if not ok then
                console.print('[WarMachine] enable error (' .. tag .. '): ' .. tostring(err))
            end
        else
            console.print('[WarMachine] sub-plugin not loaded: ' .. tag)
        end
    end
    -- Always update the tracker, even on enable/disable error: otherwise
    -- supervisor.shouldExecute keeps seeing active != target_tag and we
    -- re-fire the same broken enable every pulse.
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

    -- Pit post-boss guard: don't touch sub-plugins while post_boss.lua is
    -- mid-upgrade.  See pit_post_boss_pending() comment.
    if pit_post_boss_pending() then return false end

    -- Hordes post-boss guard: same idea -- once the boss dies the WarPlan
    -- objective ticks (so wp.activity may flip away from 'hordes' or to
    -- 'turnin') but we still need to finish the chest-opening phase.
    -- Yield until the hordes activity sets run_done.
    if hordes_post_boss_pending() then return false end

    -- Yield to any in-flight click/walk task
    if tracker.warplan.test.pending        then return false end
    if tracker.warplan.next_obj.pending    then return false end
    if tracker.warplan.turn_in.pending     then return false end
    if tracker.warplan.start_cycle.pending then return false end
    if tracker.undercity.enter.pending     then return false end

    -- Supervisor's job is purely sub-plugin enable/disable. It has NO
    -- transit logic -- moving the player between zones is dispatch's job
    -- via Next-Obj. We claim the pulse only when there's actual
    -- orchestration work to do; otherwise yield so dispatch can run.
    --
    -- Cases that need work:
    --   * Active warplan + in matching activity zone + sub-plugin not yet
    --     enabled (or wrong one enabled) -> enable correct one
    --   * Sub-plugin currently enabled but should be off (no warplan,
    --     turnin phase, or wrong zone for activity) -> disable it
    -- All other cases: nothing to do, yield to dispatch.
    local wp     = tracker.warplan.snapshot
    local zone   = get_current_world() and get_current_world():get_current_zone_name() or nil
    local active = tracker.warplan.active_sub_plugin

    -- No active warplan -> sub-plugin must be off
    if not (wp and wp.active and wp.quest) then
        return active ~= nil   -- claim only if cleanup needed
    end

    -- Turn-in phase -> sub-plugin must be off
    if wp.activity == 'turnin' then
        return active ~= nil
    end

    local target_tag = PLUGIN_FOR_ACTIVITY[wp.activity]
    if not target_tag then
        -- Unknown activity. Disable any leftover sub-plugin; otherwise yield.
        return active ~= nil
    end

    if in_activity_zone(zone, wp.activity) then
        -- We're in the activity zone -> sub-plugin must be the matching one.
        return active ~= target_tag
    end

    -- Active warplan but wrong zone for it. Sub-plugin must be off so it
    -- doesn't fight WarMachine's transit (e.g. SigilRunner trying to run
    -- from a town zone). Otherwise yield to dispatch (which will fire
    -- Next-Obj to teleport us to the activity).
    return active ~= nil
end

task.Execute = function ()
    local wp   = tracker.warplan.snapshot
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil

    -- No active warplan -> no sub-plugin should be on
    if not (wp and wp.active and wp.quest) then
        if tracker.warplan.active_sub_plugin then
            enable_plugin(nil)
        end
        task.status = 'no warplan'
        return
    end

    -- Turn-in phase -> no sub-plugin (WarMachine's turn_in task handles it)
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
        -- If WarMachine's own activities/<tag>/api.lua is loaded, the
        -- internal module drives in-zone gameplay via activity_manager
        -- (called from main.lua's WARPLAN dispatch).  We also disable any
        -- still-installed legacy external plugin so they don't fight.
        if activity_has_internal_module(wp.activity) then
            if tracker.warplan.active_sub_plugin then
                enable_plugin(nil)   -- shut off any legacy external plugin
            end
            task.status = 'internal-module: ' .. tostring(wp.activity)
        else
            -- Legacy path: enable the external sub-plugin (Arkham,
            -- WonderCity, etc.).  For pit specifically, ArkhamAsylum
            -- stays enabled even after the boss dies so its upgrade_glyph
            -- task handles the gizmo.  tasks/pit/post_boss waits for the
            -- gizmo to despawn (= upgrade complete), then disables the
            -- sub-plugin and fires Next-Obj for exit.
            enable_plugin(target_tag)
            task.status = 'sub-plugin: ' .. target_tag
        end
    else
        -- Wrong zone for the activity. Sub-plugin must be off so it doesn't
        -- run from the wrong town (e.g. SigilRunner tries to consume a
        -- sigil if enabled in town with sigils -- bad while in War Plan).
        if tracker.warplan.active_sub_plugin then
            enable_plugin(nil)
        end
        task.status = string.format('waiting for %s zone', wp.activity)
    end
end

return task
