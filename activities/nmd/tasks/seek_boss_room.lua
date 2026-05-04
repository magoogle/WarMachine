-- ---------------------------------------------------------------------------
-- activities/nmd/tasks/seek_boss_room.lua
--
-- Healing-well-anchored boss-door finder.
--
-- Healing_Well_Basic actors in NMD floors normally spawn next to sealed
-- boss-room doors.  tracker.scan_healing_wells (called every pulse from
-- nmd/api.lua) maintains the position list as wells come into actor
-- stream.  Once the active NMD quest's objectives are all complete and
-- the boss hasn't been spotted yet, we pick the closest unvisited well
-- and walk there -- when we arrive, the previously-sealed door is
-- (typically) now walkable, the explorer's frontier expands into the
-- arena, and kill_monster / boss_room_hold takes over.
--
-- This task sits ABOVE walk_to_quest_marker in the runner so it preempts
-- the marker walk on objective-complete (the marker may still point into
-- a still-locked area; the well is a closer-to-action anchor we know
-- about).  It defers to combat (kill_monster runs first) and never fires
-- once the boss has been seen.
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local zone        = require 'core.zone'
local find        = require 'core.find'
local tracker     = require 'activities.nmd.tracker'
local quest_state = require 'activities.nmd.quest_state'

local task = { name = 'seek_boss_room', status = 'idle' }

local ARRIVE_RADIUS = 8.0   -- consider the well "reached" within this
local KILL_RANGE    = 25.0

-- Returns the closest unvisited well + its distance, or nil.
local function pick_well(pp)
    local best, best_d2 = nil, math.huge
    for _, w in ipairs(tracker.healing_wells or {}) do
        if not w.visited then
            local dx = (w.x or 0) - pp:x()
            local dy = (w.y or 0) - pp:y()
            local d2 = dx*dx + dy*dy
            if d2 < best_d2 then
                best, best_d2 = w, d2
            end
        end
    end
    if not best then return nil, math.huge end
    return best, math.sqrt(best_d2)
end

task.shouldExecute = function ()
    if not zone.in_dungeon() then return false end
    if tracker.boss_seen then return false end
    if find.any_enemy_in_range(KILL_RANGE) then return false end
    -- Only fire once the dungeon's objectives are all complete.  Until
    -- then, the regular interact_poi / walk_to_quest_marker chain is
    -- driving toward objective POIs and we shouldn't preempt.
    local q = quest_state.read_active()
    if not q or not q.all_complete then return false end
    -- Need at least one unvisited well to head toward.
    if not tracker.healing_wells or #tracker.healing_wells == 0 then return false end
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end
    return pick_well(pp) ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local well, d = pick_well(pp)
    if not well then task.status = 'no unvisited wells'; return end

    if d <= ARRIVE_RADIUS then
        -- Arrived -- mark visited so we cycle to the next well next pulse
        -- if the boss room isn't immediately findable from here.  The
        -- explorer / kill_monster pipeline takes over to push into the
        -- now-unsealed area.
        well.visited = true
        task.status = 'at well, exploring boss area'
        return
    end

    move.to_pos({ x = well.x, y = well.y, z = well.z },
                { arrive_radius = ARRIVE_RADIUS })
    task.status = string.format('walking to well (%.0fm)', d)
end

return task
