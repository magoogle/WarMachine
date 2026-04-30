-- activities/hordes/tasks/walk_boss_room.lua
--
-- After clicking the Bartuc/Council portal the player teleports into the
-- boss arena.  The boss takes a couple seconds to spawn -- during that
-- window kill_monster has no targets and the bot stops moving.  This task
-- fires whenever we're in a BSK zone with NO targets, NO pylon, NO portal
-- in range, and walks toward the known boss-room center.  Once the boss
-- spawns, kill_monster picks it up (kill_range=60 covers the room).
--
-- Coords are lifted from HordeDev/tasks/horde.lua's horde_boss_room_position.
-- Same map this season; will need a refresh if Blizzard reshuffles the
-- BSK arena layout.

local move     = require 'core.move'
local settings = require 'activities.hordes.settings'

local task = { name = 'walk_boss_room', status = 'idle' }

-- HordeDev's horde_boss_room_position (vec3:new(-36.17675, -36.3222, 2.2))
local BOSS_ROOM = { x = -36.17675, y = -36.3222, z = 2.2 }
local ARRIVED_DIST = 3      -- "close enough" radius

-- Cheap pre-check: are we in a BSK zone?  (Avoids importing tracker.)
local function in_hordes()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and (z:find('BSK_', 1, true) ~= nil)
end

-- Are there any enemies in kill_range?  If yes, skip -- kill_monster takes
-- priority.  We use the same target_selector as kill_monster.
local function any_enemies_in_range(pp)
    if not target_selector or not target_selector.get_near_target_list then
        return false
    end
    local enemies = target_selector.get_near_target_list(pp, settings.kill_range)
    for _, e in pairs(enemies or {}) do
        local hp = e.get_current_health and e:get_current_health() or 0
        if hp > 1 then return true end
    end
    return false
end

task.shouldExecute = function ()
    if not in_hordes() then return false end
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end

    -- Already at the boss room?  No work to do.
    local dx = BOSS_ROOM.x - pp:x()
    local dy = BOSS_ROOM.y - pp:y()
    if math.sqrt(dx*dx + dy*dy) <= ARRIVED_DIST then return false end

    -- Anything to fight?  Let kill_monster handle it.
    if any_enemies_in_range(pp) then return false end

    return true
end

task.Execute = function ()
    if orbwalker and orbwalker.set_clear_toggle then
        -- Travel-flavored, not engagement -- pause clear toggle so we don't
        -- waste skills on stragglers along the way.
        orbwalker.set_clear_toggle(false)
    end
    local target = vec3:new(BOSS_ROOM.x, BOSS_ROOM.y, BOSS_ROOM.z)
    -- core/move.lua's to_pos(goal, opts) reads opts.arrive_radius; passing
    -- a bare number (which most other tasks do) silently falls back to
    -- DEFAULT_ARRIVE.  Pass it correctly so the bot stops exactly where
    -- we want.
    move.to_pos(target, { arrive_radius = ARRIVED_DIST })
    task.status = 'walking to boss room'
end

return task
