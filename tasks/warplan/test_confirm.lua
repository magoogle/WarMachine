-- ---------------------------------------------------------------------------
-- tasks/warplan/test_confirm.lua
--
-- Manual-only: when the user clicks "Test: dismiss confirm dialog", call
-- utility.confirm_sigil_notification() once. If it dismisses the WAR PLANS
-- post-START confirmation popup, we promote it to an auto handler in the
-- dispatch chain. If not, we fall back to a click-coord on the popup.
-- ---------------------------------------------------------------------------

local gui = require 'gui'

local task = { name = 'warplan_test_confirm', status = nil }
local _fired = false

task.shouldExecute = function ()
    if gui.elements.warplan_test_confirm_button:get() and not _fired then
        _fired = true
        return true
    end
    -- Reset the rising-edge guard once the button releases
    if not gui.elements.warplan_test_confirm_button:get() then
        _fired = false
    end
    return false
end

task.Execute = function ()
    local ok, err = pcall(function()
        if utility and utility.confirm_sigil_notification then
            utility.confirm_sigil_notification()
            console.print('[WarMachine] test_confirm: utility.confirm_sigil_notification() called')
        else
            console.print('[WarMachine] test_confirm: utility.confirm_sigil_notification not available')
        end
    end)
    if not ok then
        console.print('[WarMachine] test_confirm: error -> ' .. tostring(err))
    end
end

return task
