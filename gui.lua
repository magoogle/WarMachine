-- ---------------------------------------------------------------------------
-- WarMachine v0.4 by Magoogle -- unified bot.
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
local plugin_version = '0.4'
console.print('Lua Plugin - WarMachine v' .. plugin_version .. ' by Magoogle (unified)')

local mode = require 'core.mode'
-- Nav GUI is rendered as a sub-tree inside our main_tree below.  Lazy
-- in case nav isn't loaded for some reason -- gui.render() then renders
-- without the Navigation section.
local _nav_gui_lazy = nil
local function nav_gui()
    if _nav_gui_lazy ~= nil then return _nav_gui_lazy end
    local ok, mod = pcall(require, 'core.nav.gui')
    _nav_gui_lazy = (ok and mod) or false
    return _nav_gui_lazy
end

local gui = {}

-- ---------------------------------------------------------------------------
-- External dependencies that stay separate from WarMachine.  Pathfinding
-- and exploration are now built in (core/nav/), so there are no hard
-- required externals.  These are optional:
--   * WarPath       -- catalog reads only (POI lookup, vendor positions,
--                     overworld helltide data).  Optional -- absent
--                     installations fall back to live actor stream.
--   * AlfredTheButler -- inventory/town management (optional)
--   * Looteer         -- loot pickup (optional)
-- ---------------------------------------------------------------------------
-- Navigation is now built into WarMachine (core/nav/), so there are no
-- hard required external plugins.  Kept as an empty list so the existing
-- dependency-render loop still iterates safely; add entries here later
-- if WarMachine grows new hard dependencies.
local REQUIRED_PLUGINS = {}
local OPTIONAL_PLUGINS = {
    { folder = 'WarPath',          global = 'WarPathPlugin',
      alt_folder = 'StaticPather', alt_global = 'StaticPatherPlugin' },
    { folder = 'AlfredTheButler',  global = 'AlfredTheButlerPlugin'  },
    { folder = 'Looteer*',         global = 'LooteerPlugin'          },
}

