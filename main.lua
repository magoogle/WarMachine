-- ---------------------------------------------------------------------------
-- WarMachine v0.2 by Magoogle -- War Plan orchestrator.
--
-- Single entry point that drives the War Plan cycle: opens the WAR PLANS
-- vendor menu, selects activities, teleports between them via the map's
-- Next-Obj button, hands each activity off to the matching sub-plugin
-- (SigilRunner / HelltideRevamped / WonderCity / ArkhamAsylum / HordeDev),
-- and claims rewards at Tyrael when complete.
--
-- Sub-plugins remain independent and own their in-zone runtime. WarMachine
-- enables the matching one when the player is in the activity's zone and
-- disables it on transition.
-- ---------------------------------------------------------------------------

local plugin_label = 'warmachine'

local gui              = require 'gui'
local settings         = require 'core.settings'
local task_manager     = require 'core.task_manager'
local external         = require 'core.external'
local tracker          = require 'core.tracker'
local warplan_state    = require 'core.warplan_state'
local mode             = require 'core.mode'
local activity_manager = require 'core.activity_manager'
local alfred_bridge    = require 'core.alfred_bridge'

local local_player, player_position
local debounce_time    = nil
local debounce_timeout = 0

local update_locals = function ()
    local_player    = get_local_player()
    player_position = local_player and local_player:get_position()
end

-- ---------------------------------------------------------------------------
-- Broadcast warmachine_mode to all sub-plugins.
--
-- Each sub-plugin (ArkhamAsylum, HelltideRevamped, SigilRunner, WonderCity,
-- HordeDev) exposes set_warmachine_mode(state) on its plugin global. While ON, the
-- sub-plugin gates off its own town/entry/exit/transition tasks so
-- WarMachine can drive the War Plan flow without the sub-plugin fighting
-- back from a town zone (e.g. SigilRunner trying to consume a sigil while
-- WarMachine is between activities).
--
-- Debounced via tracker.warmachine_active so we only flip the checkboxes
-- on actual state change. nil-safe when sub-plugins aren't loaded.
-- ---------------------------------------------------------------------------
local broadcast_warmachine_mode = function (active)
    if tracker.warmachine_active == active then return end
    tracker.warmachine_active = active
    local broadcast = function (plugin, name)
        if plugin and plugin.set_warmachine_mode then
            plugin.set_warmachine_mode(active)
            if settings.debug_mode then
                console.print(string.format(
                    '[WarMachine] %s.set_warmachine_mode(%s)',
                    name, tostring(active)))
            end
        end
    end
    broadcast(ArkhamAsylumPlugin,     'ArkhamAsylumPlugin')
    broadcast(HelltideRevampedPlugin, 'HelltideRevampedPlugin')
    broadcast(SigilRunnerPlugin,      'SigilRunnerPlugin')
    broadcast(WonderCityPlugin,       'WonderCityPlugin')
    broadcast(InfernalHordesPlugin,   'InfernalHordesPlugin')
    broadcast(ReaperPlugin,           'ReaperPlugin')
end

-- When WarMachine is disabled (or the user changes mode), make sure no
-- activity is left "active" in the activity_manager -- otherwise the
-- next enable would skip the activate() step.
local _last_seen_mode = nil
local function on_disable_or_mode_change()
    if (not settings.enabled or not settings.get_keybind_state())
       and activity_manager.get_active_tag() then
        activity_manager.shutdown()
    elseif _last_seen_mode and _last_seen_mode ~= settings.mode then
        activity_manager.shutdown()
    end
    _last_seen_mode = settings.mode
end

