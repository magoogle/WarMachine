-- activities/nmd/tasks/runner.lua
--
-- Thin config-only runner.  Task list + freeroam fallback are wired
-- up by core.runner.make().

local runner = require 'core.runner'

return runner.make({
    activity    = 'nmd',
    module_path = 'activities.nmd.tasks',
    tracker     = require 'activities.nmd.tracker',
    settings    = require 'activities.nmd.settings',
    task_files  = {
        'select_dungeon',     -- standalone-only: consume a Nightmare Sigil
                              -- in town to open the next dungeon.  No-op
                              -- in WarPlan mode (WarPlan owns transit).
        'exit',               -- TP back to town once boss + chest done.
        'campfire_event',     -- ACD_ME_* Map Event: walk to + click campfire
                              -- (or similar) to start the event.  Yields to
                              -- ambush once the survive phase begins.
        'ambush',             -- LE_Ambush sub-event: speak to survivors,
                              -- hold anchor during waves.
        'cursed_shrine',      -- Click cursed-shrine sub-event when
                              -- settings.do_cursed_shrines is on.
        'carry_objective',    -- "Carry the X to the pedestal" gating
                              -- mechanic.  Yields to immediate combat
                              -- (kill_monster within 8y).
        'loot_chest',         -- Live-stream chest grab.  Runs BEFORE
                              -- interact_poi because Horadric chests
                              -- aren't yet in the catalog.
        'interact_poi',       -- Catalog-driven POI clicker.
        'kill_monster',       -- Fallback combat.  HIGHER priority than
                              -- walk_to_quest_marker so any mob within
                              -- kill_range preempts the marker walk --
                              -- the bot kills mobs along the way and
                              -- resumes walking afterward, exactly the
                              -- "explore + kill + arrive" loop the
                              -- objective progression wants.
        'seek_boss_room',     -- Once objectives are complete + boss not
                              -- yet seen, route to a remembered
                              -- Healing_Well_Basic position.  Wells in
                              -- NMD floors typically anchor sealed
                              -- boss-room doors that unseal on objective
                              -- complete -- the well is the closest
                              -- pre-known waypoint to the new path.
        'walk_to_quest_marker', -- Walk toward D4's live quest checkpoint
                                -- marker (TrackedCheckpoint_Marker
                                -- actor).  Gives the bot a directional
                                -- hint even in zones with no WarPath
                                -- catalog data.  See core/quest_marker
                                -- + core/quest_marker_task.lua.
        'boss_room_hold',     -- Anchor inside the arena once boss seen.
        'idle',
    },
    -- freeroam (default true) auto-inserts the embedded explorer
    -- before idle.  debug_idle off here -- the runner stays quiet.
})
