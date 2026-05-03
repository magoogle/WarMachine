-- activities/pit/tasks/kill_monster.lua
--
-- Reactive combat for The Pit.  Thin wrapper over core.kill_task with
-- pit-specific boss-seen patterns -- the host's is_boss flag doesn't
-- fire the moment the boss spawns for some pit families, so we layer
-- a skin-substring fallback on top.

local kill_task = require 'core.kill_task'
local settings  = require 'activities.pit.settings'
local tracker   = require 'activities.pit.tracker'

-- Pit boss-seen latch patterns.  Conservative -- a non-match doesn't
-- prevent the kill, just skips the latch.  Hits both the SNO-encoded
-- skin patterns and the human-readable boss family names.
local PIT_BOSS_PATTERNS = {
    'TWR_Boss_',
    '_Boss_KUC',
    '_Boss_HoardingChest',
    'Pit_Boss_',
    'Andariel', 'Duriel', 'Lilith', 'Belial', 'Bahamut',
    'Astaroth', 'Diablo', 'MegaDemon',
}

return kill_task.make({
    name               = 'kill_monster',
    settings           = settings,
    tracker            = tracker,
    boss_skin_patterns = PIT_BOSS_PATTERNS,
    debug_label        = 'Pit',
})
