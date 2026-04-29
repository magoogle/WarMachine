-- ---------------------------------------------------------------------------
-- WarMachine v0.2 by Magoogle -- orchestrator-only GUI
--
-- WarMachine drives the War Plan cycle (vendor menu, tp, turn-in) and
-- enables/disables the appropriate sub-plugin per active activity.
-- Sub-plugins handle in-zone runtime; their own GUIs configure their
-- own behavior. WarMachine does not duplicate per-activity settings.
-- ---------------------------------------------------------------------------

local plugin_label   = 'warmachine'
local plugin_version = '0.2'
console.print('Lua Plugin - WarMachine v' .. plugin_version .. ' by Magoogle (orchestrator)')

local gui = {}

-- ---------------------------------------------------------------------------
-- Required sub-plugin dependencies. WarMachine is an orchestrator and
-- cannot run any activity itself -- each sub-plugin owns its activity.
-- The folder name shown is the canonical one; suffix variants such as
-- "ArkhamAsylum-v1.0" or "ArkhamAsylum1" are tolerated automatically
-- because the plugin global (e.g. ArkhamAsylumPlugin) is set by the
-- plugin's main.lua regardless of which folder it lives in.
-- ---------------------------------------------------------------------------
local REQUIRED_PLUGINS = {
    { folder = 'Batmobile',        global = 'BatmobilePlugin'        },
    { folder = 'ArkhamAsylum',     global = 'ArkhamAsylumPlugin'     },
    { folder = 'HelltideRevamped', global = 'HelltideRevampedPlugin' },
    { folder = 'SigilRunner',      global = 'SigilRunnerPlugin'      },
    { folder = 'WonderCity',       global = 'WonderCityPlugin'       },
}

local function get_missing_dependencies()
    local missing = {}
    for _, dep in ipairs(REQUIRED_PLUGINS) do
        if _G[dep.global] == nil then
            missing[#missing + 1] = dep.folder
        end
    end
    return missing
end

-- Public check used by settings.update_settings to gate the master toggle.
gui.has_all_dependencies = function ()
    return #get_missing_dependencies() == 0
end
gui.get_missing_dependencies = get_missing_dependencies

local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. '_' .. key))
end
local function co(default, key)
    return combo_box:new(default, get_hash(plugin_label .. '_' .. key))
end
local function si(min, max, default, key)
    return slider_int:new(min, max, default, get_hash(plugin_label .. '_' .. key))
end
local function btn(key)
    return button:new(get_hash(plugin_label .. '_' .. key))
end

