-- ---------------------------------------------------------------------------
-- tasks/pit/teleport_cerrigar.lua
--
-- LEGACY NAME — kept so task_manager registration doesn't change. The Pit
-- moved from Kehjistan -> Cerrigar -> Skov_Temis over patches; the
-- Pit-key Crafter now lives in Temis. We don't have a Temis waypoint SNO
-- yet, so we can't auto-tp there. Instead this task just emits a one-time
-- warning if Pit mode is selected but the player isn't at the Pit hub
-- and isn't already in a pit. User must manually be in Skov_Temis.
--
-- (If we discover Temis's waypoint SNO later, this task can be revived
-- to auto-tp via teleport_to_waypoint(waypoints.SKOV_TEMIS).)
-- ---------------------------------------------------------------------------

local settings  = require 'core.settings'
local mode      = require 'core.mode'

local task = { name = 'pit_idle_check', status = nil }
local _warned = false

local function in_pit_hub()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    return zone == 'Skov_Temis'
end

local function in_pit()
    local w = get_current_world()
    if not w then return false end
    local n = w:get_name()
    return n ~= nil and n:match('^PIT_') ~= nil
end

task.shouldExecute = function ()
    if settings.mode ~= mode.PIT then
        _warned = false   -- reset for next time the user enters Pit mode
        return false
    end
    if in_pit() then return false end
    if in_pit_hub() then return false end
    return not _warned    -- only fire once until conditions change
end

task.Execute = function ()
    console.print('[WarMachine] pit: not at Pit hub (Skov_Temis) and not in a pit. Walk/tp to Temis manually.')
    _warned = true
    task.status = 'idle (need Skov_Temis)'
end

return task
