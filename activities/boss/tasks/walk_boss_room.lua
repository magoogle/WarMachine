-- activities/boss/tasks/walk_boss_room.lua
--
-- Anchor: when the altar's been activated but no enemy is in stream
-- AND no reward chest is visible, walk back toward the boss-room center
-- (boss_data.get_anchor for the current zone).  This keeps the bot
-- inside the arena instead of drifting to wherever it landed.
--
-- Same role as activities/hordes/tasks/walk_boss_room but for the
-- boss-altar zones.  Lower priority than kill_monster -- combat
-- preempts -- so this only fires in the brief gap between altar-click
-- and the first wave of boss adds spawning.

local move      = require 'core.move'
local settings  = require 'activities.boss.settings'
local tracker   = require 'activities.boss.tracker'
local boss_data = require 'activities.boss.data.boss_data'

local task = { name = 'walk_boss_room', status = 'idle' }

local function any_chest_visible()
    if not actors_manager or not actors_manager.get_all_actors then return false end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a.is_interactable and a:is_interactable() and boss_data.is_reward_chest(a) then
            return true
        end
    end
    return false
end

local function any_enemy_in_range()
    if not target_selector or not target_selector.get_near_target_list then return false end
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end
    local enemies = target_selector.get_near_target_list(pp, settings.kill_range)
    return enemies and next(enemies) ~= nil
end

task.shouldExecute = function ()
    if not tracker.altar_activated then return false end
    if any_chest_visible()         then return false end
    if any_enemy_in_range()        then return false end
    -- Only useful when we have a known anchor for this zone.
    local w = get_current_world()
    local zone = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    return boss_data.get_anchor(zone) ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local w = get_current_world()
    local zone = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    local anchor = boss_data.get_anchor(zone)
    if not anchor then task.status = 'no anchor'; return end
    local pp = lp:get_position()
    local d  = math.sqrt((anchor.x-pp:x())^2 + (anchor.y-pp:y())^2)
    -- Already at anchor (within tether range)
    if d <= settings.boss_room_tether then
        task.status = string.format('at anchor (%.0fm)', d)
        return
    end
    move.to_pos(vec3:new(anchor.x, anchor.y, anchor.z or pp:z()))
    task.status = string.format('walking to boss-room anchor (%.0fm)', d)
end

return task
