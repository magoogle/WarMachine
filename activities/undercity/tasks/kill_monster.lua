-- activities/undercity/tasks/kill_monster.lua  --  reactive combat.

local move          = require 'core.move'
local target_module = require 'core.target'
local settings      = require 'activities.undercity.settings'
local tracker       = require 'activities.undercity.tracker'

local UC_BOSS_PATTERNS = {
    'S11_Andariel_Boss_KUC',
    'X1_Undercity_Ghost_Caster_Miniboss',
    'X1_Undercity_Lacuni_Boss',
    'X1_Undercity_Snake_Brute_Miniboss',
    'X1_Undercity_Lacuni',          -- substring fallback
    'Snake_Brute',
    'Ghost_Caster',
}

local function looks_like_boss(skin)
    if not skin then return false end
    for _, p in ipairs(UC_BOSS_PATTERNS) do
        if skin:find(p, 1, true) then return true end
    end
    return false
end

local task = { name = 'kill_monster', status = 'idle' }

-- Tiered selection: boss > elite/champion > everything else, closest
-- within tier.  Shared with NMD / Pit via core/target.lua.
local function pick_target()
    return target_module.pick({ range = settings.kill_range })
end

task.shouldExecute = function ()
    if not settings.kill_monsters then return false end
    return pick_target() ~= nil
end

task.Execute = function ()
    local enemy = pick_target()
    if not enemy then task.status = 'idle'; return end
    local skin = enemy:get_skin_name() or ''
    if (target_module.is_boss(enemy) or looks_like_boss(skin)) and not tracker.boss_seen then
        tracker.boss_seen = true
        if settings.debug_mode then
            console.print('[Undercity] boss seen: ' .. tostring(skin))
        end
    end
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    -- In-range short-circuit -- see core/target.lua's IN_RANGE_DEFAULT.
    if target_module.distance_to(enemy) <= target_module.IN_RANGE_DEFAULT then
        move.clear()
        task.status = 'in-range: ' .. tostring(skin)
        return
    end
    move.to_actor(enemy)
    task.status = 'engaging ' .. tostring(skin)
end

return task
