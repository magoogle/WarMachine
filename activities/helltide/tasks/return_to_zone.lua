-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/return_to_zone.lua
--
-- Recovery: if we wander out of the helltide ring (lost the buff but the
-- helltide hour is still active), navigate back to the last-confirmed
-- in-zone position rather than letting the rest of the bot teleport away
-- or sit there confused.
--
-- Tier check: if StaticPather has no path, this falls through to Batmobile
-- via move.lua's tier-3 fallback.
-- ---------------------------------------------------------------------------

local move    = require 'core.move'
local tracker = require 'activities.helltide.tracker'

local task = { name = 'return_to_zone', status = 'idle' }

local function is_in_helltide()
    local lp = get_local_player()
    if not lp or not lp.get_buffs then return false end
    local buffs = lp:get_buffs() or {}
    for _, b in ipairs(buffs) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash())
        if hash == 1066539 then return true end
    end
    return false
end

local function helltide_active_hour()
    -- Helltide runs all but the last 5 minutes of the hour.
    local minute = tonumber(os.date('%M')) or 0
    return minute < 55
end

task.shouldExecute = function ()
    if is_in_helltide() then
        -- Keep the in-zone anchor fresh while we're inside.
        local lp = get_local_player()
        if lp then tracker.last_in_zone_pos = lp:get_position() end
        return false
    end
    if not helltide_active_hour() then return false end
    if not tracker.last_in_zone_pos then return false end
    return true
end

task.Execute = function ()
    move.to_pos(tracker.last_in_zone_pos, 5)
    task.status = 'returning to zone'
end

return task
