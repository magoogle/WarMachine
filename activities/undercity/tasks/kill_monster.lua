-- activities/undercity/tasks/kill_monster.lua
--
-- Reactive combat for the Undercity.  Thin wrapper over core.kill_task
-- with undercity-specific boss-seen patterns.

local kill_task = require 'core.kill_task'
local settings  = require 'activities.undercity.settings'
local tracker   = require 'activities.undercity.tracker'

local UC_BOSS_PATTERNS = {
    'S11_Andariel_Boss_KUC',
    'X1_Undercity_Ghost_Caster_Miniboss',
    'X1_Undercity_Lacuni_Boss',
    'X1_Undercity_Snake_Brute_Miniboss',
    'X1_Undercity_Lacuni',          -- substring fallback
    'Snake_Brute',
    'Ghost_Caster',
}

return kill_task.make({
    name               = 'kill_monster',
    settings           = settings,
    tracker            = tracker,
    boss_skin_patterns = UC_BOSS_PATTERNS,
    debug_label        = 'Undercity',
})
