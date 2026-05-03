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

return kill_task.make({
    name        = 'kill_monster',
    settings    = settings,
    debug_label = 'Helltide',
})