local function get_missing_dependencies()
    local missing = {}
    for _, dep in ipairs(REQUIRED_PLUGINS) do
        if _G[dep.global] == nil and _G[dep.alt_global or ''] == nil then
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
    nmd_do_cursed_shrines          = cb(true, 'nmd_do_cursed_shrines'),
    nmd_do_events                  = cb(true, 'nmd_do_events'),
    nmd_ignore_trigger_events      = cb(false,'nmd_ignore_trigger_events'),
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
    -- Secondary chest dropdown: 0=None, 1=Materials, 2=Gold.  Materials
    -- and Gold are mutually exclusive (you only have aether for one
    -- after the GA chest), so a dropdown enforces the constraint.
    hordes_chest_secondary         = co(0,    'hordes_chest_secondary'),
    -- Horde arena is one big open room; 100 covers the full corner-to-
    -- corner diagonal so spires/masses/events on the far side are seen.
    hordes_kill_range              = si(5,   150,  100, 'hordes_kill_range'),
    hordes_pylon_pick_timeout      = si(2,   30,    8, 'hordes_pylon_pick_timeout'),
    hordes_auto_reset_after        = si(120,3000, 1500,'hordes_auto_reset_after'),

    -- ---- Boss-altar activity settings ----
    boss_tree                      = tree_node:new(1),
    boss_kill_monsters             = cb(true, 'boss_kill_monsters'),
    boss_do_chests                 = cb(true, 'boss_do_chests'),
    boss_kill_range                = si(5,   60,   25, 'boss_kill_range'),
    boss_room_tether               = si(5,   30,   15, 'boss_room_tether'),
    boss_altar_stuck_secs          = si(15, 120,   60, 'boss_altar_stuck_secs'),
    boss_chest_grace_secs          = si(0,  60,   15, 'boss_chest_grace_secs'),
    boss_auto_reset_after          = si(60,1800,  600,'boss_auto_reset_after'),
    boss_dungeon_reset_enabled     = cb(false, 'boss_dungeon_reset_enabled'),
    boss_dungeon_reset_interval    = si(1, 200, 25, 'boss_dungeon_reset_interval'),
    -- Boss selection (standalone mode only -- WarPlan picks for us).
    boss_selection_mode            = co(0,        'boss_selection_mode'),  -- Specific / Random / Split
    boss_primary                   = co(0,        'boss_primary'),         -- index into boss list
    boss_secondary                 = co(1,        'boss_secondary'),
    boss_enable_andariel           = cb(true,  'boss_enable_andariel'),
    boss_enable_duriel             = cb(true,  'boss_enable_duriel'),
    boss_enable_varshan            = cb(true,  'boss_enable_varshan'),
    boss_enable_grigoire           = cb(true,  'boss_enable_grigoire'),
    boss_enable_zir                = cb(true,  'boss_enable_zir'),
    boss_enable_beast              = cb(true,  'boss_enable_beast'),
    boss_enable_harbinger          = cb(false, 'boss_enable_harbinger'),
    boss_enable_urivar             = cb(false, 'boss_enable_urivar'),
    boss_enable_belial             = cb(false, 'boss_enable_belial'),
    boss_enable_butcher            = cb(false, 'boss_enable_butcher'),

    -- War Plan automation toggles
    warplan_auto_tree   = tree_node:new(1),
    warplan_auto_next_obj = cb(true,  'warplan_auto_next_obj'),
    warplan_auto_turn_in  = cb(true,  'warplan_auto_turn_in'),
    warplan_auto_select   = cb(true,  'warplan_auto_select'),
    -- Activity filter: when OFF, the auto-selector skips any node whose
    -- node_name() / node_reward_name() matches Nightmare Dungeon, picking
    -- a different legal option instead.  Default OFF so NMDs are ignored
    -- right now; flip ON later once NMDs are stable to opt back in.
    warplan_allow_nightmare = cb(false, 'warplan_allow_nightmare_v1'),
    -- Drives "walk to Warplans_Vendor + open menu" whenever there is no
    -- active war plan and we're in Temis. This covers BOTH the fresh-enable
    -- case (start the very first cycle) AND post-turn-in looping. Default
    -- ON so enabling WarMachine just works. Turn off if you want to start
    -- the cycle yourself.
    -- Hash key bumped to _v2 so existing installs pick up the new default
    -- (the original key shipped with default OFF, which left users staring
    -- at WarMachine doing nothing on enable).
    warplan_auto_cycle    = cb(true,  'warplan_auto_cycle_v2'),
    -- Whispers turn-in piggyback.  Opt-in: walks to the Tree of Whispers
    -- and claims the first reward when (a) we're in a recognized town,
    -- (b) at least one bounty quest is turn-in-ready, (c) the Tree NPC
    -- is in the live actor stream.  Default OFF until live-validated.
    warplan_whisper_turn_in = cb(false, 'warplan_whisper_turn_in'),
    -- Whispers reward UI is mouse-only (no API to pick a cache).  Two
    -- click points expressed as %-of-screen so the same numbers work
    -- across resolutions.  Reward = first cache (left of three);
    -- Accept = the confirm button below the cards.  show_whisper_points
    -- draws crosshairs at the configured spots so the user can dial
    -- them in without consuming a turn-in.
    warplan_whisper_reward_x_pct = si(0, 100, 40, 'warplan_whisper_reward_x_pct'),
    warplan_whisper_reward_y_pct = si(0, 100, 55, 'warplan_whisper_reward_y_pct'),
    warplan_whisper_accept_x_pct = si(0, 100, 50, 'warplan_whisper_accept_x_pct'),
    warplan_whisper_accept_y_pct = si(0, 100, 85, 'warplan_whisper_accept_y_pct'),
    warplan_show_whisper_points  = cb(false, 'warplan_show_whisper_points'),

    -- "New Plan" reroll click points -- used by the warplan picker when
    -- DFS finds no Nightmare-free path through the current tree (every
    -- 5-pick path passes through an NMD node).  Two clicks: the panel
    -- "New Plan" button, then the confirm dialog that follows.  Both
    -- expressed as %-of-screen so the same numbers work across
    -- resolutions; defaults are 0/0 (off) -- the user dials them in
    -- with the show-overlay toggle, the picker skips reroll entirely
    -- if either coord is 0.
    warplan_new_plan_x_pct          = si(0, 100, 0, 'warplan_new_plan_x_pct'),
    warplan_new_plan_y_pct          = si(0, 100, 0, 'warplan_new_plan_y_pct'),
    warplan_new_plan_confirm_x_pct  = si(0, 100, 0, 'warplan_new_plan_confirm_x_pct'),
    warplan_new_plan_confirm_y_pct  = si(0, 100, 0, 'warplan_new_plan_confirm_y_pct'),
    warplan_show_new_plan_points    = cb(false,    'warplan_show_new_plan_points'),
    -- Cap on how many reroll attempts the picker will burn before
    -- giving up.  Avoids spinning gold/resource forever if the user's
    -- settings or the live UI block the click flow.
    warplan_max_rerolls             = si(0, 10, 5, 'warplan_max_rerolls'),

    -- (Vendor-menu picker click points removed: tasks/warplan/test_select.lua
    --  now drives the WAR PLANS menu via the host's `warplan` API
    --  (warplan.is_ready / get_selectable_now / select_node / confirm).
    --  No more 25 slot sliders or START/CONFIRM coords -- the API sends
    --  the confirm packet directly.  warplan_show_points / warplan_cp_s*
    --  GUI elements are gone; their saved hashes will just be inert keys
    --  in the user's settings store.)

    -- Tree wrapper for the remaining pixel-click points (Next-Obj on the
    -- map + Undercity Open Portal in the tribute UI).
    warplan_cp_tree     = tree_node:new(1),

    -- Map "Next Warplan Objective" button.  Still pixel-clicked because
    -- the host doesn't expose the map's Next-Obj button via API.
    warplan_cp_nextobj_x  = si(0, 3840, 960, 'warplan_cp_nextobj_x'),
    warplan_cp_nextobj_y  = si(0, 2160, 960, 'warplan_cp_nextobj_y'),

    -- Undercity entry click point (Undercity Obelisk tribute UI -> Open Portal)
    undercity_auto_enter         = cb(true, 'undercity_auto_enter'),
    undercity_cp_open_portal_x   = si(0, 3840, 0, 'undercity_cp_open_portal_x'),
    undercity_cp_open_portal_y   = si(0, 2160, 0, 'undercity_cp_open_portal_y'),
    undercity_show_click_points  = cb(false,    'undercity_show_click_points'),

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
    -- One-shot dump of the live WAR PLANS panel state to console.  Use
    -- when the auto-picker chose something unexpected -- prints every
    -- node's id / name / reward / selectable state / neighbors so we
    -- can see exactly what get_selectable_now() returned and why the
    -- Nightmare filter did or didn't match.  Player must be at the
    -- vendor with the panel open for the API to return data.
    debug_dump_warplan_button = btn('debug_dump_warplan'),
}

