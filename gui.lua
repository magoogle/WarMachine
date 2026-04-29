-- ---------------------------------------------------------------------------
-- WarMachine v0.1 by Magoogle
-- Phase 1 skeleton: master toggle, keybind, mode selector, placeholder trees.
-- Per-mode settings will be filled in subsequent phases.
-- ---------------------------------------------------------------------------

local plugin_label   = 'warmachine'
local plugin_version = '0.1'
console.print('Lua Plugin - WarMachine v' .. plugin_version .. ' by Magoogle')

local gui = {}

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

-- Mode list — index in this table maps to the combo-box selected value.
gui.modes = {
    'Idle',
    'Helltide',
    'Nightmare',
    'Undercity',
    'War Plan',
    'Hordes',
    'Pit',
}

gui.pit_exit_modes = { 'Reset Dungeons', 'Teleport to Cerrigar' }

gui.sigil_tier_list = { 'Any', 'Common', 'Magic', 'Rare', 'Legendary' }

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.elements = {
    main_tree      = tree_node:new(0),
    main_toggle    = cb(false, 'main_toggle'),
    use_keybind    = cb(false, 'use_keybind'),
    keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle')),

    mode_select    = co(0, 'mode_select'),

    -- Per-mode trees
    helltide_tree  = tree_node:new(1),
    nmd_tree       = tree_node:new(1),
    undercity_tree = tree_node:new(1),
    warplan_tree   = tree_node:new(1),
    hordes_tree    = tree_node:new(1),

    -- Nightmare standalone settings
    nmd_auto_use_sigil = cb(true,  'nmd_auto_use_sigil'),
    nmd_min_tier       = co(0,     'nmd_min_tier'),    -- 0=Any, 1=Common, ..., 4=Legendary
    nmd_max_tier       = co(4,     'nmd_max_tier'),
    nmd_map_x          = si(0, 3840, 0, 'nmd_map_x'),
    nmd_map_y          = si(0, 2160, 0, 'nmd_map_y'),

    -- Helltide settings
    helltide_auto_chests   = cb(true, 'helltide_auto_chests'),
    helltide_min_cinders   = si(50, 300, 75, 'helltide_min_cinders'),
    helltide_pursue_props  = cb(true, 'helltide_pursue_props'),
    helltide_pursue_events = cb(true, 'helltide_pursue_events'),
    helltide_use_shrines   = cb(true, 'helltide_use_shrines'),
    helltide_chase_goblins = cb(true, 'helltide_chase_goblins'),

    -- Pit settings
    pit_tree            = tree_node:new(1),
    pit_auto_enter      = cb(true,  'pit_auto_enter'),
    pit_level           = si(1, 150, 1, 'pit_level'),
    pit_reset_timeout   = si(60, 1800, 600, 'pit_reset_timeout'),
    pit_exit_mode       = co(1, 'pit_exit_mode'),  -- 0=reset, 1=tp to Cerrigar
    pit_interact_shrine = cb(true, 'pit_interact_shrine'),

    -- War Plan automation toggles (Phase 5)
    warplan_auto_tree            = tree_node:new(1),
    warplan_auto_next_obj        = cb(true,  'warplan_auto_next_obj'),
    warplan_auto_turn_in         = cb(true,  'warplan_auto_turn_in'),
    warplan_auto_select          = cb(true,  'warplan_auto_select'),
    warplan_auto_cycle           = cb(false, 'warplan_auto_cycle'),
    warplan_test_confirm_button  = btn('warplan_test_confirm_button'),

    -- War Plan vendor menu click points (Phase 5 prototype — manual configurable)
    warplan_cp_tree     = tree_node:new(1),
    warplan_show_points = cb(false, 'warplan_show_points'),
    warplan_test_button = btn('warplan_test_button'),
    -- 5 rows × 3 columns = 15 click-points covering the WAR PLANS menu.
    -- Iteration clicks each in turn; redundant clicks on the same slot
    -- toggle it but the grid pattern guarantees we hit every visible slot
    -- regardless of the menu's current layout.
    --
    -- Default values lay out a 3-column × 5-row grid roughly covering
    -- (320..620, 360..960). User adjusts in the GUI.
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
    warplan_cp_start_x = si(0, 3840, 1500, 'warplan_cp_start_x'),
    warplan_cp_start_y = si(0, 2160, 1000, 'warplan_cp_start_y'),

    -- Confirmation popup that appears after START — click "Accept" / "Yes"
    warplan_cp_confirm_x = si(0, 3840, 0, 'warplan_cp_confirm_x'),
    warplan_cp_confirm_y = si(0, 2160, 0, 'warplan_cp_confirm_y'),

    -- Undercity entry click points (Undercity Obelisk tribute UI -> Open Portal button)
    undercity_auto_enter   = cb(true, 'undercity_auto_enter'),
    undercity_cp_open_portal_x = si(0, 3840, 0, 'undercity_cp_open_portal_x'),
    undercity_cp_open_portal_y = si(0, 2160, 0, 'undercity_cp_open_portal_y'),

    -- Next-Objective button on the map (Tab opens map, click here to auto-tp)
    warplan_test_next_obj = btn('warplan_test_next_obj'),
    warplan_cp_nextobj_x  = si(0, 3840,  960, 'warplan_cp_nextobj_x'),
    warplan_cp_nextobj_y  = si(0, 2160,  960, 'warplan_cp_nextobj_y'),

    -- Debug
    debug_tree = tree_node:new(2),
    debug_mode = cb(false, 'debug_mode'),
}

