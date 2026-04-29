-- ---------------------------------------------------------------------------
-- External plugin facade -- exposed as global WarMachinePlugin.
-- Lets other scripts (and the MCP bridge) read state and toggle the bot.
-- ---------------------------------------------------------------------------

local gui           = require 'gui'
local settings      = require 'core.settings'
local task_manager  = require 'core.task_manager'
local mode          = require 'core.mode'
local tracker       = require 'core.tracker'
local warplan_state = require 'core.warplan_state'

local external = {
    get_status = function ()
        local current = task_manager.get_current_task()
        local task_msg
        if current.status ~= nil then
            task_msg = current.name .. ' (' .. tostring(current.status) .. ')'
        else
            task_msg = current.name
        end
        return {
            name    = settings.plugin_label,
            version = settings.plugin_version,
            enabled = settings.enabled and settings.get_keybind_state(),
            mode    = mode.label(settings.mode),
            task    = task_msg,
            warplan = tracker.warplan and tracker.warplan.snapshot or nil,
        }
    end,
    -- Forced fresh read (bypasses tracker cache) -- useful for MCP probes.
    get_warplan = warplan_state.read,
    get_usable_sigils = warplan_state.usable_sigils,
    enable = function ()
        gui.elements.main_toggle:set(true)
    end,
    disable = function ()
        gui.elements.main_toggle:set(false)
    end,
    set_mode = function (m)
        if type(m) == 'number' and mode.labels[m] then
            gui.elements.mode_select:set(m)
            return true
        end
        return false
    end,
    get_mode = function ()
        return settings.mode, mode.label(settings.mode)
    end,
}

return external
