-- ---------------------------------------------------------------------------
-- WarMachine settings — namespaced by activity.
-- Phase 1: only master + mode + debug. Per-activity sub-tables filled later.
-- ---------------------------------------------------------------------------

local gui = require 'gui'

local settings = {
    plugin_label   = gui.plugin_label,
    plugin_version = gui.plugin_version,

    enabled    = false,
    mode       = 0,        -- index into gui.modes (0=Idle)
    debug_mode = false,

    -- Per-activity namespaces — populated in later phases.
    helltide  = {},
    nmd       = {},
    undercity = {},
    warplan   = {},
}

-- Returns true when the keybind is held / not in use.
settings.get_keybind_state = function ()
    local toggle_key   = gui.elements.keybind_toggle:get_key()
    local toggle_state = gui.elements.keybind_toggle:get_state()
    local use_keybind  = gui.elements.use_keybind:get()
    if not use_keybind then return true end
    if use_keybind and toggle_key ~= 0x0A and toggle_state == 1 then return true end
    return false
end

settings.update_settings = function ()
    settings.enabled    = gui.elements.main_toggle:get()
    settings.mode       = gui.elements.mode_select:get()
    settings.debug_mode = gui.elements.debug_mode:get()

    -- War Plan automation toggles (Phase 5)
    settings.warplan.auto_next_obj = gui.elements.warplan_auto_next_obj:get()
    settings.warplan.auto_turn_in  = gui.elements.warplan_auto_turn_in:get()
    settings.warplan.auto_select   = gui.elements.warplan_auto_select:get()
    settings.warplan.auto_cycle    = gui.elements.warplan_auto_cycle:get()

    -- War Plan vendor click points (Phase 5 prototype)
    settings.warplan.show_click_points = gui.elements.warplan_show_points:get()
    settings.warplan.click_points = {
        slots = {
            { x = gui.elements.warplan_cp_s1_x:get(),  y = gui.elements.warplan_cp_s1_y:get(),  label = '1' },
            { x = gui.elements.warplan_cp_s2_x:get(),  y = gui.elements.warplan_cp_s2_y:get(),  label = '2' },
            { x = gui.elements.warplan_cp_s3_x:get(),  y = gui.elements.warplan_cp_s3_y:get(),  label = '3' },
            { x = gui.elements.warplan_cp_s4_x:get(),  y = gui.elements.warplan_cp_s4_y:get(),  label = '4' },
            { x = gui.elements.warplan_cp_s5_x:get(),  y = gui.elements.warplan_cp_s5_y:get(),  label = '5' },
            { x = gui.elements.warplan_cp_s6_x:get(),  y = gui.elements.warplan_cp_s6_y:get(),  label = '6' },
            { x = gui.elements.warplan_cp_s7_x:get(),  y = gui.elements.warplan_cp_s7_y:get(),  label = '7' },
            { x = gui.elements.warplan_cp_s8_x:get(),  y = gui.elements.warplan_cp_s8_y:get(),  label = '8' },
            { x = gui.elements.warplan_cp_s9_x:get(),  y = gui.elements.warplan_cp_s9_y:get(),  label = '9' },
            { x = gui.elements.warplan_cp_s10_x:get(), y = gui.elements.warplan_cp_s10_y:get(), label = '10' },
            { x = gui.elements.warplan_cp_s11_x:get(), y = gui.elements.warplan_cp_s11_y:get(), label = '11' },
            { x = gui.elements.warplan_cp_s12_x:get(), y = gui.elements.warplan_cp_s12_y:get(), label = '12' },
            { x = gui.elements.warplan_cp_s13_x:get(), y = gui.elements.warplan_cp_s13_y:get(), label = '13' },
            { x = gui.elements.warplan_cp_s14_x:get(), y = gui.elements.warplan_cp_s14_y:get(), label = '14' },
            { x = gui.elements.warplan_cp_s15_x:get(), y = gui.elements.warplan_cp_s15_y:get(), label = '15' },
        },
        start = { x = gui.elements.warplan_cp_start_x:get(), y = gui.elements.warplan_cp_start_y:get(), label = 'START' },
        confirm = {
            x = gui.elements.warplan_cp_confirm_x:get(),
            y = gui.elements.warplan_cp_confirm_y:get(),
            label = 'Confirm',
        },
        next_objective = {
            x = gui.elements.warplan_cp_nextobj_x:get(),
            y = gui.elements.warplan_cp_nextobj_y:get(),
            label = 'Next Obj',
        },
    }

    -- Undercity automation
    settings.undercity.auto_enter = gui.elements.undercity_auto_enter:get()
    settings.undercity.click_points = {
        open_portal = {
            x = gui.elements.undercity_cp_open_portal_x:get(),
            y = gui.elements.undercity_cp_open_portal_y:get(),
            label = 'Open Portal',
        },
    }

    -- Nightmare standalone
    settings.nmd.auto_use_sigil = gui.elements.nmd_auto_use_sigil:get()
    settings.nmd.min_tier       = gui.elements.nmd_min_tier:get()    -- 0=Any
    settings.nmd.max_tier       = gui.elements.nmd_max_tier:get()
    settings.nmd.map_click = {
        x = gui.elements.nmd_map_x:get(),
        y = gui.elements.nmd_map_y:get(),
        label = 'Map NMD',
    }
end

return settings
