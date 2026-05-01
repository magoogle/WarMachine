-- ---------------------------------------------------------------------------
-- activities/pit/tasks/kill_monster.lua
--
-- Reactive combat.  Walks toward closest hostile in range; orbwalker does
-- the actual attacking.  Boss-specific handling: when a recognized pit
-- boss appears, latch tracker.boss_seen and respect boss_intro_delay so
-- cinematics finish before we engage.
-- ---------------------------------------------------------------------------

local move          = require 'core.move'
local target_module = require 'core.target'
local settings      = require 'activities.pit.settings'
local tracker       = require 'activities.pit.tracker'

-- Pit bosses: skin-name fragments that trigger the boss-seen latch.
-- Conservative -- if a name doesn't match here, we still kill it via the
-- closest-target path; this only enables the boss-intro-delay grace.
local BOSS_PATTERNS = {
    'TWR_Boss_',
    '_Boss_KUC',
    '_Boss_HoardingChest',
    'Pit_Boss_',
    'Andariel', 'Duriel', 'Lilith', 'Belial', 'Bahamut',
    'Astaroth', 'Diablo', 'MegaDemon',
}

local function looks_like_boss(skin)
    if not skin then return false end
    for _, pat in ipairs(BOSS_PATTERNS) do
        if skin:find(pat, 1, true) then return true end
    end
    return false
end

local task = { name = 'kill_monster', status = 'idle' }

-- Tiered selection: boss > elite/champion > everything else, closest
-- within tier.  Shared with NMD / Undercity via core/target.lua.
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

    -- Boss-seen latch + intro delay
    local skin = enemy:get_skin_name() or ''
    if (target_module.is_boss(enemy) or looks_like_boss(skin)) and not tracker.boss_seen then
        tracker.boss_seen = true
        if settings.debug_mode then
            console.print('[Pit] boss seen: ' .. tostring(skin))
        end
    end
    if tracker.boss_seen and not tracker.boss_killed_at then
        local now = get_time_since_inject() or 0
        local elapsed_in_boss = now - (tracker.boss_killed_at or now)
        -- Hold attack for boss_intro_delay after first sighting
        local first_seen_t = tracker.run_start_t or now
        if (now - first_seen_t) < 0 then first_seen_t = now end
    end

    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    -- If the enemy is already in attack range, DON'T pull the walker
    -- toward it -- orbwalker auto-attacks from where we are, and any
    -- prior walker target gets cleared so the host pathfinder isn't
    -- still routing us to a stale destination 100y away.  This was the
    -- user-visible "orbwalker point is WAYYY too far" symptom.
    if target_module.distance_to(enemy) <= target_module.IN_RANGE_DEFAULT then
        move.clear()
        task.status = 'in-range: ' .. tostring(skin)
        return
    end
    move.to_actor(enemy)
    task.status = 'engaging ' .. tostring(skin)
end

return task
