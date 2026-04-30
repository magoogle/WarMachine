-- activities/nmd/tasks/kill_monster.lua

local move     = require 'core.move'
local settings = require 'activities.nmd.settings'
local tracker  = require 'activities.nmd.tracker'

local task = { name = 'kill_monster', status = 'idle' }

local function pick_target()
    local lp = get_local_player()
    if not lp then return nil end
    local pp = get_player_position and get_player_position() or lp:get_position()
    if not pp then return nil end
    if not target_selector or not target_selector.get_near_target_list then return nil end
    local enemies = target_selector.get_near_target_list(pp, settings.kill_range)
    local boss, boss_d
    local closest, closest_d
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
    local skin = target:get_skin_name() or ''
    if target:is_boss() and not tracker.boss_seen then
        tracker.boss_seen = true
        if settings.debug_mode then console.print('[NMD] boss seen: ' .. skin) end
    end
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    move.to_actor(target)
    task.status = 'engaging ' .. skin
end

return task
