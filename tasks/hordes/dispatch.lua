-- ---------------------------------------------------------------------------
-- tasks/hordes/dispatch.lua
--
-- Stub dispatcher for Infernal Hordes mode. Currently does nothing —
-- needs data discovery before it can be wired up. Specifically:
--
--   • The Hordes vendor NPC skin name (in town — likely Skov_Temis or Cerrigar)
--   • Compass item naming pattern (Infernal_Compass_*?)
--   • The Apply Compass UI (click points + key presses)
--   • The Hordes zone name pattern (DGN_Hordes_* / Tower_* / similar)
--   • The end-of-Hordes Aether vault interactable
--   • Compass tier filtering (if applicable)
--
-- Until those are captured via MCP, this task just announces "Hordes
-- mode TBD" once when the user enters Hordes mode, then stays silent.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local mode     = require 'core.mode'

local task = { name = 'hordes_dispatch', status = nil }

local _announced = false

task.shouldExecute = function ()
    if settings.mode ~= mode.HORDES then
        _announced = false   -- reset so we re-announce next time mode flips
        return false
    end
    return not _announced
end

task.Execute = function ()
    if not _announced then
        console.print('[WarMachine] Hordes mode: not yet implemented. Need data on:')
        console.print('  • Hordes vendor NPC skin name')
        console.print('  • Infernal Compass item pattern')
        console.print('  • Apply-Compass UI flow + click points')
        console.print('  • Hordes zone name pattern')
        console.print('  • End-of-run Aether vault interactable')
        console.print('Drop into Hordes via the manual flow + ping me with MCP captures.')
        _announced = true
    end
    task.status = 'Hordes mode TBD (awaiting data capture)'
end

return task
