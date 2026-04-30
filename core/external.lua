-- ---------------------------------------------------------------------------
-- External plugin facade -- exposed as global WarMachinePlugin.
--
-- Other plugins (AlfredTheButler especially) introspect WarMachine's state
-- to coordinate: pause looting while WarMachine is mid-teleport, hand off
-- inventory salvage when WarMachine asks for it, etc.  The surface here is
-- what they're allowed to read/poke.
-- ---------------------------------------------------------------------------

local gui              = require 'gui'
local settings         = require 'core.settings'
local task_manager     = require 'core.task_manager'
local mode             = require 'core.mode'
local tracker          = require 'core.tracker'
local warplan_state    = require 'core.warplan_state'
local activity_manager = require 'core.activity_manager'

local external = {}

-- ---------------------------------------------------------------------------
-- Status reads
-- ---------------------------------------------------------------------------

-- Top-level status -- used by the GUI overlay AND by other plugins.
external.get_status = function ()
    local current = task_manager.get_current_task()
    local task_msg
    if current and current.status ~= nil then
        task_msg = current.name .. ' (' .. tostring(current.status) .. ')'
    elseif current then
        task_msg = current.name
    end

    local active_tag = activity_manager.get_active_tag()
    local act_status = active_tag and activity_manager.get_status() or nil

    return {
        name           = settings.plugin_label,
        version        = settings.plugin_version,
        enabled        = settings.enabled and settings.get_keybind_state() or false,
        mode           = mode.label(settings.mode),
        mode_value     = settings.mode,
        task           = task_msg,
        warplan        = tracker.warplan and tracker.warplan.snapshot or nil,
        active_activity = active_tag,
        activity       = act_status,
    }
end

-- Boolean: is WarMachine actively running an activity right now?
-- Useful guard for Alfred/Looteer to gate "is the bot busy".
external.is_busy = function ()
    if not (settings.enabled and settings.get_keybind_state()) then return false end
    return activity_manager.get_active_tag() ~= nil
end

-- Boolean: is the player currently in the indicated activity?
external.is_in_activity = function (tag)
    return activity_manager.get_active_tag() == tag
end

-- Returns activity tag string ('pit'/'undercity'/...) or nil.
external.current_activity = function ()
    return activity_manager.get_active_tag()
end

-- Returns the per-activity status table (whatever that activity's
-- get_status() returns) -- e.g. { task = 'kill_monster', floor = 3 }.
external.get_activity_status = function (tag)
    if tag and tag ~= activity_manager.get_active_tag() then return nil end
    return activity_manager.get_status()
end

-- ---------------------------------------------------------------------------
-- Pause / resume coordination -- Alfred uses this to ask WarMachine to
-- hold while it does town/inventory work.  We just toggle a tracker flag;
-- main_pulse + activity_manager check it before pulsing tasks.
-- ---------------------------------------------------------------------------
external.request_pause = function (caller, reason)
    if not caller then return false end
    tracker.external_pause = tracker.external_pause or {}
    tracker.external_pause[caller] = reason or true
    return true
end

external.request_resume = function (caller)
    if not caller then return false end
    if tracker.external_pause then
        tracker.external_pause[caller] = nil
        if next(tracker.external_pause) == nil then
            tracker.external_pause = nil
        end
    end
    return true
end

external.is_externally_paused = function ()
    return tracker.external_pause and next(tracker.external_pause) ~= nil or false
end

-- ---------------------------------------------------------------------------
-- Quest API passthroughs (cheap reads).
-- ---------------------------------------------------------------------------
external.get_warplan = warplan_state.read
external.get_usable_sigils = warplan_state.usable_sigils

-- ---------------------------------------------------------------------------
-- Enable / disable / mode select.  Drives the GUI checkboxes so the user's
-- visual state stays in sync with whatever the orchestrator is doing.
-- ---------------------------------------------------------------------------
external.enable = function ()
    gui.elements.main_toggle:set(true)
end

external.disable = function ()
    gui.elements.main_toggle:set(false)
end

external.set_mode = function (m)
    if type(m) == 'number' and mode.labels[m] then
        if gui.elements.mode_select then
            gui.elements.mode_select:set(mode.to_index(m))
            return true
        end
    end
    return false
end

external.get_mode = function ()
    return settings.mode, mode.label(settings.mode)
end

-- ---------------------------------------------------------------------------
-- Activity registry introspection -- lets the GUI grey out modes whose
-- backing module isn't ported yet.  Also useful for "what activities does
-- this WarMachine build support" queries.
-- ---------------------------------------------------------------------------
external.list_activities = activity_manager.list_activities
external.is_activity_loaded = activity_manager.is_activity_loaded

return external
