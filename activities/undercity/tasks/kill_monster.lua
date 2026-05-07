-- activities/undercity/tasks/kill_monster.lua
--
-- Reactive combat for the Undercity.  Thin wrapper over core.kill_task
-- with undercity-specific boss-seen patterns.

local kill_task = require 'core.kill_task'
local settings  = require 'activities.undercity.settings'
local tracker   = require 'activities.undercity.tracker'

-- Floor-boss skin patterns: only the FINAL floor's boss should trigger
-- the boss_seen latch (which shuts down enticements / POI / descent).
-- Miniboss-class wave spawns (Dreg_caster_miniboss, etc.) get matched
-- positively here but EXCLUDED via UC_NON_BOSS_PATTERNS below -- D4
-- flags them as is_boss()=true, and without the negative pattern the
-- first wave miniboss permanently kills the rest of the floor's
-- enticement work.  Live log: clicked hearth #1, miniboss spawned
-- from the wave, boss_seen=true, interact_enticement died, nav stayed
-- paused, bot stuck.
local UC_BOSS_PATTERNS = {
    'S11_Andariel_Boss_KUC',
    'X1_Undercity_Lacuni_Boss',
    'Lacuni_Boss',                -- substring fallback for the floor boss
}

-- Skin substrings that EXCLUDE an actor from the boss_seen latch even
-- when is_boss()=true.  Captured live: Dreg_caster_miniboss appears
-- as is_boss=true on undercity floors and used to falsely fire the
-- floor-boss latch.
local UC_NON_BOSS_PATTERNS = {
    'Miniboss',
    'miniboss',
    '_Miniboss',
}

return kill_task.make({
    name                        = 'kill_monster',
    settings                    = settings,
    tracker                     = tracker,
    boss_skin_patterns          = UC_BOSS_PATTERNS,
    boss_skin_negative_patterns = UC_NON_BOSS_PATTERNS,
    debug_label                 = 'Undercity',
})