gui.render = function ()
    if not gui.elements.main_tree:push('WarMachine v' .. plugin_version .. ' by Magoogle') then return end

    gui.elements.main_toggle:render('Enable', 'Master enable for WarMachine')
    gui.elements.use_keybind:render('Use keybind', 'Keybind to quick-toggle the bot')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind_toggle:render('Toggle Keybind', 'Toggle the bot on/off')
    end

    gui.elements.mode_select:render(
        'Mode',
        gui.modes,
        'Idle = no-op. Pick an activity, or War Plan for the full rotation.'
    )

    -- Activity sections — collapsed placeholders for now
    if gui.elements.helltide_tree:push('Helltide settings') then
        render_menu_header('Standalone Helltide mode + War Plan helltide leg. Bot auto-explores until it can interact with helltide objectives based on the toggles below.')

        gui.elements.helltide_auto_chests:render('Auto open Tortured Gifts',
            'When cinders >= threshold, walk to the nearest Helltide_RewardChest_* and open it.')
        gui.elements.helltide_min_cinders:render('Min cinders to open chest',
            'Wait until cinders are at least this value before pursuing a chest. 75 = lowest-tier chest, 175 = mystery chest tier, 250 = uber chest.')

        render_menu_header('Pursuit toggles — what else the bot should walk to in helltide:')
        gui.elements.helltide_pursue_props:render('Pursue cinder props',
            'Hell_Prop_*Clicky and BreakableContainer entities — give bonus cinders when interacted/destroyed.')
        gui.elements.helltide_pursue_events:render('Pursue events',
            'Flame Pillar (S04_Helltide_FlamePillar_Switch_Dyn) and similar event triggers.')
        gui.elements.helltide_use_shrines:render('Use shrines',
            'Shrine_DRLG when encountered. (Wired in later phases.)')
        gui.elements.helltide_chase_goblins:render('Chase goblins',
            'Treasure Goblin pursuit. (Wired in later phases.)')
        gui.elements.helltide_tree:pop()
    end

    if gui.elements.nmd_tree:push('Nightmare Dungeon settings') then
        render_menu_header('Standalone Nightmare mode: bot uses a sigil from your inventory + clicks the dungeon entrance on the map. Map click point must be configured.')
        gui.elements.nmd_auto_use_sigil:render('Auto consume sigil',
            'When in Nightmare mode + in town with usable sigils, fire the sigil-consume + map-click flow automatically.')
        gui.elements.nmd_min_tier:render('Minimum tier', gui.sigil_tier_list,
            'Skip sigils below this tier. Any = no minimum.')
        gui.elements.nmd_max_tier:render('Maximum tier', gui.sigil_tier_list,
            'Skip sigils above this tier.')
        render_menu_header('Map dungeon-entrance click point — open the world map after consuming a sigil, hover over the dungeon icon, position the magenta crosshair on it.')
        gui.elements.nmd_map_x:render('Map NMD X',
            'Screen X for the dungeon entrance icon on the world map')
        gui.elements.nmd_map_y:render('Map NMD Y',
            'Screen Y for the dungeon entrance icon on the world map')
        gui.elements.nmd_tree:pop()
    end

    if gui.elements.undercity_tree:push('Undercity settings') then
        render_menu_header('Default flow: walk to the Undercity Obelisk in Temis -> click Open Portal -> walk into portal. Set the Open Portal click point so the bot can dispatch the portal automatically when in Temis with an active Undercity war plan.')
        gui.elements.undercity_auto_enter:render('Auto-enter Undercity',
            'When in Temis with an active Undercity war plan, walk to the Undercity Obelisk + click Open Portal automatically.')
        gui.elements.undercity_cp_open_portal_x:render('Open Portal X',
            'Screen X for the "Open Portal" button on the Undercity Obelisk tribute menu (brown crosshair when Show points is on)')
        gui.elements.undercity_cp_open_portal_y:render('Open Portal Y',
            'Screen Y for the "Open Portal" button')
        gui.elements.undercity_tree:pop()
    end

    if gui.elements.pit_tree:push('Pit settings') then
        render_menu_header('Standalone Pit mode: bot teleports to Cerrigar, walks to the Iron Wolves Pit-key Crafter, opens the configured pit level, walks into the portal, runs the pit, exits when boss-cleared / glyph gizmo appears / timeout.')
        gui.elements.pit_auto_enter:render('Auto-enter Pit',
            'When in Cerrigar in Pit mode, automatically open + enter the configured pit.')
        gui.elements.pit_level:render('Pit level',
            'Pit difficulty level (1..150). Higher = tougher, better rewards.')
        gui.elements.pit_reset_timeout:render('Reset timeout (s)',
            'Force-exit the pit after this many seconds if not yet completed.')
        gui.elements.pit_exit_mode:render('Exit mode', gui.pit_exit_modes,
            'On exit: Reset Dungeons (re-enter same pit) OR Teleport to Cerrigar.')
        gui.elements.pit_interact_shrine:render('Use shrines',
            'Interact with shrines encountered inside the pit.')
        gui.elements.pit_tree:pop()
    end

    if gui.elements.hordes_tree:push('Hordes settings') then
        render_menu_header('Infernal Hordes mode — needs data discovery before it can be wired up. NPC name, compass-apply UI, zone pattern, end-of-run Aether vault all TBD. Drop into Hordes mode and share captures via MCP to populate this section.')
        gui.elements.hordes_tree:pop()
    end

    if gui.elements.warplan_tree:push('War Plan settings') then

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
            gui.elements.warplan_test_confirm_button:render('Test: dismiss confirm dialog',
                'Calls utility.confirm_sigil_notification() once. Click while a confirmation popup is up.', 0)
            gui.elements.warplan_auto_tree:pop()
        end

        if gui.elements.warplan_cp_tree:push('Vendor menu click points') then
            render_menu_header('Open the War Plans vendor window. Toggle "Show points" to see crosshairs, then drag sliders to align them with each activity slot + the START button.')
            gui.elements.warplan_show_points:render('Show points', 'Render crosshairs at each click point')
            gui.elements.warplan_test_button:render('Test selection sequence',
                'Bot must be enabled. Clicks slot 1 -> START, then slot 2 -> START, etc. Stops when quest list grows (plan started).', 0)
            render_menu_header('5×3 grid covering the WAR PLANS menu. Iteration clicks each cell once — redundant hits on the same slot toggle it, but full grid coverage guarantees we hit every visible slot.')
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

            render_menu_header('Confirmation popup — appears after START asking to confirm the war plan. Leave at 0,0 if your war plan doesn\'t show this popup; the step will be skipped.')
            gui.elements.warplan_cp_confirm_x:render('Confirm X', 'Screen X for the Confirm button on the post-START popup (silver crosshair)')
            gui.elements.warplan_cp_confirm_y:render('Confirm Y', 'Screen Y for the Confirm button')

            render_menu_header('Map "Next Warplan Objective" button — opens map (Tab) and clicks the next-objective marker for a one-step teleport.')
            gui.elements.warplan_test_next_obj:render('Test: open map + next objective',
                'Sends Tab, waits, clicks the configured map button. Bot must be enabled.', 0)
            gui.elements.warplan_cp_nextobj_x:render('Next-Obj X', 'Screen X for the Next-Warplan-Objective button on the map')
            gui.elements.warplan_cp_nextobj_y:render('Next-Obj Y', 'Screen Y for the Next-Warplan-Objective button on the map')
            gui.elements.warplan_cp_tree:pop()
        end

        gui.elements.warplan_tree:pop()
    end

    if gui.elements.debug_tree:push('Debug') then
        gui.elements.debug_mode:render('Debug mode', 'Verbose console logging')
        gui.elements.debug_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui
