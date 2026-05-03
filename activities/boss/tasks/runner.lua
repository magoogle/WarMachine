-- activities/boss/tasks/runner.lua
--
-- Thin config-only runner.

local runner = require 'core.runner'

return runner.make({
    activity    = 'boss',
    module_path = 'activities.boss.tasks',
    tracker     = require 'activities.boss.tracker',
    settings    = require 'activities.boss.settings',
    task_files  = {
        'select_boss',     -- standalone-only: teleport to next boss
        'exit',            -- run-complete or safety timeout
        'interact_altar',  -- click the summon altar
        'open_chest',      -- post-kill reward chest
        'kill_monster',    -- boss + adds + suppressors
        'walk_boss_room',  -- anchor when arena empty (post-altar, pre-spawn)
        'idle',
    },
})
