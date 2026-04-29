-- ---------------------------------------------------------------------------
-- tasks/pit/post_boss.lua
--
-- Fires when the pit boss is dead — detected by the
-- Gizmo_Paragon_Glyph_Upgrade actor appearing in stream.
--
-- Steps:
--   1. Disable ArkhamAsylum sub-plugin so it stops killing trash mobs and
--      doesn't fire its own exit_pit (which would tp to Cerrigar).
--   2. Walk to the glyph gizmo and interact (opens the upgrade UI).
--   3. Hold a grace period so the glyph upgrade can be applied (auto or
--      by the player).
--   4. Trigger the shared Next-Obj travel to leave the pit and continue
--      the war plan rotation.
--
-- Only active in War Plan mode — standalone Pit mode lets ArkhamAsylum
-- handle exit on its own.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'
local interact = require 'core.interact'

local GLYPH_GIZMO_SKIN     = 'Gizmo_Paragon_Glyph_Upgrade'
local GIZMO_INTERACT_RANGE = 30.0
local GLYPH_GRACE_S        = 10.0   -- after first interact, give upgrade UI time

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
    return find_glyph_gizmo() ~= nil
end

task.Execute = function ()
    local now   = get_time_since_inject()
    local state = tracker.pit

    -- Step 1: stop the sub-plugin (combat, exit_pit) and prevent the
    -- supervisor from re-enabling it on subsequent pulses.
    if tracker.warplan.active_sub_plugin then
        if ArkhamAsylumPlugin and ArkhamAsylumPlugin.disable then
            console.print('[WarMachine] pit cleared — disabling ArkhamAsylum')
            ArkhamAsylumPlugin.disable()
        end
        tracker.warplan.active_sub_plugin = nil
    end

    -- Stop Batmobile from chasing trash
    if BatmobilePlugin and BatmobilePlugin.pause then
        BatmobilePlugin.pause('warmachine')
    end

    state.glyph_gizmo_seen = true

    -- Step 2: walk to the gizmo + interact (D4 walks the final yards).
    local gizmo = find_glyph_gizmo()
    if not gizmo then
        -- Despawned (already upgraded). Skip to exit.
        task.status = 'glyph done — exit pending'
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
            console.print('[WarMachine] pit: glyph gizmo gone, firing Next-Obj exit')
            -- Reset pit state for the next cycle
            state.glyph_interacted_at = nil
            state.glyph_gizmo_seen    = false
            state.start_time          = -1
            state.exit_trigger_time   = nil
        end
        return
    end

    -- First click: opens the glyph upgrade UI
    if not state.glyph_interacted_at then
        local r = interact.walk_and_interact(gizmo, GIZMO_INTERACT_RANGE)
        if r == 'interacted' then
            state.glyph_interacted_at = now
            console.print('[WarMachine] pit: glyph gizmo interacted')
            task.status = 'glyph upgrade UI'
        elseif r == 'too_far' then
            task.status = 'glyph gizmo too far'
        end
        return
    end

    -- Grace period — let the upgrade UI animate / player hand-pick / auto-apply
    local since = now - state.glyph_interacted_at
    if since < GLYPH_GRACE_S then
        task.status = string.format('glyph grace %.1fs', GLYPH_GRACE_S - since)
        return
    end

    -- Step 4: fire Next-Obj to exit the pit (same map-click flow that
    -- handles every other inter-activity travel).
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
        console.print('[WarMachine] pit: glyph done, triggering Next-Obj exit')
        task.status = 'exit via Next-Obj'

        -- Reset pit state for the next cycle
        state.glyph_interacted_at = nil
        state.glyph_gizmo_seen    = false
        state.start_time          = -1
        state.exit_trigger_time   = nil
    end
end

return task
