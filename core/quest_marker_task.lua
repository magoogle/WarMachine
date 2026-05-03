-- ---------------------------------------------------------------------------
-- core/quest_marker_task.lua
--
-- Factory for a "walk to the live quest checkpoint" task.  When the
-- host has placed a TrackedCheckpoint_Marker actor in the stream
-- (= the player has an active quest with a directional objective),
-- this task drives the bot toward it.
--
-- Designed to slot into the runner BETWEEN interact_poi (catalog-
-- driven) and freeroam (random ring scoring):
--
--   exit / objectives / loot / interact_poi
--   walk_to_quest_marker   <-- this task
--   kill_monster           (preempts whenever a mob is in range)
--   freeroam               (last resort, no marker either)
--
-- The runner's priority chain stays the same -- this task only
-- claims the pulse when nothing higher had work AND a marker is
-- visible.  It stops claiming when the marker leaves stream
-- (player got close + the objective auto-completed + a new marker
-- moved to a different room out of range).
--
-- API:
--
--   local make = require 'core.quest_marker_task'
--   return make.task({
--       name = 'walk_to_quest_marker',
--       arrive_radius = 5.0,    -- stop walking once within this
--       require_zone_check = function () return true end,  -- optional gate
--   })
--
-- Per-activity wrapping:
--
--   activities/nmd/tasks/walk_to_quest_marker.lua:
--     local zone = require 'core.zone'
--     return require('core.quest_marker_task').task({
--         require_zone_check = zone.in_dungeon,
--     })
--
-- Combat coexistence:
--
-- This task does NOT yield to combat -- that's the runner's job
-- (kill_monster sits BELOW this in the priority chain, and the
-- factory inserts it AFTER kill_monster so combat preempts the
-- walk).  See activities/<name>/tasks/runner.lua for the order.
--
-- Wait -- correction.  We DO want this to run BEFORE kill_monster
-- in some sense (the marker tells us where to go; without it we
-- just stand around if no mob is in range).  The order in the
-- runner is:
--
--   ...interact_poi -> walk_to_quest_marker -> kill_monster -> freeroam
--
-- which means: "if nothing reachable to interact with, AND there's
-- a quest marker, walk toward it.  Combat preempts because
-- kill_monster runs FIRST every pulse via target.pick (which itself
-- yields when no enemy is in range), so the order works out: an
-- enemy in range fires kill_monster regardless of order.  When NO
-- enemy is in range, this task picks up and walks toward the
-- marker."
--
-- Concretely: kill_monster is BELOW this task, but kill_monster
-- only takes the pulse when an enemy is in kill_range.  When that's
-- false, this task runs.  When that's true, kill_monster runs and
-- this task waits.  Either way, the walk-to-marker resumes after
-- the kill.  The bot organically explores + fights its way toward
-- the objective.
-- ---------------------------------------------------------------------------

local move          = require 'core.move'
local quest_marker  = require 'core.quest_marker'
local reach         = require 'core.reach'

local M = {}

-- Default arrival radius -- stop driving once we're within this of
-- the marker.  D4's marker is a directional hint (often dropped
-- 5-15y from the actual objective actor), so once we're inside this
-- radius the higher-priority tasks (interact_poi, kill_monster) take
-- over automatically.
local DEFAULT_ARRIVE_M = 8.0

-- How often the task is allowed to issue a fresh move.to_pos.  The
-- walker handles continuous walking; we just need to refresh the
-- target periodically (the marker moves as the quest progresses).
local REFRESH_INTERVAL_S = 0.5

M.task = function (cfg)
    cfg = cfg or {}
    local task = {
        name           = cfg.name or 'walk_to_quest_marker',
        status         = 'idle',
        last_refresh_t = -math.huge,
    }

    local arrive_radius      = cfg.arrive_radius or DEFAULT_ARRIVE_M
    local require_zone_check = cfg.require_zone_check

    -- Returns the current marker position, or nil when there's no
    -- marker / we're already within arrive radius / a custom zone
    -- check rejects the activity.
    local function active_marker_pos()
        if require_zone_check and not require_zone_check() then return nil end
        local pos = quest_marker.position()
        if not pos then return nil end
        local lp = get_local_player()
        if not lp then return nil end
        local pp = lp:get_position()
        if not pp then return nil end
        local dx = pos:x() - pp:x()
        local dy = pos:y() - pp:y()
        if (dx * dx + dy * dy) <= (arrive_radius * arrive_radius) then
            return nil   -- already there; let other tasks claim
        end
        return pos
    end

    task.shouldExecute = function ()
        return active_marker_pos() ~= nil
    end

    task.Execute = function ()
        local pos = active_marker_pos()
        if not pos then task.status = 'no marker'; return end

        local now = (get_time_since_inject and get_time_since_inject()) or 0
        if (now - task.last_refresh_t) < REFRESH_INTERVAL_S then
            task.status = 'walking to quest marker'
            return
        end
        task.last_refresh_t = now

        -- Reachability check.  The marker's position IS reachable
        -- almost always -- the host placed it on a valid navmesh
        -- cell -- but if the host pathfinder can't route to it RIGHT
        -- NOW (closed door, partial map exposure), we want to walk
        -- toward it via freeroam exploration rather than wall-walking.
        --
        -- Strategy: if reach says yes, walk straight to the marker.
        -- If reach says no, drop to "no marker" status so freeroam
        -- (lower priority) takes over and explores -- the marker
        -- becomes reachable as the bot opens up the floor.
        local lp = get_local_player()
        local pp = lp and lp:get_position() or nil
        if pp and not reach.is_reachable(pp, pos) then
            task.status = 'marker unreachable -- exploring'
            return
        end

        local dx = pos:x() - (pp and pp:x() or 0)
        local dy = pos:y() - (pp and pp:y() or 0)
        local d  = math.sqrt(dx * dx + dy * dy)

        move.to_pos(
            { x = pos:x(), y = pos:y(), z = pos:z() },
            { arrive_radius = arrive_radius }
        )
        task.status = string.format('walking to quest marker (%.0fm)', d)
    end

    return task
end

return M
