-- activities/helltide/tasks/runner.lua
--
-- Thin config-only runner.

local runner = require 'core.runner'

return runner.make({
    activity    = 'helltide',
    module_path = 'activities.helltide.tasks',
    tracker     = require 'activities.helltide.tracker',
    settings    = require 'activities.helltide.settings',
    task_files  = {
        'return_to_zone',     -- recover if we wandered out of the ring
        'maiden',             -- maiden event takes over when active
        'interact_poi',       -- main event: walk to + click highest-prio POI.
                              -- Priority queue handles affordability:
                              -- unaffordable Tortured Gifts get filtered out,
                              -- bot moves to next-best POI, cinders accumulate
                              -- from kills along the way, chest auto-reclaims
                              -- top priority once affordable.
        'kill_monster',       -- fallback combat
        'idle',
    },
})
