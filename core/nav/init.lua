-- ---------------------------------------------------------------------------
-- core/nav/init.lua  --  WarMachine's primary navigation sub-module.
--
-- Boots as part of WarMachine via `require 'core.nav'` from
-- WarMachine/main.lua.  Side effects on load:
--   * registers its own on_update / on_render / on_render_menu callbacks
--     (the host runs all registered handlers each frame, so this stacks
--     cleanly with WarMachine's own callbacks)
--   * publishes WarMachineNav as the public global API
--   * publishes a back-compat global with the legacy plugin-global name
--     so existing consumers (AlfredTheButler tasks, Reaper boss-nav)
--     keep working unchanged.  The alias can be removed once all
--     consumers migrate to WarMachineNav.
-- ---------------------------------------------------------------------------

local plugin_label = 'wm_nav'

local gui          = require 'core.nav.gui'
local settings     = require 'core.nav.settings'
local external     = require 'core.nav.external'
local drawing      = require 'core.nav.drawing'
local utils        = require 'core.nav.utils'
local tracker      = require 'core.nav.tracker'
local navigator    = require 'core.nav.navigator'
local long_path    = require 'core.nav.long_path'
local explorer     = require 'core.nav.explorer'
local pathfinder   = require 'core.nav.pathfinder'
local persistence  = require 'core.nav.persistence'

-- Explorer memory: lives in process memory only -- no disk I/O.
-- Cell knowledge accumulates while the player stays in one zone (and one
-- procedural world_id, where applicable), and is dropped on every zone
-- change so cells from the previous zone can't bleed into the new one's
-- absolute-position-keyed state.  Coming back to a zone re-explores from
-- scratch -- the trade-off for a stutter-free run loop.
--
-- Tracking world_id (not just zone name) covers the procedural-floor
-- case: PIT_Subzone re-entered with a different world_id is genuinely a
-- new layout, so we must reset.
local _last_zone     = nil
local _last_world_id = nil

local function current_zone_name()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return nil end
    return w:get_current_zone_name()
end

local function current_world_id()
    local w = get_current_world()
    if not w or not w.get_world_id then return nil end
    return w:get_world_id()
end

local function on_change(prev_zone, prev_wid, cur_zone, cur_wid)
    -- Reset everything keyed by absolute cell position.  Without this,
    -- cells from the previous zone bleed into the new zone's explorer
    -- state and confuse the navigator.
    explorer.reset()
    if pathfinder.clear_wall_penalty_cache then
        pathfinder.clear_wall_penalty_cache()
    end
end

local function detect_change()
    local cur_zone = current_zone_name()
    local cur_wid  = current_world_id()
    if cur_zone ~= _last_zone or cur_wid ~= _last_world_id then
        on_change(_last_zone, _last_world_id, cur_zone, cur_wid)
        _last_zone     = cur_zone
        _last_world_id = cur_wid
    end
end

local local_player
local debounce_time = nil
local debounce_timeout = 1
local draw_keybind_data = checkbox:new(false, get_hash(plugin_label .. '_draw_keybind_data'))
local move_keybind_data = checkbox:new(false, get_hash(plugin_label .. '_move_keybind_data'))
if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false then
    gui.elements.draw_keybind_toggle:set(draw_keybind_data:get())
    gui.elements.move_keybind_toggle:set(move_keybind_data:get())
end

local function update_locals()
    local_player = get_local_player()
end

local function main_pulse()
    if utils.player_loading() then
        -- extend last_update so that it doesnt trigger unstuck straight after loading
        navigator.last_update = get_time_since_inject() + 5
    end
    -- Cheap per-pulse zone-change check; resets in-memory cell state
    -- when (zone, world_id) flips so the new zone starts clean.
    detect_change()
    settings:update_settings()
    if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false  then
        if draw_keybind_data:get() ~= (gui.elements.draw_keybind_toggle:get_state() == 1) then
            draw_keybind_data:set(gui.elements.draw_keybind_toggle:get_state() == 1)
        end
        if move_keybind_data:get() ~= (gui.elements.move_keybind_toggle:get_state() == 1) then
            move_keybind_data:set(gui.elements.move_keybind_toggle:get_state() == 1)
        end
    end
    if gui.elements.reset_keybind:get_state() == 1 then
        if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
        gui.elements.reset_keybind:set(false)
        debounce_time = get_time_since_inject()
        navigator.reset()
    end
    -- Long Path Debug GUI buttons (Set Target / Cursor / Test) were
    -- removed -- the long_path module itself stays in use by activities
    -- via move.to_pos auto-engaging it for goals > 60y.  Only the
    -- ad-hoc pin-and-test debug widgets are gone.
    --
    -- long_path.navigating is still driven through external API calls
    -- (BatmobilePlugin.navigate_long_path / WarMachineNav equivalents)
    -- so the navigation pulse below still applies.
    if long_path.navigating then
        if not local_player or local_player:is_dead() then
            long_path.stop_navigation()
        else
            local cur = utils.normalize_node(local_player:get_position())
            -- Reached target: navigator consumed the path and is at the goal
            if navigator.target ~= nil and utils.distance(cur, navigator.target) <= 1 then
                console.print("[LONG PATH] Reached target!")
                long_path.navigating  = false
                long_path.active_path = nil
                navigator.clear_target()
            elseif navigator.target == nil and #navigator.path == 0 then
                console.print("[LONG PATH] Navigation complete")
                long_path.navigating  = false
                long_path.active_path = nil
            else
                navigator.unpause()
                local start_update = os.clock()
                navigator.update()
                tracker.timer_update = os.clock() - start_update
                local start_move = os.clock()
                navigator.move()
                tracker.timer_move = os.clock() - start_move
            end
        end
    end
    if gui.elements.freeroam_keybind_toggle:get_state() == 1 then
        if local_player:is_dead() then
            revive_at_checkpoint()
        end
        -- Town/hub gate: skip explorer accumulation in non-trackable
        -- zones (Skov_Temis, Cerrigar, Kyovashad, Margrave, etc.).
        -- Towns are tiny + transit-only; tracking cells there bloats
        -- the in-memory tables and runs the navigator's frontier
        -- selector for no useful exploration.  Player can still walk
        -- around freely via the host's normal movement; we just skip
        -- the navigator's update/move heartbeat.  See SKIP_PREFIXES
        -- in core/nav/persistence.lua for the full skip list.
        local cur_zone = current_zone_name()
        if persistence.is_persistable_zone(cur_zone) then
            navigator.unpause()
            local start_update = os.clock()
            navigator.update()
            tracker.timer_update = os.clock() - start_update
            local start_move = os.clock()
            navigator.move()
            tracker.timer_move = os.clock() - start_move
        end
    end
end

local function render_pulse()
    if not local_player then return end
    if not settings.draw then return end
    drawing.draw_nodes(local_player)
end

on_update(function()
    update_locals()
    main_pulse()
end)

-- Nav GUI is rendered as a sub-tree of WarMachine's main menu (called
-- from WarMachine/gui.lua), not as a top-level on_render_menu handler --
-- otherwise it'd appear as a second separate window in the cheat menu.
on_render(render_pulse)

-- Public globals.
WarMachineNav   = external
-- Back-compat alias under the legacy plugin-global name so existing
-- consumers keep working without a coordinated update.  Drop this line
-- once Alfred/Reaper migrate to WarMachineNav.
BatmobilePlugin = external