gui.render = function ()
    if not gui.elements.main_tree:push('WarMachine v' .. plugin_version .. ' by Magoogle') then return end

    -- Dependency check banner: REQUIRED_PLUGINS is empty now that nav is
    -- built in.  The block is preserved so adding a future hard dependency
    -- is a one-line entry-list edit.
    local missing = get_missing_dependencies()
    if #missing > 0 then
        render_menu_header('==========================================================')
        render_menu_header('  MISSING REQUIRED PLUGIN -- WarMachine cannot run without:')
        for _, folder in ipairs(missing) do
            render_menu_header('    * ' .. folder)
        end
        render_menu_header('  Install the listed plugin(s) and re-enable WarMachine.')
        render_menu_header('==========================================================')
    end
    -- Soft warnings for optional integrations.  WarPath / StaticPather
    -- transition: accept either folder + either global so users on
    -- whichever side of the rename don't get a spurious "missing
    -- integration" warning.
    local missing_optional = {}
    for _, dep in ipairs(OPTIONAL_PLUGINS) do
        local present = _G[dep.global] ~= nil
        if not present and dep.alt_global then
            present = _G[dep.alt_global] ~= nil
        end
        if not present then
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

    -- Per-mode hint text under the dropdown.  IDLE is no longer in the
    -- dropdown so we don't render an Idle hint -- if a stale settings
    -- file still carries mode==IDLE, fall through to the generic hint.
    local current_mode_value = mode.from_index(gui.elements.mode_select:get())
    if current_mode_value == mode.WARPLAN then
        render_menu_header('Mode = War Plan. Bot accepts a War Plan, cycles through its activities, and turns in.')
    else
        render_menu_header(string.format(
            'Mode = %s (standalone). Bot loops this activity until you disable it.',
            mode.label(current_mode_value)))
    end

    if gui.elements.helltide_tree:push('Helltide settings') then
        render_menu_header('What to do during a helltide hour. POI selection drives off WarPath merged WarMap data; the explore task wanders the zone when no POI is queued.')
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
            'Drive the WAR PLANS menu picker (via the warplan API) when the menu is open and no war plan is active.')
        gui.elements.warplan_allow_nightmare:render('Allow Nightmare Dungeon plans',
            'When OFF (default), auto-select skips Nightmare Dungeon nodes and picks a different legal option instead.  Turn ON to opt back in once NMDs are stable for you.')
        gui.elements.warplan_whisper_turn_in:render('Auto turn in Whispers',
            'When in town, walk to Tree/Raven and claim first reward ' ..
            'if any bounty is ready.  Piggyback only -- never teleports to ' ..
            'the Tree on its own.  Click points below MUST be tuned to ' ..
            'your resolution; enable "show whisper click points" to see them.')
        gui.elements.warplan_whisper_reward_x_pct:render('Whisper reward click X%',
            'X position of the first cache card as a percent of screen width.')
        gui.elements.warplan_whisper_reward_y_pct:render('Whisper reward click Y%',
            'Y position of the first cache card as a percent of screen height.')
        gui.elements.warplan_whisper_accept_x_pct:render('Whisper accept click X%',
            'X position of the Accept button as a percent of screen width.')
        gui.elements.warplan_whisper_accept_y_pct:render('Whisper accept click Y%',
            'Y position of the Accept button as a percent of screen height.')
        gui.elements.warplan_show_whisper_points:render('Show whisper click points',
            'Draw crosshairs at the configured Reward + Accept click points ' ..
            'so you can verify they line up with the in-game UI.')

        render_menu_header('"New Plan" reroll click points (used when every legal path runs through Nightmare Dungeons). Coords are %-of-screen so the same numbers work across resolutions; defaults are 0/0 -- the picker skips reroll entirely until both pairs are dialed in.')
        gui.elements.warplan_max_rerolls:render('Max rerolls',
            'Cap on how many "New Plan" attempts the picker burns before ' ..
            'giving up.  0 disables the reroll path entirely (picker just ' ..
            'aborts when the tree is NMD-locked).')
        gui.elements.warplan_new_plan_x_pct:render('New Plan button X%',
            'X position of the "New Plan" button on the WAR PLANS panel as a percent of screen width.')
        gui.elements.warplan_new_plan_y_pct:render('New Plan button Y%',
            'Y position of the "New Plan" button.')
        gui.elements.warplan_new_plan_confirm_x_pct:render('New Plan confirm X%',
            'X position of the dialog confirm button (the "yes, generate a fresh tree" prompt that pops after clicking New Plan).')
        gui.elements.warplan_new_plan_confirm_y_pct:render('New Plan confirm Y%',
            'Y position of the New Plan confirm button.')
        gui.elements.warplan_show_new_plan_points:render('Show New Plan click points',
            'Draw crosshairs at the configured New Plan + confirm click ' ..
            'points so you can verify them against the live UI.')

        gui.elements.warplan_auto_cycle:render('Auto-start war plan',
            'When no war plan is active and you are in Temis, walk to Warplans_Vendor ' ..
            'and open the menu. Covers the first start (fresh WarMachine enable) and ' ..
            'post-turn-in looping. Turn off for manual cycle control.')
        gui.elements.warplan_auto_tree:pop()
    end

    if gui.elements.warplan_cp_tree:push('Map / UI click points') then
        render_menu_header('A few in-game UI elements still require pixel clicks because the host doesn\'t expose them via API. The vendor menu (slot picker / START / Confirm) was migrated to the warplan API and no longer needs coords.')

        render_menu_header('Map "Next Warplan Objective" button. Opens map (Tab) and clicks the next-objective marker for a one-step teleport between activities.')
        gui.elements.warplan_cp_nextobj_x:render('Next-Obj X', 'Screen X for the Next-Warplan-Objective button on the map')
        gui.elements.warplan_cp_nextobj_y:render('Next-Obj Y', 'Screen Y for the Next-Warplan-Objective button')

        render_menu_header('Undercity Obelisk Open Portal button -- appears in the tribute UI after interacting with the Undercity Obelisk in Temis.')
        gui.elements.undercity_auto_enter:render('Auto-enter Undercity',
            'When in Temis with an active Undercity war plan, walk to the Undercity Obelisk + click Open Portal automatically.')
        gui.elements.undercity_cp_open_portal_x:render('Open Portal X',
            'Screen X for the "Open Portal" button on the Undercity Obelisk tribute menu')
        gui.elements.undercity_cp_open_portal_y:render('Open Portal Y',
            'Screen Y for the "Open Portal" button')
        gui.elements.undercity_show_click_points:render('Show Undercity click points',
            'Draw a crosshair at the configured Open Portal pixel coords ' ..
            'so you can verify it lines up with the in-game button.  ' ..
            'Open the Undercity Obelisk tribute menu manually first; ' ..
            'the overlay is screen-position-only, no auto-click.')

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
        gui.elements.nmd_do_cursed_shrines:render('Do cursed shrines',
            'Click cursed shrines to start the mob-wave sub-event ' ..
            '(reward: CursedEventChest).  When off, the bot walks past ' ..
            'cursed shrines without activating them.')
        gui.elements.nmd_do_events:render('Do events',
            'Engage local events: LE_Ambush (speak to survivor, survive ' ..
            'waves), DE_* / DSQ_* (walk into trigger zone, kill mobs).  ' ..
            'When off, the bot ignores event triggers and walks past ' ..
            'them.  kill_monster still engages any mobs that aggro.')
        gui.elements.nmd_ignore_trigger_events:render('Ignore trigger events',
            'Skip the anchor-hold survive phase for ambush-style events ' ..
            'spawned by shrines, healing wells, and other random triggers. ' ..
            'kill_monster still engages whatever aggros, but the bot ' ..
            'keeps walking the route instead of pinning to the trigger ' ..
            'point.  Leaves "Do events" alone for events that need an ' ..
            'NPC click or interactable to progress (those still fire).')
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
            'Edit activities/hordes/data/pylon_priority.lua to reorder ' ..
            '(top = strongest preference) or to blacklist boons you ' ..
            'never want picked.  Reloads on Lua reload, no plugin restart.')
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
            'Greater-Affix chest.  Top priority -- bot tries it first ' ..
            'with retry-until-success.  If aether runs out the chest ' ..
            'is marked failed and we fall through to the secondary.')
        local CHEST_SECONDARY_OPTS = { 'None', 'Materials', 'Gold' }
        gui.elements.hordes_chest_secondary:render('  Secondary chest',
            CHEST_SECONDARY_OPTS,
            'Materials or Gold (mutually exclusive -- only enough aether ' ..
            'for one after the GA chest).  Picked AFTER the GA attempt ' ..
            'resolves.  None = no secondary chest.')
        render_menu_header('Run lifecycle')
        gui.elements.hordes_auto_reset_after:render('Auto-reset after (s)', 'Safety net')
        gui.elements.hordes_tree:pop()
    end

    if gui.elements.boss_tree:push('Boss settings') then
        render_menu_header('Boss-altar runs.  Standalone Boss mode auto-teleports between bosses based on the selection below.  WarPlan picks the boss for you (no auto-teleport).')

        render_menu_header('Boss selection (standalone mode)')
        local SELECTION_MODES = { 'Specific', 'Random', 'Split 50/50' }
        gui.elements.boss_selection_mode:render('Selection mode', SELECTION_MODES,
            'Specific: always run primary boss.  Random: pick from enabled bosses each run.  Split: alternate primary/secondary 50/50.')
        local BOSS_LABELS = {
            'Andariel (greater)', 'Duriel (greater)', 'Varshan (lower)',
            'Grigoire (lower)',   'Lord Zir (lower)', 'Beast in Ice (lower)',
            'Harbinger (greater)','Urivar (greater)', 'Belial (husk)',
            'Bloody Butcher (greater)',
        }
        gui.elements.boss_primary:render('Primary boss', BOSS_LABELS,
            'Used by Specific mode (always) and Split mode (one of the two).')
        gui.elements.boss_secondary:render('Secondary boss', BOSS_LABELS,
            'Split-mode partner.  Ignored by Specific / Random.')

        render_menu_header('Random mode: which bosses to include')
        gui.elements.boss_enable_andariel:render('  Andariel (greater key)',  'Random pool')
        gui.elements.boss_enable_duriel:render('  Duriel (greater key)',      'Random pool')
        gui.elements.boss_enable_varshan:render('  Varshan (lower key)',      'Random pool')
        gui.elements.boss_enable_grigoire:render('  Grigoire (lower key)',    'Random pool')
        gui.elements.boss_enable_zir:render('  Lord Zir (lower key)',         'Random pool')
        gui.elements.boss_enable_beast:render('  Beast in Ice (lower key)',   'Random pool')
        gui.elements.boss_enable_harbinger:render('  Harbinger (greater key)','Random pool')
        gui.elements.boss_enable_urivar:render('  Urivar (greater key)',      'Random pool')
        gui.elements.boss_enable_belial:render('  Belial (husks)',            'Random pool -- needs Corrupted Vessels')
        gui.elements.boss_enable_butcher:render('  Bloody Butcher (greater key)', 'Random pool')

        render_menu_header('Combat')
        gui.elements.boss_kill_monsters:render('Kill monsters', 'Engage boss + adds + suppressors after the altar is clicked')
        gui.elements.boss_kill_range:render('Kill range', 'Aggro radius around the player')
        gui.elements.boss_room_tether:render('Boss-room tether', 'Walk back toward the boss room anchor when no enemy is in range')
        gui.elements.boss_do_chests:render('Open reward chests', 'After the boss dies, click EGB / Theme reward chests')

        render_menu_header('Run lifecycle')
        gui.elements.boss_altar_stuck_secs:render('Altar stuck timeout (s)',
            'If the altar is clicked but no chest appears within this window, reset the run')
        gui.elements.boss_chest_grace_secs:render('Chest grace (s)',
            'Wait this long after the chest opens before declaring the run done (so VFX + loot windows finish)')
        gui.elements.boss_auto_reset_after:render('Auto-reset after (s)', 'Safety net: full reset_all_dungeons if a run drags this long')
        gui.elements.boss_dungeon_reset_enabled:render('Periodic dungeon reset',
            'Call reset_all_dungeons() between runs every N completed runs.  Helps when long sessions accumulate stale actors / lingering effects in boss zones.')
        if gui.elements.boss_dungeon_reset_enabled:get() then
            gui.elements.boss_dungeon_reset_interval:render('  Reset every N runs',
                'How many runs between automatic resets.')
        end
        gui.elements.boss_tree:pop()
    end

    -- Nav sub-tree (movement spells + reset + freeroam debug toggle).
    -- Provided by core/nav/gui.lua so the navigation module owns its
    -- own controls; rendered inside our main_tree as a sub-section so
    -- it doesn't appear as a second top-level window.
    local ng = nav_gui()
    if ng and ng.render then
        ng.render()
    end

    if gui.elements.debug_tree:push('Debug') then
        gui.elements.debug_mode:render('Debug mode', 'Verbose console logging')
        gui.elements.debug_dump_warplan_button:render('Dump WarPlan panel',
            'Open the WAR PLANS vendor menu first, then click this to ' ..
            'print every node (id, name, reward, selectable, neighbors) ' ..
            'and the current selected path to console.  Use when the ' ..
            'auto-picker is choosing the wrong activity to figure out ' ..
            'how the host is naming each node.', 0)
        gui.elements.debug_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui
