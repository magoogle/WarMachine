-- activities/boss/tasks/kill_monster.lua
--
-- Engage enemies once the altar's been activated (boss summoned).
-- Thin wrapper over core.kill_task with two boss-specific hooks:
--
--   extra_should  : only fires after altar_activated AND when no
--                   reward chest is visible (otherwise we'd keep
--                   fighting past the kill).
--   target_hijack : monsterAffix_suppressor_barrier orbs gate damage
--                   on nearby enemies; when one is up, drop everything
--                   and chase it.
--
-- Was 77 lines of custom shouldExecute/Execute; the hooks now express
-- the same behavior in 15.

local kill_task = require 'core.kill_task'
local settings  = require 'activities.boss.settings'
local tracker   = require 'activities.boss.tracker'
local boss_data = require 'activities.boss.data.boss_data'

local function find_suppressor()
    if not actors_manager or not actors_manager.get_all_actors then return nil end
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if sn == boss_data.suppressor_skin then return a end
    end
    return nil
end

local function any_reward_chest_visible()
    if not actors_manager or not actors_manager.get_all_actors then return false end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a.is_interactable and a:is_interactable() and boss_data.is_reward_chest(a) then
            return true
        end
    end
    return false
end

return kill_task.make({
    name          = 'kill_monster',
    settings      = settings,
    tracker       = tracker,
    extra_should  = function ()
        if not tracker.altar_activated   then return false end
        if any_reward_chest_visible()    then return false end
        return true
    end,
    target_hijack = find_suppressor,
    debug_label   = 'Boss',
})
