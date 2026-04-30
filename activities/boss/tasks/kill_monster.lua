-- activities/boss/tasks/kill_monster.lua
--
-- Engage enemies once the altar's been activated (boss is summoned).
-- Same shape as helltide/kill_monster but gated on tracker.altar_activated
-- and no reward-chest visible (otherwise we'd keep "fighting" past the
-- end of the kill).
--
-- Suppressor priority: Reaper chases monsterAffix_suppressor_barrier
-- orbs unconditionally because they block all damage to nearby enemies.
-- Mirrored here.

local move      = require 'core.move'
local settings  = require 'activities.boss.settings'
local tracker   = require 'activities.boss.tracker'
local boss_data = require 'activities.boss.data.boss_data'

local task = { name = 'kill_monster', status = 'idle' }

local function find_suppressor()
    if not actors_manager or not actors_manager.get_all_actors then return nil end
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if sn == boss_data.suppressor_skin then return a end
    end
    return nil
end

local function any_chest_visible()
    if not actors_manager or not actors_manager.get_all_actors then return false end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a.is_interactable and a:is_interactable() and boss_data.is_reward_chest(a) then
            return true
        end
    end
    return false
end

local function pick_enemy()
    if not target_selector or not target_selector.get_near_target_list then return nil end
    local lp = get_local_player()
    if not lp then return nil end
    local pp = lp:get_position()
    if not pp then return nil end
    local enemies = target_selector.get_near_target_list(pp, settings.kill_range)
    local boss, boss_d, closest, closest_d
    for _, e in pairs(enemies or {}) do
        local hp = e.get_current_health and e:get_current_health() or 0
        if hp > 1 then
            local ep = e:get_position()
            if ep then
                local d = math.sqrt((ep:x()-pp:x())^2 + (ep:y()-pp:y())^2)
                if d <= settings.kill_range then
                    if e.is_boss and e:is_boss() and (not boss_d or d < boss_d) then
                        boss, boss_d = e, d
                    end
                    if not closest_d or d < closest_d then
                        closest, closest_d = e, d
                    end
                end
            end
        end
    end
    return boss or closest
end

task.shouldExecute = function ()
    if not settings.kill_monsters then return false end
    if not tracker.altar_activated then return false end
    if any_chest_visible()         then return false end
    -- Suppressor is always a yes (gates all damage when present)
    if find_suppressor()           then return true end
    return pick_enemy() ~= nil
end

task.Execute = function ()
    if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(true) end

    -- Suppressor takes priority -- chase + burst it before anything else
    local sup = find_suppressor()
    if sup then
        move.to_actor(sup)
        task.status = 'chasing suppressor'
        return
    end

    local target = pick_enemy()
    if not target then task.status = 'idle'; return end
    move.to_actor(target)
    task.status = 'engaging ' .. tostring(target.get_skin_name and target:get_skin_name() or '?')
end

return task
