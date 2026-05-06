local plugin_label = 'wm_nav'
local plugin_version = '1.0.12'
console.print("Lua Plugin - WarMachine nav v" .. plugin_version)

local get_character_class = function (local_player)
    if not local_player then
        local_player = get_local_player();
    end
    if not local_player then return end
    local class_id = local_player:get_character_class_id()
    local character_classes = {
        [0] = 'sorcerer',
        [1] = 'barbarian',
        [3] = 'rogue',
        [5] = 'druid',
        [6] = 'necromancer',
        [7] = 'spiritborn',
        [8] = 'default', -- new class in expansion, dont know name yet
        [9] = 'paladin'
    }
    if character_classes[class_id] then
        return character_classes[class_id]
    else
        return 'default'
    end
end

local gui = {}

local function create_checkbox(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label = plugin_label
gui.plugin_version = plugin_version
gui.log_levels_enum = {
    DISABLED = 0,
    INFO = 1,
    DEBUG = 2
}
gui.log_level = { 'Disabled', 'Info', 'Debug'}

gui.elements = {
    -- Sub-tree of WarMachine's main menu (depth 1).  WarMachine/gui.lua
    -- calls gui.render() inside its own main_tree push/pop.
    main_tree = tree_node:new(1),
    reset_keybind        = keybind:new(0x0A, true, get_hash(plugin_label .. '_reset_keybind' )),
    draw_keybind_toggle  = keybind:new(0x0A, true, get_hash(plugin_label .. '_draw_keybind_toggle' )),
    movement_tree = tree_node:new(2),
    move_keybind_toggle  = keybind:new(0x0A, true, get_hash(plugin_label .. '_move_keybind_toggle' )),
    use_evade              = create_checkbox(true, "use_evade"),
    use_teleport           = create_checkbox(true, "use_teleport"),
    use_teleport_enchanted = create_checkbox(true, "use_teleport_enchanted"),
    use_dash               = create_checkbox(true, "use_dash"),
    use_soar               = create_checkbox(true, "use_soar"),
    use_hunter             = create_checkbox(true, "use_hunter"),
    use_leap               = create_checkbox(true, "use_leap"),
    use_charge             = create_checkbox(true, "use_charge"),
    use_advance            = create_checkbox(true, "use_advance"),
    use_falling_star       = create_checkbox(true, "use_falling_star"),
    use_aoj                = create_checkbox(true, "use_aoj"),
    -- Logging level lives next to Reset/Draw -- it's a one-line knob
    -- developers occasionally bump up while reproducing a bug.
    log_level = combo_box:new(0, get_hash(plugin_label .. '_' .. 'log_level')),
    -- Freeroam keybind: held-key explorer mode.  Mostly a debug aid now
    -- that activities drive nav themselves; left in for ad-hoc testing.
    freeroam_keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_freeroam_keybind_toggle' )),
}

function gui.render()
    if not gui.elements.main_tree:push('Navigation') then return end
    gui.elements.draw_keybind_toggle:render('Toggle drawing', 'Render the navigator overlay (path + frontier)')
    gui.elements.move_keybind_toggle:render('Use movement spells', 'Use class movement skills (evade, teleport, dash, etc.) when pathfinding')
    gui.elements.reset_keybind:render('Reset navigation', 'Clear the navigator state -- use to recover from a stuck path')
    gui.elements.freeroam_keybind_toggle:render('Freeroam explorer (debug)',
        'Hold key to drive the in-script explorer.  Activities drive nav on their own; this is just an ad-hoc debug toggle.  WARNING: running freeroam in the overworld can cause lag spikes from elevation + traversal scans.')
    gui.elements.log_level:render('Log level', gui.log_level,
        'Verbosity for the navigator\'s own debug prints')

    if gui.elements.movement_tree:push('Movement Spells') then
        render_menu_header("Toggle 'Use movement spells' above before any of these have effect.")
        local class = get_character_class()
        gui.elements.use_evade:render('Evade', 'Use evade for movement')
        if class == 'sorcerer' then
            gui.elements.use_teleport:render('Teleport', 'Use teleport for movement')
            gui.elements.use_teleport_enchanted:render('Teleport (enchanted)', 'Use teleport enchanted for movement')
        elseif class == 'rogue' then
            gui.elements.use_dash:render('Dash', 'Use dash for movement')
        elseif class == 'spiritborn' then
            gui.elements.use_soar:render('Soar', 'Use soar for movement')
            gui.elements.use_hunter:render('Hunter', 'Use hunter for movement')
        elseif class == 'barbarian' then
            gui.elements.use_leap:render('Leap', 'Use leap for movement')
            gui.elements.use_charge:render('Charge', 'Use charge for movement')
        elseif class == 'paladin' then
            gui.elements.use_advance:render('Advance', 'Use advance for movement')
            gui.elements.use_falling_star:render('Falling Star', 'Use Falling Star for movement')
            gui.elements.use_aoj:render('Arbiter of Justice', 'Use Arbiter of Justice for movement')
        end
        gui.elements.movement_tree:pop()
    end

    gui.elements.main_tree:pop()
end

-- Long Path Debug + Nav viz + advanced-iteration sliders were removed
-- from this GUI -- the controls were dev-only and noisy in the menu.
-- The long_path module is still used by activities (move.to_pos auto-
-- engages it for goals > 60y); only the debug pin/test buttons are
-- gone.  If you need to reintroduce a debug knob, restore it here and
-- wire up the corresponding handler block in core/nav/init.lua.

return gui
