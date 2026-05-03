-- activities/nmd/tasks/kill_monster.lua
--
-- Reactive combat for nightmare dungeons.  Just a thin wrapper over
-- core.kill_task -- the priority logic (boss > elite > closest, with
-- reachability filter + goblin-tier override) lives in core.target,
-- and the engage loop lives in core.kill_task.

local kill_task = require 'core.kill_task'
local settings  = require 'activities.nmd.settings'
local tracker   = require 'activities.nmd.tracker'

return kill_task.make({
    name        = 'kill_monster',
    settings    = settings,
    tracker     = tracker,
    debug_label = 'NMD',
})
