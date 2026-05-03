-- activities/undercity/tasks/runner.lua
--
-- Thin config-only runner.

local runner = require 'core.runner'

return runner.make({
    activity    = 'undercity',
    module_path = 'activities.undercity.tasks',
    tracker     = require 'activities.undercity.tracker',
    settings    = require 'activities.undercity.settings',
    task_files  = {
        'exit',                -- chest looted / auto-reset / warp pad ready
        'goto_chest',          -- attunement chest after boss kill
        'interact_enticement', -- live-stream SpiritHearth/Beacon clicks.
                               -- Higher priority than floor_portal so we
                               -- consume enticements BEFORE descending.
        'floor_portal',        -- descend via X1_Undercity_PortalSwitch
        'interact_poi',        -- enticements, shrines, side chests (catalog)
        'kill_monster',        -- fallback combat
        'enter_undercity',     -- standalone: town brazier flow
        'idle',
    },
})
