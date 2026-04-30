-- activities/boss/tasks/open_chest.lua
--
-- After the boss dies, walk to the closest reward chest matching one of
-- boss_data.chest_patterns (EGB_Chest, Chest_Boss, Boss_WT_Belial_*,
-- S12_Prop_Theme_Chest_*) and click it.  Set tracker.chest_opened so
-- exit.lua can fire run_done.
--
-- Reaper tracks a 4-phase open-chest state machine (MAIN -> WAIT_GONE ->
-- THEME -> WAIT_COMPLETE) to also chase the seasonal Theme/DOOM chest
-- that pops up after the main boss chest.  We collapse that to "click
-- whatever reward-chest is interactable, until none remain" -- the
-- generic chest-pattern matcher catches both the EGB chest AND the
-- theme chest.

local move      = require 'core.move'
local settings  = require 'activities.boss.settings'
local tracker   = require 'activities.boss.tracker'
local boss_data = require 'activities.boss.data.boss_data'

local task = { name = 'open_chest', status = 'idle', last_click_t = nil }

local CLICK_DEBOUNCE_S = 4

local function find_closest_chest()
    if not actors_manager or not actors_manager.get_all_actors then return nil, math.huge end
    local lp = get_local_player()
    if not lp then return nil, math.huge end
    local pp = lp:get_position()
    if not pp then return nil, math.huge end
    local best, best_d = nil, math.huge
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a.is_interactable and a:is_interactable() and boss_data.is_reward_chest(a) then
            local p = a:get_position()
            if p then
                local d = math.sqrt((p:x()-pp:x())^2 + (p:y()-pp:y())^2)
                if d < best_d then best, best_d = a, d end
            end
        end
    end
    return best, best_d
end

task.shouldExecute = function ()
    if not settings.do_chests then return false end
    return find_closest_chest() ~= nil
end

task.Execute = function ()
    local now = get_time_since_inject() or 0
    if task.last_click_t and (now - task.last_click_t) < CLICK_DEBOUNCE_S then
        task.status = 'waiting for chest VFX'
        return
    end
    local chest, d = find_closest_chest()
    if not chest then task.status = 'no chest'; return end
    if d <= 3 then
        if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
        interact_object(chest)
        task.last_click_t = now
        tracker.chest_opened   = true
        tracker.chest_opened_t = now
        if settings.debug_mode then
            console.print('[Boss] opened chest ' .. tostring(chest:get_skin_name()))
        end
        task.status = 'opened ' .. tostring(chest:get_skin_name())
        return
    end
    move.to_actor(chest)
    task.status = string.format('walking to chest (%.0fm)', d)
end

return task
