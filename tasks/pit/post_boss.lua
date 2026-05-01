-- ---------------------------------------------------------------------------
-- tasks/pit/post_boss.lua
--
-- Pit-clear handoff. ArkhamAsylum does the glyph upgrade (its own
-- upgrade_glyph task interacts with the gizmo and walks through the UI);
-- WarMachine only watches for the upgrade to finish, then disables
-- ArkhamAsylum and fires the shared Next-Obj exit so we don't tp to
-- Cerrigar (which is what ArkhamAsylum's exit_pit hardcodes).
--
-- Detection sequence:
--   1. While in PIT_* and Gizmo_Paragon_Glyph_Upgrade is in stream:
--      mark glyph_gizmo_seen, do nothing (ArkhamAsylum handles upgrade).
--   2. When ArkhamAsylumPlugin.is_glyph_done() returns true:
--      hard-disable Batmobile (so it stops drifting during the map+tp
--      sequence), disable ArkhamAsylum, fire Next-Obj, reset state.
--
-- Why we wait on is_glyph_done() instead of "gizmo despawned":
--   The actor stream can briefly drop the gizmo during ArkhamAsylum's
--   interact_object() call, which previously raced the post-boss exit
--   ahead of the actual upgrade.  is_glyph_done() flips when ArkhamAsylum
--   has confirmed the upgrade UI processed all upgradable glyphs.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'

local GLYPH_GIZMO_SKIN = 'Gizmo_Paragon_Glyph_Upgrade'

local task = { name = 'pit_post_boss', status = nil }

local function in_pit()
    local w = get_current_world()
    if not w then return false end
    local n = w:get_name()
    return n ~= nil and n:match('^PIT_') ~= nil
end

local function find_glyph_gizmo()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a:get_skin_name() == GLYPH_GIZMO_SKIN then return a end
    end
    return nil
end

task.shouldExecute = function ()
    if settings.mode ~= mode.WARPLAN then return false end
    if not in_pit() then return false end
    -- Fire while the gizmo is visible (mark seen) OR after we've seen it
    -- earlier (so we keep polling until ArkhamAsylum signals glyph_done).
    return find_glyph_gizmo() ~= nil or tracker.pit.glyph_gizmo_seen == true
end

task.Execute = function ()
    local now   = get_time_since_inject()
    local state = tracker.pit
    local gizmo = find_glyph_gizmo()

    if gizmo then
        -- First time we see it -- mark and let ArkhamAsylum's upgrade_glyph
        -- task take care of the interaction + UI clicks.
        if not state.glyph_gizmo_seen then
            state.glyph_gizmo_seen = true
            console.print('[WarMachine] pit: glyph gizmo appeared -- ArkhamAsylum handles upgrade')
        end
        task.status = 'glyph upgrade (sub-plugin)'
        return
    end

    -- Gizmo not in stream this pulse.  Don't trust that signal alone --
    -- it briefly drops during ArkhamAsylum's interact_object() and would
    -- race-trigger the exit before the upgrade actually completed.  Wait
    -- for ArkhamAsylum to confirm via tracker.glyph_done.
    local arkham_done = ArkhamAsylumPlugin
        and ArkhamAsylumPlugin.is_glyph_done
        and ArkhamAsylumPlugin.is_glyph_done()
    if not arkham_done then
        task.status = 'glyph upgrade in progress'
        return
    end

    -- Both signals confirm: upgrade complete.
    -- Take over: hard-disable Batmobile (pause is futile -- main.lua's
    -- freeroam loop unconditionally unpauses it), disable ArkhamAsylum,
    -- fire Next-Obj.
    if tracker.warplan.active_sub_plugin then
        if ArkhamAsylumPlugin and ArkhamAsylumPlugin.disable then
            console.print('[WarMachine] pit: glyph upgrade complete -- disabling ArkhamAsylum')
            ArkhamAsylumPlugin.disable()
        end
        tracker.warplan.active_sub_plugin = nil
    end

    -- Hard stop the internal walker so it doesn't keep walking during
    -- the map+tp sequence.
    local wok, walker = pcall(require, 'core.walker')
    if wok and walker and walker.stop then walker.stop() end

    if not tracker.warplan.next_obj.pending then
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
        console.print('[WarMachine] pit: triggering Next-Obj exit')
        task.status = 'exit via Next-Obj'

        -- Reset pit state for the next cycle
        state.glyph_gizmo_seen    = false
        state.glyph_interacted_at = nil
        state.start_time          = -1
        state.exit_trigger_time   = nil
    end
end

return task
