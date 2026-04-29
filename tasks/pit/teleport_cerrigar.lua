-- ---------------------------------------------------------------------------
-- tasks/pit/teleport_cerrigar.lua
--
-- When Pit mode is active and we're not in Cerrigar, teleport there using
-- the known waypoint SNO (0x76D58 = 486744). This is the Pit hub town —
-- the Iron Wolves Pit-key Crafter NPC and the Pit portal both live here.
-- ---------------------------------------------------------------------------

local settings  = require 'core.settings'
local mode      = require 'core.mode'
local waypoints = require 'data.waypoints'

local task = { name = 'pit_teleport_cerrigar', status = nil }
local _last_tp_at = -math.huge
local TP_COOLDOWN_S = 10.0

local function in_cerrigar()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    return zone == 'Scos_Cerrigar'
end

local function in_pit()
    local w = get_current_world()
    if not w then return false end
    local n = w:get_name()
    return n ~= nil and n:match('^PIT_') ~= nil
end

task.shouldExecute = function ()
    if settings.mode ~= mode.PIT then return false end
    if in_pit() then return false end
    if in_cerrigar() then return false end
    -- Cooldown to avoid spamming tp calls
    if get_time_since_inject() - _last_tp_at < TP_COOLDOWN_S then return false end
    return true
end

task.Execute = function ()
    task.status = 'tp to Cerrigar'
    console.print('[WarMachine] pit: teleport_to_waypoint(CERRIGAR)')
    teleport_to_waypoint(waypoints.CERRIGAR)
    _last_tp_at = get_time_since_inject()
end

return task
