-- activities/nmd/tasks/walk_to_quest_marker.lua
--
-- Walk toward the live quest checkpoint marker.  D4 places a
-- TrackedCheckpoint_Marker actor at the current quest objective
-- (the same pulsing marker the player sees on the minimap).  Even
-- when WarPath has no catalog data for this dungeon, the marker
-- gives us a directional hint so the bot doesn't just ring-explore
-- aimlessly.
--
-- The marker moves as the quest advances ("Slay the Aldurkin: 1" ->
-- next room when killed -> "Travel to Moon Scryer's Glade" -> moves
-- to the Glade).  We walk toward the current position; the runner
-- chain handles combat preemption -- kill_monster is HIGHER priority
-- than this task, so any mob within kill_range pulls us off the walk
-- to fight, then we resume walking toward the (possibly updated)
-- marker.
--
-- See core/quest_marker_task.lua for the factory + design notes.

local zone = require 'core.zone'

return require('core.quest_marker_task').task({
    name               = 'walk_to_quest_marker',
    -- Only inside dungeon zones -- in town the marker often sits at
    -- the entrance NPC and we don't want to charge at vendor NPCs.
    require_zone_check = function () return zone.in_dungeon() end,
    -- 8y arrival radius -- D4's marker is a coarse hint, often
    -- dropped near (not on) the objective actor.  Inside 8y we let
    -- interact_poi / kill_monster take over.
    arrive_radius      = 8.0,
})
