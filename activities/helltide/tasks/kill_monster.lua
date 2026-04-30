-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/kill_monster.lua
--
-- Fallback combat -- only fires when nothing's in the POI queue (which is
-- rare during an active helltide).  Reactive walk-to-target so orbwalker
-- can do its thing.  Heavier combat happens passively while interact_poi
-- walks toward the next objective.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local settings = require 'activities.helltide.settings'

local task = { name = 'kill_monster', status = 'idle' }

local function pick_target()
    local lp = get_local_player()
    if not lp then return nil end
    local pp = get_player_position and get_player_position() or lp:get_position()
    if not pp then return nil end
    if not target_selector or not target_selector.get_near_target_list then return nil end
    local enemies = target_selector.get_near_target_list(pp, settings.kill_range)
    local closest, closest_d
    local boss, boss_d
    for _, e in pairs(enemies or {}) do
        if e:get_current_health() and e:get_current_health() > 1 then
            local ep = e:get_position()
            if ep then
                local dx = ep:x() - pp:x()
                local dy = ep:y() - pp:y()
                local d  = math.sqrt(dx*dx + dy*dy)
                if d <= settings.kill_range then
                    if e:is_boss() and (not boss_d or d < boss_d) then
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
    return pick_target() ~= nil
end

task.Execute = function ()
    local target = pick_target()
    if not target then task.status = 'idle'; return end
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    move.to_actor(target)
    task.status = 'engaging ' .. tostring(target:get_skin_name() or '?')
end

return task
