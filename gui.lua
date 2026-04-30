-- ---------------------------------------------------------------------------
-- WarMachine v0.3 by Magoogle -- unified bot.
--
-- Run modes (selected via the dropdown at the top of the panel):
--   * War Plan  -- autopilot following the WarPlans_QST_* quest line
--   * Nightmare -- standalone NMD farm
--   * Undercity -- standalone Undercity farm
--   * Pit       -- standalone Pit farm
--   * Hordes    -- standalone Infernal Hordes
--   * Helltide  -- standalone Helltide farm
--
-- Each non-WarPlan mode loops its activity directly.  WarPlan reads the
-- live quest and switches activity per phase automatically.
--
-- All activity logic lives in activities/<name>/.  Older external
-- plugins (ArkhamAsylum / WonderCity / HelltideRevamped / SigilRunner /
-- HordeDev) are absorbed -- WarMachine no longer reaches into their
-- globals.
-- ---------------------------------------------------------------------------

local plugin_label   = 'warmachine'
local plugin_version = '0.3'
console.print('Lua Plugin - WarMachine v' .. plugin_version .. ' by Magoogle (unified)')

local mode = require 'core.mode'

local gui = {}

-- ---------------------------------------------------------------------------
-- External dependencies that stay separate from WarMachine.  These are
-- generic libraries the bot uses but doesn't own:
--   * Batmobile     -- navigation library used as fallback when StaticPather
--                      has no map data for the current zone
--   * StaticPather  -- consumes WarMap merged data + the host pathfinder
--   * AlfredTheButler -- inventory/town management (optional)
--   * Looteer       -- loot pickup (optional)
-- Only Batmobile is hard-required (no fallback).  StaticPather is strongly
-- recommended; without it every zone falls back to Batmobile exploration.
-- Alfred + Looteer are nice-to-haves; WarMachine still runs without them.
-- ---------------------------------------------------------------------------
local REQUIRED_PLUGINS = {
    { folder = 'Batmobile', global = 'BatmobilePlugin' },
}
local OPTIONAL_PLUGINS = {
    { folder = 'StaticPather',     global = 'StaticPatherPlugin'     },
    { folder = 'AlfredTheButler',  global = 'AlfredTheButlerPlugin'  },
    { folder = 'Looteer*',         global = 'LooteerPlugin'          },
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

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.elements = {
    main_tree      = tree_node:new(0),
    main_toggle    = cb(false, 'main_toggle'),
    use_keybind    = cb(false, 'use_keybind'),
    keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle')),

    -- Run mode dropdown.  Default index is mode.WARPLAN's slot in the
    -- dropdown_order array (which is 1, since WARPLAN is 2nd entry after IDLE).
    mode_select    = co(mode.to_index(mode.WARPLAN), 'mode_select_v3'),
    -- (debug_mode element is declared once below, around line 173, in its
    -- existing position so the legacy "Debug" tree still wires up.)

    -- ---- Helltide activity settings ----
    helltide_tree                  = tree_node:new(1),
    helltide_do_chests             = cb(true,  'helltide_do_chests'),
    helltide_do_silent_chests      = cb(true,  'helltide_do_silent_chests'),
    helltide_do_ores               = cb(true,  'helltide_do_ores'),
    helltide_do_herbs              = cb(true,  'helltide_do_herbs'),
    helltide_do_shrines            = cb(true,  'helltide_do_shrines'),
    helltide_do_pyres              = cb(true,  'helltide_do_pyres'),
    helltide_do_goblins            = cb(true,  'helltide_do_goblins'),
    helltide_do_events             = cb(true,  'helltide_do_events'),
    helltide_do_chaos_rifts        = cb(true,  'helltide_do_chaos_rifts'),
    helltide_kill_monsters         = cb(true,  'helltide_kill_monsters'),
    helltide_do_maiden             = cb(true,  'helltide_do_maiden'),
    helltide_auto_mount            = cb(true,  'helltide_auto_mount'),
    helltide_kill_range            = si(5, 60, 25, 'helltide_kill_range'),
    helltide_leave_zone_grace      = si(0, 120, 30, 'helltide_leave_zone_grace'),

    -- ---- Pit activity settings (legacy pit_tree/pit_level/pit_auto_enter
    --      are declared further down for the warplan-pit-entry click-points;
    --      this section adds the per-run tuning the new pit module reads.)
    pit_kill_monsters              = cb(true,  'pit_kill_monsters'),
    pit_do_chests                  = cb(true,  'pit_do_chests'),
    pit_do_shrines                 = cb(true,  'pit_do_shrines'),
    pit_exit_after_chest           = cb(true,  'pit_exit_after_chest'),
    pit_kill_range                 = si(5,  60,    25, 'pit_kill_range'),
    pit_boss_intro_delay           = si(0,  30,     3, 'pit_boss_intro_delay'),
    pit_auto_reset_after           = si(120,1800, 600, 'pit_auto_reset_after'),
    -- Glyph upgrade (post-boss gizmo).  Settings parity with ArkhamAsylum.
    pit_glyph_upgrade              = cb(true,  'pit_glyph_upgrade'),
    pit_glyph_upgrade_mode         = co(1,         'pit_glyph_upgrade_mode'),
    pit_glyph_upgrade_threshold    = si(1, 100,   1, 'pit_glyph_upgrade_threshold'),
    pit_glyph_upgrade_legendary    = cb(true,  'pit_glyph_upgrade_legendary'),
    pit_glyph_min_level            = si(1, 100,   1, 'pit_glyph_min_level'),
    pit_glyph_max_level            = si(1, 100, 100, 'pit_glyph_max_level'),

    -- ---- Undercity activity settings ----
    uc_tree                        = tree_node:new(1),
    uc_kill_monsters               = cb(true, 'uc_kill_monsters'),
    uc_do_chests                   = cb(true, 'uc_do_chests'),
    uc_do_enticements              = cb(true, 'uc_do_enticements'),
    uc_exit_after_chest            = cb(true, 'uc_exit_after_chest'),
    uc_speed_run                   = cb(false,'uc_speed_run'),
    uc_kill_range                  = si(5,   60,   25, 'uc_kill_range'),
    uc_boss_intro_delay            = si(0,   30,    3, 'uc_boss_intro_delay'),
    uc_max_hearths                 = si(0,    8,    4, 'uc_max_hearths'),
    uc_enticement_timeout          = si(2,   20,    4, 'uc_enticement_timeout'),
    uc_auto_reset_after            = si(120,1800,  600,'uc_auto_reset_after'),

    -- ---- NMD activity settings ----
    nmd_tree                       = tree_node:new(1),
    nmd_kill_monsters              = cb(true, 'nmd_kill_monsters'),
    nmd_do_chests                  = cb(true, 'nmd_do_chests'),
    nmd_do_shrines                 = cb(true, 'nmd_do_shrines'),
    nmd_do_objectives              = cb(true, 'nmd_do_objectives'),
    nmd_exit_after_boss            = cb(true, 'nmd_exit_after_boss'),
    nmd_kill_range                 = si(5,   60,   25, 'nmd_kill_range'),
    nmd_boss_intro_delay           = si(0,   30,    3, 'nmd_boss_intro_delay'),
    nmd_auto_reset_after           = si(120,1800,  900,'nmd_auto_reset_after'),

    -- ---- Hordes activity settings ----
    hordes_tree                    = tree_node:new(1),
    hordes_kill_monsters           = cb(true, 'hordes_kill_monsters'),
    hordes_do_pylons               = cb(true, 'hordes_do_pylons'),
    hordes_do_aether_structures    = cb(true, 'hordes_do_aether_structures'),
    hordes_do_boss_portals         = cb(true, 'hordes_do_boss_portals'),
    hordes_prefer_bartuc           = cb(false,'hordes_prefer_bartuc'),
    hordes_do_chests               = cb(true, 'hordes_do_chests'),
    hordes_do_chest_ga             = cb(true, 'hordes_do_chest_ga'),
    hordes_do_chest_equipment      = cb(true, 'hordes_do_chest_equipment'),
    hordes_do_chest_materials      = cb(false,'hordes_do_chest_materials'),
    hordes_do_chest_gold           = cb(false,'hordes_do_chest_gold'),
    -- Horde arena is large; 60 covers the full radius so we engage edges, not just center.
    hordes_kill_range              = si(5,   120,   60, 'hordes_kill_range'),
    hordes_pylon_pick_timeout      = si(2,   30,    8, 'hordes_pylon_pick_timeout'),
    hordes_auto_reset_after        = si(120,3000, 1500,'hordes_auto_reset_after'),

    -- War Plan automation toggles
    warplan_auto_tree   = tree_node:new(1),
    warplan_auto_next_obj = cb(true,  'warplan_auto_next_obj'),
    warplan_auto_turn_in  = cb(true,  'warplan_auto_turn_in'),
    warplan_auto_select   = cb(true,  'warplan_auto_select'),
    -- Drives "walk to Warplans_Vendor + open menu" whenever there is no
    -- active war plan and we're in Temis. This covers BOTH the fresh-enable
    -- case (start the very first cycle) AND post-turn-in looping. Default
    -- ON so enabling WarMachine just works. Turn off if you want to start
    -- the cycle yourself.
    -- Hash key bumped to _v2 so existing installs pick up the new default
    -- (the original key shipped with default OFF, which left users staring
    -- at WarMachine doing nothing on enable).
    warplan_auto_cycle    = cb(true,  'warplan_auto_cycle_v2'),

    -- War Plan vendor menu click points
    warplan_cp_tree     = tree_node:new(1),
    warplan_show_points = cb(false, 'warplan_show_points'),

    -- 5 rows x 3 cols = 15 slot click-points covering the WAR PLANS menu.
    -- The three slots in each row sit at the same Y in-game (row of cards
    -- in the menu), so we only expose ONE Y slider per row -- 15 X +
    -- 5 row-Y = 20 sliders instead of 30.  Cuts setup time roughly in
    -- half.  Row Y defaults match the original per-slot defaults.
    warplan_cp_row1_y = si(0, 2160, 360, 'warplan_cp_row1_y'),
    warplan_cp_row2_y = si(0, 2160, 510, 'warplan_cp_row2_y'),
    warplan_cp_row3_y = si(0, 2160, 660, 'warplan_cp_row3_y'),
    warplan_cp_row4_y = si(0, 2160, 810, 'warplan_cp_row4_y'),
    warplan_cp_row5_y = si(0, 2160, 960, 'warplan_cp_row5_y'),

    -- Per-slot X (unchanged -- columns can drift independently)
    warplan_cp_s1_x  = si(0, 3840, 320, 'warplan_cp_s1_x'),
    warplan_cp_s2_x  = si(0, 3840, 470, 'warplan_cp_s2_x'),
    warplan_cp_s3_x  = si(0, 3840, 620, 'warplan_cp_s3_x'),
    warplan_cp_s4_x  = si(0, 3840, 320, 'warplan_cp_s4_x'),
    warplan_cp_s5_x  = si(0, 3840, 470, 'warplan_cp_s5_x'),
    warplan_cp_s6_x  = si(0, 3840, 620, 'warplan_cp_s6_x'),
    warplan_cp_s7_x  = si(0, 3840, 320, 'warplan_cp_s7_x'),
    warplan_cp_s8_x  = si(0, 3840, 470, 'warplan_cp_s8_x'),
    warplan_cp_s9_x  = si(0, 3840, 620, 'warplan_cp_s9_x'),
    warplan_cp_s10_x = si(0, 3840, 320, 'warplan_cp_s10_x'),
    warplan_cp_s11_x = si(0, 3840, 470, 'warplan_cp_s11_x'),
    warplan_cp_s12_x = si(0, 3840, 620, 'warplan_cp_s12_x'),
    warplan_cp_s13_x = si(0, 3840, 320, 'warplan_cp_s13_x'),
    warplan_cp_s14_x = si(0, 3840, 470, 'warplan_cp_s14_x'),
    warplan_cp_s15_x = si(0, 3840, 620, 'warplan_cp_s15_x'),

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

    -- Pit entry settings. ArkhamAsylum standalone uses the legacy Cerrigar
    -- Pit Crafter; WarMachine drives the new Skov_Temis Pit Obelisk path
    -- (utility.open_pit_portal at the configured level) when a Pit war
    -- plan is active.
    pit_tree         = tree_node:new(1),
    pit_auto_enter   = cb(true, 'pit_auto_enter'),
    pit_level        = si(1, 150, 1, 'pit_level'),

    -- Debug
    debug_tree = tree_node:new(2),
    debug_mode = cb(false, 'debug_mode'),
}

gui.render = function ()
    if not gui.elements.main_tree:push('WarMachine v' .. plugin_version .. ' by Magoogle') then return end

    -- Dependency check banner. Block of red-text headers naming each
    -- missing sub-plugin folder. The master toggle is force-disabled in
    -- WarMachine is now self-contained for the activities; only Batmobile
    -- is hard-required (used as fallback navigator for zones with no merged
    -- WarMap data).  Show a soft warning for missing optional integrations
    -- (StaticPather/Alfred/Looteer) but don't block the master toggle.
    local missing = get_missing_dependencies()
    if #missing > 0 then
        render_menu_header('==========================================================')
        render_menu_header('  MISSING REQUIRED PLUGIN -- WarMachine cannot run without:')
        for _, folder in ipairs(missing) do
            render_menu_header('    * ' .. folder)
        end
        render_menu_header('  Install Batmobile in scripts/ then re-enable WarMachine.')
        render_menu_header('==========================================================')
    end
    -- Soft warnings for optional integrations
    local missing_optional = {}
    for _, dep in ipairs(OPTIONAL_PLUGINS) do
        if _G[dep.global] == nil then
            missing_optional[#missing_optional + 1] = dep.folder
        end
    end
    if #missing_optional > 0 then
        render_menu_header('Optional integrations not loaded: ' .. table.concat(missing_optional, ', '))
    end

    gui.elements.main_toggle:render('Enable', 'Master enable for WarMachine')
    gui.elements.use_keybind:render('Use keybind', 'Keybind to quick-toggle the bot')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind_toggle:render('Toggle Keybind', 'Toggle the bot on/off')
    end
    -- (debug toggle is rendered in the bottom Debug tree to match the
    -- legacy GUI layout; not duplicated here)

    -- Run-mode dropdown.  Drives core/activity_manager which picks the
    -- correct activities/<name>/ module each pulse.
    gui.elements.mode_select:render(
        'Run mode',
        mode.dropdown_labels,
        'Pick what WarMachine should do.  War Plan = autopilot following the ' ..
        'WarPlans_QST_* quest.  The other entries are standalone "just farm this ' ..
        'activity in a loop" modes.')

    -- Per-mode hint text under the dropdown
    local current_mode_value = mode.from_index(gui.elements.mode_select:get())
    if current_mode_value == mode.IDLE then
        render_menu_header('Mode = Idle. Bot does nothing -- pick a mode above.')
    elseif current_mode_value == mode.WARPLAN then
        render_menu_header('Mode = War Plan. Bot accepts a War Plan, cycles through its activities, and turns in.')
    else
        render_menu_header(string.format(
            'Mode = %s (standalone). Bot loops this activity until you disable it.',
            mode.label(current_mode_value)))
    end

    if gui.elements.helltide_tree:push('Helltide settings') then
        render_menu_header('What to do during a helltide hour. POI selection drives off StaticPather merged WarMap data + falls back to Batmobile freeroam when none is available.')
        gui.elements.helltide_do_chests:render('Open Tortured Gifts + Helltide chests',
            'Spend cinders on rare chests; open free helltide reward chests')
        gui.elements.helltide_do_silent_chests:render('Open Silent chests',
            'Use whispering keys when present')
        gui.elements.helltide_do_ores:render('Mine ore', 'Helltide-themed ore nodes')
        gui.elements.helltide_do_herbs:render('Pick herbs', 'Helltide-themed herb nodes')
        gui.elements.helltide_do_shrines:render('Use shrines', 'Light/heavy shrines (buffs)')
        gui.elements.helltide_do_pyres:render('Light pyres (Maiden hearts)',
            'Required for the Maiden of Anguish event')
        gui.elements.helltide_do_goblins:render('Chase goblins', 'Treasure goblins drop bonus loot')
        gui.elements.helltide_do_events:render('Do events',
            'Random world events (flame pillars, ravenous souls)')
        gui.elements.helltide_do_chaos_rifts:render('Do Chaos Rifts',
            'Channeled portal events')
        gui.elements.helltide_do_maiden:render('Do Maiden of Anguish event',
            'Engage the brazier + boss when a maiden event is up')
        gui.elements.helltide_kill_monsters:render('Kill monsters between objectives',
            'Fallback combat when no POI is in range')
        gui.elements.helltide_kill_range:render('Combat search range (y)',
            'Furthest distance kill_monster considers hostiles')
        gui.elements.helltide_leave_zone_grace:render('Leave-zone grace (s)',
            'Tolerate brief buff drops before declaring "wandered out"')
        gui.elements.helltide_auto_mount:render('Auto mount (Z)',
            'Auto-press Z to mount when traveling between events; auto-dismount when an enemy is close. Big speed boost.')
        gui.elements.helltide_tree:pop()
    end

    if gui.elements.warplan_auto_tree:push('Automation') then
        render_menu_header('Toggles control which steps WarMachine drives automatically. With everything off, mode is observe-only.')
        gui.elements.warplan_auto_next_obj:render('Auto next-objective teleport',
            'Press Tab + click Next-Obj button when player is in the wrong zone for the active war plan.')
        gui.elements.warplan_auto_turn_in:render('Auto turn-in at Tyrael',
            'Walk to Tyrael and interact when WarPlans_QST_TurnIn_Rewards is active.')
        gui.elements.warplan_auto_select:render('Auto select activities',
            'Run the click sequence when the WAR PLANS menu is open and no war plan is active.')
        gui.elements.warplan_auto_cycle:render('Auto-start war plan',
            'When no war plan is active and you are in Temis, walk to Warplans_Vendor ' ..
            'and open the menu. Covers the first start (fresh WarMachine enable) and ' ..
            'post-turn-in looping. Turn off for manual cycle control.')
        gui.elements.warplan_auto_tree:pop()
    end

    if gui.elements.warplan_cp_tree:push('Vendor menu click points') then
        render_menu_header('Open the War Plans vendor window. Toggle "Show points" to see crosshairs, then drag sliders to align them with each activity slot, START, Confirm popup, and the map Next-Obj button.')
        gui.elements.warplan_show_points:render('Show points', 'Render crosshairs at each click point')

        render_menu_header('5x3 grid covering the WAR PLANS menu. Three slots in each row share a single Y slider -- in-game the cards in a row sit at the same screen height, so independent Y per slot was just busywork. Drag each row Y once, then nudge each L/M/R X.')
        local function row(prefix, color_label, ey, e1x, e2x, e3x)
            ey :render(prefix .. ' Y',   'Screen Y for the entire ' .. prefix .. ' (' .. color_label .. ')')
            e1x:render(prefix .. ' L X', 'Screen X for ' .. prefix .. ' left')
            e2x:render(prefix .. ' M X', 'Screen X for ' .. prefix .. ' middle')
            e3x:render(prefix .. ' R X', 'Screen X for ' .. prefix .. ' right')
        end
        row('Row 1', 'red',
            gui.elements.warplan_cp_row1_y,
            gui.elements.warplan_cp_s1_x, gui.elements.warplan_cp_s2_x, gui.elements.warplan_cp_s3_x)
        row('Row 2', 'green',
            gui.elements.warplan_cp_row2_y,
            gui.elements.warplan_cp_s4_x, gui.elements.warplan_cp_s5_x, gui.elements.warplan_cp_s6_x)
        row('Row 3', 'yellow',
            gui.elements.warplan_cp_row3_y,
            gui.elements.warplan_cp_s7_x, gui.elements.warplan_cp_s8_x, gui.elements.warplan_cp_s9_x)
        row('Row 4', 'cyan',
            gui.elements.warplan_cp_row4_y,
            gui.elements.warplan_cp_s10_x, gui.elements.warplan_cp_s11_x, gui.elements.warplan_cp_s12_x)
        row('Row 5', 'orange',
            gui.elements.warplan_cp_row5_y,
            gui.elements.warplan_cp_s13_x, gui.elements.warplan_cp_s14_x, gui.elements.warplan_cp_s15_x)
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

    if gui.elements.pit_tree:push('Pit settings') then
        render_menu_header('Settings used by both standalone Pit mode and WarPlan-pit drives. ' ..
            'Entry is from the Iron Wolves Pit-key Crafter in Skov_Temis using the level set here.')
        gui.elements.pit_auto_enter:render('Auto-enter Pit',
            'Walk to the Pit Obelisk + open the configured level + enter portal automatically.')
        gui.elements.pit_level:render('Pit Level',
            'Pit tier to open. Match this to your character\'s farming tier.')

        render_menu_header('Combat')
        gui.elements.pit_kill_monsters:render('Kill monsters', 'Reactive combat between objectives')
        gui.elements.pit_kill_range:render('Combat search range (y)', 'How far kill_monster will engage hostiles')
        gui.elements.pit_boss_intro_delay:render('Boss intro delay (s)', 'Hold attacks this long after a boss appears')

        render_menu_header('In-pit objectives')
        gui.elements.pit_do_chests:render('Loot chests', 'Side-corridor chests + end-of-run reward')
        gui.elements.pit_do_shrines:render('Use shrines', 'Buff shrines on the way')

        render_menu_header('Glyph upgrade (post-boss)')
        gui.elements.pit_glyph_upgrade:render('Enable glyph upgrade',
            'Interact with the Paragon Glyph Upgrade gizmo at the end of the final floor and iterate the upgrade UI.')
        if gui.elements.pit_glyph_upgrade:get() then
            gui.elements.pit_glyph_upgrade_mode:render('Upgrade mode',
                { 'Highest to lowest', 'Lowest to highest' },
                'Order to iterate glyphs.  Highest-to-lowest matches ArkhamAsylum default.')
            gui.elements.pit_glyph_upgrade_threshold:render('Min upgrade chance %',
                'Only attempt an upgrade if its success chance is >= this percent.')
            gui.elements.pit_glyph_min_level:render('Minimum glyph level',
                'Skip glyphs below this level.')
            gui.elements.pit_glyph_max_level:render('Maximum glyph level',
                'Skip glyphs above this level.')
            gui.elements.pit_glyph_upgrade_legendary:render('Upgrade to legendary',
                'Allow level-45 -> legendary upgrades.  Disable to save gem fragments.')
        end

        render_menu_header('Run lifecycle')
        gui.elements.pit_exit_after_chest:render('Exit after chest', 'Warp out as soon as the attunement chest is looted')
        gui.elements.pit_auto_reset_after:render('Auto-reset after (s)', 'Safety net: reset_all_dungeons if the run drags this long')

        gui.elements.pit_tree:pop()
    end

    if gui.elements.uc_tree:push('Undercity settings') then
        render_menu_header('Combat')
        gui.elements.uc_kill_monsters:render('Kill monsters', 'Reactive combat between objectives')
        gui.elements.uc_kill_range:render('Combat search range (y)', 'How far kill_monster engages')
        gui.elements.uc_boss_intro_delay:render('Boss intro delay (s)', 'Hold attacks after boss appears')
        render_menu_header('In-undercity objectives')
        gui.elements.uc_do_chests:render('Loot chests', 'Side chests + attunement chest')
        gui.elements.uc_do_enticements:render('Use enticements', 'Spirit beacons + hearths (mid-run elite triggers)')
        gui.elements.uc_max_hearths:render('Max SpiritHearth interactions', 'Cap on hearths per run (beacons unlimited)')
        gui.elements.uc_enticement_timeout:render('Enticement timeout (s)', 'How long to wait at each beacon/hearth')
        render_menu_header('Run lifecycle')
        gui.elements.uc_exit_after_chest:render('Exit after chest', 'Warp out / reset after the attunement chest is looted')
        gui.elements.uc_speed_run:render('Speed run',
            'Once attunement orbs hit max (4/4 by default), skip enticements / shrines / mid-floor chests and beeline floor switches + boss room.  Mid-run rewards are wasted at 4/4 anyway.')
        gui.elements.uc_auto_reset_after:render('Auto-reset after (s)', 'Safety net')
        gui.elements.uc_tree:pop()
    end

    if gui.elements.nmd_tree:push('Nightmare Dungeon settings') then
        render_menu_header('Combat')
        gui.elements.nmd_kill_monsters:render('Kill monsters', 'Reactive combat')
        gui.elements.nmd_kill_range:render('Combat search range (y)', 'How far kill_monster engages')
        gui.elements.nmd_boss_intro_delay:render('Boss intro delay (s)', 'Hold attacks after boss appears')
        render_menu_header('In-dungeon objectives')
        gui.elements.nmd_do_objectives:render('Do objectives', 'Pedestals, levers, doors gating progression')
        gui.elements.nmd_do_chests:render('Loot chests', 'Side-corridor + reward chests')
        gui.elements.nmd_do_shrines:render('Use shrines', 'Buff shrines on the way')
        render_menu_header('Run lifecycle')
        gui.elements.nmd_exit_after_boss:render('Exit after boss', 'reset_all_dungeons after the boss kill')
        gui.elements.nmd_auto_reset_after:render('Auto-reset after (s)', 'Safety net')
        gui.elements.nmd_tree:pop()
    end

    if gui.elements.hordes_tree:push('Hordes settings') then
        render_menu_header('Combat')
        gui.elements.hordes_kill_monsters:render('Kill monsters', 'Reactive combat (aether masses prioritized)')
        gui.elements.hordes_kill_range:render('Combat search range (y)', 'Engagement radius')
        render_menu_header('Pylons + aether')
        gui.elements.hordes_do_pylons:render('Pick pylons (boons)',
            'Auto-pick the highest-priority pylon between waves. ' ..
            'Priority list is in activities/hordes/data/pylon_priority.lua.')
        gui.elements.hordes_pylon_pick_timeout:render('Pylon pick timeout (s)',
            'If no preferred pylon detected within this time, take the first available')
        gui.elements.hordes_do_aether_structures:render('Engage aether structures',
            'BSK_Structure_BonusAether spawns -- walking up grants bonus aether')
        render_menu_header('End-of-run')
        gui.elements.hordes_do_boss_portals:render('Click boss portal',
            'After waves clear, walk to and click the Bartuc/Council pylon to enter the boss arena.')
        gui.elements.hordes_prefer_bartuc:render('Prefer Bartuc',
            'When both portals are visible, click Bartuc instead of Council. Falls back to Council if Bartuc fails to interact within 6s.')
        gui.elements.hordes_do_chests:render('Open reward chests',
            'Master toggle.  Off -> skip the chest phase entirely.')
        gui.elements.hordes_do_chest_ga:render('  GA chest',
            'Greater-Affix chest.  Highest priority -- bot tries this one first.')
        gui.elements.hordes_do_chest_equipment:render('  Equipment chest',
            'Random gear pieces.  Second priority.')
        gui.elements.hordes_do_chest_materials:render('  Materials chest',
            'Crafting materials.  Third priority.  Off by default.')
        gui.elements.hordes_do_chest_gold:render('  Gold chest',
            'Pile of gold.  Lowest priority.  Off by default.')
        render_menu_header('Run lifecycle')
        gui.elements.hordes_auto_reset_after:render('Auto-reset after (s)', 'Safety net')
        gui.elements.hordes_tree:pop()
    end

    if gui.elements.debug_tree:push('Debug') then
        gui.elements.debug_mode:render('Debug mode', 'Verbose console logging')
        gui.elements.debug_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui
