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
        'post_boss_grace',    -- detect boss kill, hold position briefly
                              -- for loot pickup (sets boss_killed_at).
                              -- Must run BEFORE upgrade_glyph so we
                              -- loot the boss-death spot before
                              -- walking off to the glyph stone.
        'upgrade_glyph',      -- post-boss glyph UI sequence (final floor)
        'cross_traversal',    -- force-walk + interact across cliff
                              -- climbs / jumps / slides when the
                              -- pathfinder rejects the goal.  Runs
                              -- BEFORE floor_portal so the bot can
                              -- reach a portal sitting across a cliff.
        'floor_portal',       -- descend via PortalSwitch / floor portal
        'shortcut_portal',    -- Charon's bonus loot room (grab before fighting)
        'kill_monster',       -- main combat loop
        'push_monsters',      -- cluster-pull distant mobs into AOE
                              -- range when the local pack is too
                              -- thin to be worth fighting in place.
                              -- Lower priority than kill_monster so
                              -- nearby mobs get engaged first.  Off
                              -- by default; user opts in via the
                              -- `push_mode` setting.
        'seek_progression',   -- catalog-driven walk to closest
                              -- unvisited floor-portal / exit-switch
                              -- when no enemies in range
        'enter_pit',          -- standalone: open the pit portal in town
        'idle',
    },
})
