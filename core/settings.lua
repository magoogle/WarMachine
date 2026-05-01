-- ---------------------------------------------------------------------------
-- WarMachine settings -- unified bot.
-- Activity-specific settings (per-mode tuning) live under settings.<activity>
-- and are populated from each activities/<name>/settings.lua module's GUI
-- bindings.  This file owns only the top-level mode + the WarPlan/Pit/UC
-- click-points the orchestrator drives directly.
-- ---------------------------------------------------------------------------

local gui  = require 'gui'
local mode = require 'core.mode'

local settings = {
    plugin_label   = gui.plugin_label,
    plugin_version = gui.plugin_version,

    enabled    = false,
    mode       = mode.WARPLAN,   -- default to War Plan; user can pick from dropdown
    debug_mode = false,

    -- War Plan automation namespace + Undercity click-points
    warplan   = {},
    undercity = {},
    -- Pit (War Plan) settings. Populated from gui.elements.pit_*
    -- Only used by tasks/pit/enter.lua when a Pit war plan is active.
    pit       = { auto_enter = true, level = 1 },
}

settings.get_keybind_state = function ()
    local toggle_key   = gui.elements.keybind_toggle:get_key()
    local toggle_state = gui.elements.keybind_toggle:get_state()
    local use_keybind  = gui.elements.use_keybind:get()
    if not use_keybind then return true end
    if use_keybind and toggle_key ~= 0x0A and toggle_state == 1 then return true end
    return false
end

-- Track whether we've logged the missing-deps message this enable cycle,
-- so we don't spam the console every pulse.
local _logged_dep_warning = false

settings.update_settings = function ()
    local toggle_state  = gui.elements.main_toggle:get()
    settings.debug_mode = gui.elements.debug_mode:get()
    -- Read run mode from the dropdown.
    settings.mode = mode.from_index(gui.elements.mode_select:get())

    -- Gate enable on the (now-much-shorter) hard-required dependency list.
    -- Currently only Batmobile is required; everything else is internal or
    -- optional.
    if toggle_state and not gui.has_all_dependencies() then
        if not _logged_dep_warning then
            local missing = gui.get_missing_dependencies()
            console.print('[WarMachine] DISABLED: missing required plugin -> ' ..
                table.concat(missing, ', '))
            _logged_dep_warning = true
        end
        settings.enabled = false
    else
        settings.enabled = toggle_state
        if not toggle_state then _logged_dep_warning = false end   -- reset on user-toggle-off
    end

    -- War Plan automation
    settings.warplan.auto_next_obj      = gui.elements.warplan_auto_next_obj:get()
    settings.warplan.auto_turn_in       = gui.elements.warplan_auto_turn_in:get()
    settings.warplan.auto_select        = gui.elements.warplan_auto_select:get()
    settings.warplan.auto_cycle         = gui.elements.warplan_auto_cycle:get()
    settings.warplan.whisper_turn_in    = gui.elements.warplan_whisper_turn_in
                                              and gui.elements.warplan_whisper_turn_in:get()
                                              or false
    -- Click points are stored in the GUI as integer percentages so the
    -- slider widget works; convert to 0..1 fractions for the click code.
    -- Defensive `and ... or default` so a missing GUI element falls back
    -- to the canonical default.
    local function pct_frac(elem, default_pct)
        if not elem then return default_pct / 100.0 end
        return (elem:get() or default_pct) / 100.0
    end
    settings.warplan.whisper_reward_x_frac = pct_frac(gui.elements.warplan_whisper_reward_x_pct, 40)
    settings.warplan.whisper_reward_y_frac = pct_frac(gui.elements.warplan_whisper_reward_y_pct, 55)
    settings.warplan.whisper_accept_x_frac = pct_frac(gui.elements.warplan_whisper_accept_x_pct, 50)
    settings.warplan.whisper_accept_y_frac = pct_frac(gui.elements.warplan_whisper_accept_y_pct, 85)
    settings.warplan.show_whisper_points   = gui.elements.warplan_show_whisper_points
                                                and gui.elements.warplan_show_whisper_points:get()
                                                or false
    settings.warplan.show_click_points  = gui.elements.warplan_show_points:get()

    -- Row Y values are shared across the 3 slots in each row -- the
    -- vendor-menu cards in a row sit at the same screen height in-game,
    -- so independent Y per slot was busywork.  See gui.lua warplan_cp_row*_y.
    local row1_y = gui.elements.warplan_cp_row1_y:get()
    local row2_y = gui.elements.warplan_cp_row2_y:get()
    local row3_y = gui.elements.warplan_cp_row3_y:get()
    local row4_y = gui.elements.warplan_cp_row4_y:get()
    local row5_y = gui.elements.warplan_cp_row5_y:get()
    settings.warplan.click_points = {
        slots = {
            { x = gui.elements.warplan_cp_s1_x:get(),  y = row1_y, label = '1' },
            { x = gui.elements.warplan_cp_s2_x:get(),  y = row1_y, label = '2' },
            { x = gui.elements.warplan_cp_s3_x:get(),  y = row1_y, label = '3' },
            { x = gui.elements.warplan_cp_s4_x:get(),  y = row2_y, label = '4' },
            { x = gui.elements.warplan_cp_s5_x:get(),  y = row2_y, label = '5' },
            { x = gui.elements.warplan_cp_s6_x:get(),  y = row2_y, label = '6' },
            { x = gui.elements.warplan_cp_s7_x:get(),  y = row3_y, label = '7' },
            { x = gui.elements.warplan_cp_s8_x:get(),  y = row3_y, label = '8' },
            { x = gui.elements.warplan_cp_s9_x:get(),  y = row3_y, label = '9' },
            { x = gui.elements.warplan_cp_s10_x:get(), y = row4_y, label = '10' },
            { x = gui.elements.warplan_cp_s11_x:get(), y = row4_y, label = '11' },
            { x = gui.elements.warplan_cp_s12_x:get(), y = row4_y, label = '12' },
            { x = gui.elements.warplan_cp_s13_x:get(), y = row5_y, label = '13' },
            { x = gui.elements.warplan_cp_s14_x:get(), y = row5_y, label = '14' },
            { x = gui.elements.warplan_cp_s15_x:get(), y = row5_y, label = '15' },
        },
        start          = { x = gui.elements.warplan_cp_start_x:get(),   y = gui.elements.warplan_cp_start_y:get(),   label = 'START'    },
        confirm        = { x = gui.elements.warplan_cp_confirm_x:get(), y = gui.elements.warplan_cp_confirm_y:get(), label = 'Confirm'  },
        next_objective = { x = gui.elements.warplan_cp_nextobj_x:get(), y = gui.elements.warplan_cp_nextobj_y:get(), label = 'Next Obj' },
    }

    -- Undercity entry click point (war-plan UC entry from Skov_Temis)
    settings.undercity.auto_enter = gui.elements.undercity_auto_enter:get()
    settings.undercity.click_points = {
        open_portal = {
            x = gui.elements.undercity_cp_open_portal_x:get(),
            y = gui.elements.undercity_cp_open_portal_y:get(),
            label = 'Open Portal',
        },
    }

    -- Pit entry (war-plan Pit entry from Skov_Temis Pit Obelisk).
    -- Standalone Pit (ArkhamAsylum) still uses legacy Cerrigar; this
    -- table only feeds WarMachine's tasks/pit/enter.lua.
    settings.pit.auto_enter = gui.elements.pit_auto_enter:get()
    settings.pit.level      = gui.elements.pit_level:get()
end

return settings
