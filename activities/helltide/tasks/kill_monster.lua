-- activities/helltide/tasks/kill_monster.lua
--
-- Fallback combat for helltide.  Only fires when the POI queue is
-- empty -- most active helltide pulses are interact_poi walking to
-- the next chest/pyre.  Thin wrapper over core.kill_task with no
-- activity-specific bosses to latch (helltide's "boss" is the
-- maiden, owned by activities/helltide/tasks/maiden.lua).
--
-- Was a 67-line file with its own closest-by-tier picker; now uses
-- the shared core.target picker so reachability filtering + goblin
-- override apply uniformly.

local kill_task = require 'core.kill_task'
local settings  = require 'activities.helltide.settings'

local HELLTIDE_BUFF_HASH = 1066539

local function is_in_helltide()
    local lp = get_local_player()
    if not lp or not lp.get_buffs then return false end
    for _, b in ipairs(lp:get_buffs() or {}) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash())
        if hash == HELLTIDE_BUFF_HASH then return true end
    end
    return false
end

return kill_task.make({
    name         = 'kill_monster',
    settings     = settings,
    -- Don't fight outside the helltide ring.  Outside the ring the bot
    -- should be navigating back in, not chasing enemies.
    extra_should = is_in_helltide,
    debug_label  = 'Helltide',
})
