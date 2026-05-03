-- activities/hordes/tasks/runner.lua
--
-- Thin config-only runner.  Hordes-specific quirks vs. the other
-- activities:
--   * NO freeroam fallback -- the BSK arena is small + fully
--     catalogued by WarPath, so explorer's frontier search adds no
--     value and would just thrash pathfinder.calculate_and_get_path_points.
--     walk_boss_room handles the "no enemy in range" case directly.
--   * Idle-diag watchdog ON -- the user reported "teleported in and
--     just stood there" failure modes; the diag dump after IDLE_LOG_S
--     of continuous idle surfaces which task chain broke (gated
--     behind settings.debug_mode -- see core/runner.lua).

local runner = require 'core.runner'

return runner.make({
    activity    = 'hordes',
    module_path = 'activities.hordes.tasks',
    tracker     = require 'activities.hordes.tracker',
    settings    = require 'activities.hordes.settings',
    freeroam    = false,
    debug_idle  = true,
    task_files  = {
        'exit',                 -- run-done (chests opened) or safety timeout
        'interact_pylon',       -- between-wave pylon choice (~10s window)
        'interact_boss_portal', -- end-of-waves portal -> boss arena
        'open_chest',           -- boss-kill reward chests
        'interact_aether',      -- BSK_Structure_BonusAether mid-wave bonus
        'kill_monster',         -- engage everything else (tiered priority)
        'walk_boss_room',       -- fallback when arena empty (pre-spawn)
        'idle',
    },
})
