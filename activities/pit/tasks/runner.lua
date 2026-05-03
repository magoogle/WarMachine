-- activities/pit/tasks/runner.lua
--
-- Thin config-only runner.

local runner = require 'core.runner'

return runner.make({
    activity    = 'pit',
    module_path = 'activities.pit.tasks',
    tracker     = require 'activities.pit.tracker',
    settings    = require 'activities.pit.settings',
    task_files  = {
        'exit',
        'upgrade_glyph',      -- post-boss glyph UI sequence (final floor)
        'floor_portal',       -- descend via PortalSwitch / floor portal
        'kill_monster',       -- main combat loop
        'seek_progression',   -- catalog-driven walk to closest
                              -- unvisited floor-portal / exit-switch
                              -- when no enemies in range
        'enter_pit',          -- standalone: open the pit portal in town
        'idle',
    },
})
