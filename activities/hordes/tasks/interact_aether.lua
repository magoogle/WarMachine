-- activities/hordes/tasks/interact_aether.lua
--
-- Walks to BSK_Structure_BonusAether spawns (mid-wave aether-bonus
-- structures).  These need the player to stand close to grant the bonus
-- aether; killing them is also worth it.  We treat them as walk-and-engage
-- targets.

local move     = require 'core.move'
local settings = require 'activities.hordes.settings'

local task = { name = 'interact_aether', status = 'idle' }

local function find_aether()
    if not actors_manager then return nil end
    local lp = get_local_player()
    if not lp then return nil end
    local pp = lp:get_position()
    local best, best_d = nil, math.huge
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a:get_skin_name() or ''
        if sn:find('BSK_Structure_BonusAether', 1, true) then
            local p = a:get_position()
            if p and pp then
                local d = (p:x()-pp:x())^2 + (p:y()-pp:y())^2
                if d < best_d then best, best_d = a, d end
            end
        end
    end
    return best
end

task.shouldExecute = function ()
    if not settings.do_aether_structures then return false end
    return find_aether() ~= nil
end

task.Execute = function ()
    local target = find_aether()
    if not target then task.status = 'idle'; return end
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    move.to_actor(target)
    task.status = 'walking to aether structure'
end

return task