local main_pulse = function ()
    if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then
        return
    end
    debounce_time = get_time_since_inject()

    settings:update_settings()

    if not local_player then return end

    -- Sync warmachine_mode to sub-plugins whenever WarMachine's "actively
    -- driving" state changes. We do this BEFORE the enabled-gate so that
    -- turning WarMachine off correctly clears warmachine_mode on every
    -- sub-plugin, releasing them to run standalone again.
    broadcast_warmachine_mode(settings.enabled and settings.get_keybind_state() and true or false)

    -- Detect disable / mode-change so activity_manager can deactivate cleanly.
    on_disable_or_mode_change()

    if not settings.enabled or not settings.get_keybind_state() then return end

    if tracker.bot_done then return end

    -- Track zone transitions for downstream phases.
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    if zone ~= tracker.last_zone then
        tracker.last_zone = zone
        if settings.debug_mode then
            console.print('[WarMachine] Zone -> ' .. tostring(zone))
        end
    end

    -- Refresh War Plan state every pulse -- quest API is cheap to read.
    -- Detect transitions (none -> active, active -> none, activity changed).
    local wp = warplan_state.read()
    local prev = tracker.warplan.snapshot
    local changed = false
    if not prev then
        if wp.active then changed = true end
    elseif prev.active ~= wp.active then
        changed = true
    elseif wp.active and prev.quest and wp.quest then
        if prev.quest.name ~= wp.quest.name or prev.quest.phase_id ~= wp.quest.phase_id then
            changed = true
        end
    end
    tracker.warplan.snapshot = wp
    if changed and settings.debug_mode then
        if wp.active then
            console.print(string.format('[WarMachine] WarPlan -> %s (activity=%s, phase=%d)',
                wp.quest.name, tostring(wp.activity), wp.quest.phase_id))
        else
            console.print('[WarMachine] WarPlan -> none')
        end
    end

    if local_player:is_dead() then
        revive_at_checkpoint()
    else
        -- Alfred bridge: if bags are full / repair needed AND the active
        -- in-house activity is in a safe-to-interrupt state, hand control
        -- to AlfredTheButler for a town run.  Yields THIS pulse while
        -- Alfred is running so we don't fight it for input.  Activities
        -- self-deselect via shouldExecute() once Alfred teleports out of
        -- the activity zone, then re-engage when the player is back.
        if alfred_bridge.update() then return end

        -- Dispatch by mode.
        --
        -- WARPLAN: BOTH paths run.
        --   * task_manager.execute_tasks() drives WarPlan orchestration
        --     (vendor menu clicks, Next-Obj teleports, turn-in at Tyrael)
        --     -- NOT in-zone activity gameplay.
        --   * activity_manager.pulse(WARPLAN) drives the in-zone activity
        --     by reading tracker.warplan.snapshot.activity and dispatching
        --     to the matching internal module (activities/pit/, etc.).
        --     The two run independently each pulse and don't conflict
        --     because task_manager's tasks all gate on
        --     `tracker.warplan.<X>.pending` flags or zone-classification,
        --     while activity_manager only runs when an activity module's
        --     shouldExecute() returns true (typically requires being in
        --     the activity's runtime zone).
        --
        -- Standalone modes (PIT/UC/HELLTIDE/NMD/HORDES): only
        -- activity_manager.  IDLE: nothing.
        if settings.mode == mode.WARPLAN then
            task_manager.execute_tasks()
            activity_manager.pulse(mode.WARPLAN)
        elseif settings.mode ~= mode.IDLE then
            activity_manager.pulse(settings.mode)
        end
    end
end

-- Slot colors are grouped per row (3 cells per row, 5 rows total) so the
-- user can read the grid visually: red=R1, green=R2, yellow=R3, cyan=R4,
-- orange=R5. Labels "1".."15" disambiguate which cell within a row.
local cp_colors = {
    [1]  = color_red(220),    [2]  = color_red(220),    [3]  = color_red(220),
    [4]  = color_green(220),  [5]  = color_green(220),  [6]  = color_green(220),
    [7]  = color_yellow(220), [8]  = color_yellow(220), [9]  = color_yellow(220),
    [10] = color_cyan(220),   [11] = color_cyan(220),   [12] = color_cyan(220),
    [13] = color_orange(220), [14] = color_orange(220), [15] = color_orange(220),
    start          = color_white(255),
    confirm        = color_silver(255),
    next_objective = color_purple(220),
}

local function draw_crosshair(cx, cy, label, color)
    local arm = 12
    graphics.line(vec2:new(cx - arm, cy), vec2:new(cx + arm, cy), color, 2)
    graphics.line(vec2:new(cx, cy - arm), vec2:new(cx, cy + arm), color, 2)
    graphics.circle_2d(vec2:new(cx, cy), 5, color, 1)
    graphics.text_2d(label, vec2:new(cx + 14, cy - 8), 14, color)
end

local render_pulse = function ()
    -- Click-point overlay renders regardless of bot enable state -- it's a
    -- positioning aid that needs to be visible while the user is dragging
    -- sliders, even before they flip Enable on.
    if settings.warplan and settings.warplan.show_click_points then
        local cps = settings.warplan.click_points
        if cps then
            for i, slot in ipairs(cps.slots or {}) do
                draw_crosshair(slot.x, slot.y, slot.label, cp_colors[i] or color_white(220))
            end
            if cps.start then
                draw_crosshair(cps.start.x, cps.start.y, cps.start.label, cp_colors.start)
            end
            if cps.confirm and (cps.confirm.x ~= 0 or cps.confirm.y ~= 0) then
                draw_crosshair(cps.confirm.x, cps.confirm.y, cps.confirm.label, cp_colors.confirm)
            end
            if cps.next_objective then
                draw_crosshair(cps.next_objective.x, cps.next_objective.y,
                    cps.next_objective.label, cp_colors.next_objective)
            end
        end
    end

    -- Undercity click points overlay
    if settings.warplan and settings.warplan.show_click_points
       and settings.undercity and settings.undercity.click_points then
        local op = settings.undercity.click_points.open_portal
        if op and (op.x ~= 0 or op.y ~= 0) then
            draw_crosshair(op.x, op.y, op.label, color_brown(220))
        end
    end

    -- (NMD, Pit, and Helltide standalone modes were removed -- the
    -- corresponding sub-plugins handle their own click points.)

    if not local_player or not settings.enabled then return end
    if not settings.get_keybind_state() then return end

    local cur     = task_manager.get_current_task()
    local task_str = cur.name
    if cur.status ~= nil then
        task_str = cur.name .. ' (' .. tostring(cur.status) .. ')'
    end

    local msg = string.format(
        'WarMachine v%s | Task: %s',
        settings.plugin_version,
        task_str
    )
    -- All three overlay lines share the same starting x so they look like
    -- a coherent left-aligned block. Centering each line by its own length
    -- with a fixed 5.5 px/char doesn't work across font sizes 20/18/16 --
    -- smaller fonts end up visibly shifted left of the larger one.
    local x = get_screen_width() / 2 - (#msg * 5.5)
    -- y=200 keeps the WarMachine overlay clear of sub-plugin status lines
    -- (HelltideRevamped, ArkhamAsylum, WonderCity, etc.) which all draw
    -- around y=60..120 at the top of the screen.
    local y = 200
    graphics.text_2d(msg, vec2:new(x, y), 20, color_white(255))

    -- Active War Plan summary (if any) -- driven from the cached snapshot.
    local wp = tracker.warplan and tracker.warplan.snapshot
    if wp and wp.active and wp.quest then
        -- Header line: name, activity, macro progress
        local progress_str = ''
        if wp.macro_progress then
            progress_str = string.format(' [%d/%d]', wp.macro_progress.cur, wp.macro_progress.max)
        end
        local wp_msg = string.format('Active WarPlan: %s [%s]%s',
            wp.quest.name, tostring(wp.activity), progress_str)
        graphics.text_2d(wp_msg, vec2:new(x, y + 24), 18, color_yellow(220))

        -- First non-"War Plan: N/M" objective text -- that's the actionable line
        for _, o in ipairs(wp.quest.objectives or {}) do
            if o.text and not o.text:find('War Plan:') then
                local t = o.text
                if #t > 80 then t = t:sub(1, 77) .. '...' end
                graphics.text_2d(t, vec2:new(x, y + 46), 16, color_white(200))
                break
            end
        end
    end
end

on_update(function ()
    update_locals()
    main_pulse()
end)

on_render_menu(function ()
    gui.render()
end)

on_render(render_pulse)

WarMachinePlugin = external