-- Mode list (combo-box index)
gui.modes = { 'Idle', 'War Plan' }

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.elements = {
    main_tree      = tree_node:new(0),
    main_toggle    = cb(false, 'main_toggle'),
    use_keybind    = cb(false, 'use_keybind'),
    keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle')),

    -- Hash key bumped (mode_select_v2) to invalidate any saved combo-box
    -- state from the pre-orchestrator versions (mode used to range 0..6
    -- with Hordes=5 / Pit=6 -- those indices are out of range now and
    -- crash the host's combo_box render).
    mode_select    = co(1, 'mode_select_v2'),  -- default to War Plan

    -- War Plan automation toggles
    warplan_auto_tree   = tree_node:new(1),
    warplan_auto_next_obj = cb(true,  'warplan_auto_next_obj'),
    warplan_auto_turn_in  = cb(true,  'warplan_auto_turn_in'),
    warplan_auto_select   = cb(true,  'warplan_auto_select'),
    warplan_auto_cycle    = cb(false, 'warplan_auto_cycle'),

    -- War Plan vendor menu click points
    warplan_cp_tree     = tree_node:new(1),
    warplan_show_points = cb(false, 'warplan_show_points'),

    -- 5 rows x 3 cols = 15 slot click-points covering the WAR PLANS menu
    -- Row 1 (red)
    warplan_cp_s1_x  = si(0, 3840, 320, 'warplan_cp_s1_x'),
    warplan_cp_s1_y  = si(0, 2160, 360, 'warplan_cp_s1_y'),
    warplan_cp_s2_x  = si(0, 3840, 470, 'warplan_cp_s2_x'),
    warplan_cp_s2_y  = si(0, 2160, 360, 'warplan_cp_s2_y'),
    warplan_cp_s3_x  = si(0, 3840, 620, 'warplan_cp_s3_x'),
    warplan_cp_s3_y  = si(0, 2160, 360, 'warplan_cp_s3_y'),
    -- Row 2 (green)
    warplan_cp_s4_x  = si(0, 3840, 320, 'warplan_cp_s4_x'),
    warplan_cp_s4_y  = si(0, 2160, 510, 'warplan_cp_s4_y'),
    warplan_cp_s5_x  = si(0, 3840, 470, 'warplan_cp_s5_x'),
    warplan_cp_s5_y  = si(0, 2160, 510, 'warplan_cp_s5_y'),
    warplan_cp_s6_x  = si(0, 3840, 620, 'warplan_cp_s6_x'),
    warplan_cp_s6_y  = si(0, 2160, 510, 'warplan_cp_s6_y'),
    -- Row 3 (yellow)
    warplan_cp_s7_x  = si(0, 3840, 320, 'warplan_cp_s7_x'),
    warplan_cp_s7_y  = si(0, 2160, 660, 'warplan_cp_s7_y'),
    warplan_cp_s8_x  = si(0, 3840, 470, 'warplan_cp_s8_x'),
    warplan_cp_s8_y  = si(0, 2160, 660, 'warplan_cp_s8_y'),
    warplan_cp_s9_x  = si(0, 3840, 620, 'warplan_cp_s9_x'),
    warplan_cp_s9_y  = si(0, 2160, 660, 'warplan_cp_s9_y'),
    -- Row 4 (cyan)
    warplan_cp_s10_x = si(0, 3840, 320, 'warplan_cp_s10_x'),
    warplan_cp_s10_y = si(0, 2160, 810, 'warplan_cp_s10_y'),
    warplan_cp_s11_x = si(0, 3840, 470, 'warplan_cp_s11_x'),
    warplan_cp_s11_y = si(0, 2160, 810, 'warplan_cp_s11_y'),
    warplan_cp_s12_x = si(0, 3840, 620, 'warplan_cp_s12_x'),
    warplan_cp_s12_y = si(0, 2160, 810, 'warplan_cp_s12_y'),
    -- Row 5 (orange)
    warplan_cp_s13_x = si(0, 3840, 320, 'warplan_cp_s13_x'),
    warplan_cp_s13_y = si(0, 2160, 960, 'warplan_cp_s13_y'),
    warplan_cp_s14_x = si(0, 3840, 470, 'warplan_cp_s14_x'),
    warplan_cp_s14_y = si(0, 2160, 960, 'warplan_cp_s14_y'),
    warplan_cp_s15_x = si(0, 3840, 620, 'warplan_cp_s15_x'),
    warplan_cp_s15_y = si(0, 2160, 960, 'warplan_cp_s15_y'),

    -- Top-row UI buttons
    warplan_cp_start_x   = si(0, 3840, 1500, 'warplan_cp_start_x'),
    warplan_cp_start_y   = si(0, 2160, 1000, 'warplan_cp_start_y'),
    warplan_cp_confirm_x = si(0, 3840, 0,    'warplan_cp_confirm_x'),
    warplan_cp_confirm_y = si(0, 2160, 0,    'warplan_cp_confirm_y'),

    -- Map "Next Warplan Objective" button
    warplan_cp_nextobj_x  = si(0, 3840, 960, 'warplan_cp_nextobj_x'),
    warplan_cp_nextobj_y  = si(0, 2160, 960, 'warplan_cp_nextobj_y'),

    -- Undercity entry click point (Undercity Obelisk tribute UI -> Open Portal)
    undercity_auto_enter       = cb(true, 'undercity_auto_enter'),
    undercity_cp_open_portal_x = si(0, 3840, 0, 'undercity_cp_open_portal_x'),
    undercity_cp_open_portal_y = si(0, 2160, 0, 'undercity_cp_open_portal_y'),

    -- Debug
    debug_tree = tree_node:new(2),
    debug_mode = cb(false, 'debug_mode'),
}

gui.render = function ()
    if not gui.elements.main_tree:push('WarMachine v' .. plugin_version .. ' by Magoogle') then return end

    -- Dependency check banner. Block of red-text headers naming each
    -- missing sub-plugin folder. The master toggle is force-disabled in
    -- settings.update_settings when this list is non-empty.
    local missing = get_missing_dependencies()
    if #missing > 0 then
        render_menu_header('==========================================================')
        render_menu_header('  MISSING SUB-PLUGINS -- WarMachine cannot run without these:')
        for _, folder in ipairs(missing) do
            render_menu_header('    * ' .. folder .. '  (or ' .. folder .. '-* variant)')
        end
        render_menu_header('  Install each script into scripts/. The folder name may have')
        render_menu_header('  any suffix (e.g. ' .. missing[1] .. '-v1.0).')
        render_menu_header('  Master toggle is force-disabled until all are present.')
        render_menu_header('==========================================================')
    end

    gui.elements.main_toggle:render('Enable', 'Master enable for WarMachine orchestrator')
    gui.elements.use_keybind:render('Use keybind', 'Keybind to quick-toggle the bot')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind_toggle:render('Toggle Keybind', 'Toggle the bot on/off')
    end

    gui.elements.mode_select:render(
        'Mode', gui.modes,
        'Idle = no-op. War Plan = run the war plan cycle (vendor menu + tp between activities + sub-plugin handoff + turn-in).'
    )

    render_menu_header('WarMachine is the war-plan ORCHESTRATOR. It does not run activities directly -- it enables the matching sub-plugin (SigilRunner / HelltideRevamped / WonderCity / ArkhamAsylum) when each activity is active in the war plan, then disables it on completion. Each sub-plugin must be installed AND have its own main_toggle ON for orchestration to work.')

    if gui.elements.warplan_auto_tree:push('Automation') then
        render_menu_header('Toggles control which steps WarMachine drives automatically. With everything off, mode is observe-only.')
        gui.elements.warplan_auto_next_obj:render('Auto next-objective teleport',
            'Press Tab + click Next-Obj button when player is in the wrong zone for the active war plan.')
        gui.elements.warplan_auto_turn_in:render('Auto turn-in at Tyrael',
            'Walk to Tyrael and interact when WarPlans_QST_TurnIn_Rewards is active.')
        gui.elements.warplan_auto_select:render('Auto select activities',
            'Run the click sequence when the WAR PLANS menu is open and no war plan is active.')
        gui.elements.warplan_auto_cycle:render('Auto-start next cycle',
            'After turn-in, walk back to Warplans_Vendor and start a new war plan automatically. Loop forever.')
        gui.elements.warplan_auto_tree:pop()
    end

    if gui.elements.warplan_cp_tree:push('Vendor menu click points') then
        render_menu_header('Open the War Plans vendor window. Toggle "Show points" to see crosshairs, then drag sliders to align them with each activity slot, START, Confirm popup, and the map Next-Obj button.')
        gui.elements.warplan_show_points:render('Show points', 'Render crosshairs at each click point')

        render_menu_header('5x3 grid covering the WAR PLANS menu. Iteration clicks each cell once -- redundant hits on the same slot toggle it, but full grid coverage guarantees we hit every visible slot.')
        local function row(prefix, color_label, e1x, e1y, e2x, e2y, e3x, e3y)
            e1x:render(prefix .. ' L X', 'Screen X for ' .. prefix .. ' left ('  .. color_label .. ')')
            e1y:render(prefix .. ' L Y', 'Screen Y for ' .. prefix .. ' left')
            e2x:render(prefix .. ' M X', 'Screen X for ' .. prefix .. ' middle')
            e2y:render(prefix .. ' M Y', 'Screen Y for ' .. prefix .. ' middle')
            e3x:render(prefix .. ' R X', 'Screen X for ' .. prefix .. ' right')
            e3y:render(prefix .. ' R Y', 'Screen Y for ' .. prefix .. ' right')
        end
        row('Row 1', 'red',
            gui.elements.warplan_cp_s1_x,  gui.elements.warplan_cp_s1_y,
            gui.elements.warplan_cp_s2_x,  gui.elements.warplan_cp_s2_y,
            gui.elements.warplan_cp_s3_x,  gui.elements.warplan_cp_s3_y)
        row('Row 2', 'green',
            gui.elements.warplan_cp_s4_x,  gui.elements.warplan_cp_s4_y,
            gui.elements.warplan_cp_s5_x,  gui.elements.warplan_cp_s5_y,
            gui.elements.warplan_cp_s6_x,  gui.elements.warplan_cp_s6_y)
        row('Row 3', 'yellow',
            gui.elements.warplan_cp_s7_x,  gui.elements.warplan_cp_s7_y,
            gui.elements.warplan_cp_s8_x,  gui.elements.warplan_cp_s8_y,
            gui.elements.warplan_cp_s9_x,  gui.elements.warplan_cp_s9_y)
        row('Row 4', 'cyan',
            gui.elements.warplan_cp_s10_x, gui.elements.warplan_cp_s10_y,
            gui.elements.warplan_cp_s11_x, gui.elements.warplan_cp_s11_y,
            gui.elements.warplan_cp_s12_x, gui.elements.warplan_cp_s12_y)
        row('Row 5', 'orange',
            gui.elements.warplan_cp_s13_x, gui.elements.warplan_cp_s13_y,
            gui.elements.warplan_cp_s14_x, gui.elements.warplan_cp_s14_y,
            gui.elements.warplan_cp_s15_x, gui.elements.warplan_cp_s15_y)
        gui.elements.warplan_cp_start_x:render('START X', 'Screen X for the START button')
        gui.elements.warplan_cp_start_y:render('START Y', 'Screen Y for the START button')

        render_menu_header('Confirmation popup -- appears after START asking to confirm the war plan. Leave at 0,0 if your war plan doesn\'t show this popup; the step will be skipped.')
        gui.elements.warplan_cp_confirm_x:render('Confirm X', 'Screen X for the Confirm button on the post-START popup (silver crosshair)')
        gui.elements.warplan_cp_confirm_y:render('Confirm Y', 'Screen Y for the Confirm button')

        render_menu_header('Map "Next Warplan Objective" button. Opens map (Tab) and clicks the next-objective marker for a one-step teleport between activities.')
        gui.elements.warplan_cp_nextobj_x:render('Next-Obj X', 'Screen X for the Next-Warplan-Objective button on the map')
        gui.elements.warplan_cp_nextobj_y:render('Next-Obj Y', 'Screen Y for the Next-Warplan-Objective button')

        render_menu_header('Undercity Obelisk Open Portal button -- appears in the tribute UI after interacting with the Undercity Obelisk in Temis. Brown crosshair.')
        gui.elements.undercity_auto_enter:render('Auto-enter Undercity',
            'When in Temis with an active Undercity war plan, walk to the Undercity Obelisk + click Open Portal automatically.')
        gui.elements.undercity_cp_open_portal_x:render('Open Portal X',
            'Screen X for the "Open Portal" button on the Undercity Obelisk tribute menu')
        gui.elements.undercity_cp_open_portal_y:render('Open Portal Y',
            'Screen Y for the "Open Portal" button')

        gui.elements.warplan_cp_tree:pop()
    end

    if gui.elements.debug_tree:push('Debug') then
        gui.elements.debug_mode:render('Debug mode', 'Verbose console logging')
        gui.elements.debug_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui
