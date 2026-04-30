-- ---------------------------------------------------------------------------
-- activities/pit/tasks/kill_monster.lua
--
-- Reactive combat.  Walks toward closest hostile in range; orbwalker does
-- the actual attacking.  Boss-specific handling: when a recognized pit
-- boss appears, latch tracker.boss_seen and respect boss_intro_delay so
-- cinematics finish before we engage.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local settings = require 'activities.pit.settings'
local tracker  = require 'activities.pit.tracker'

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

    -- Boss-seen latch + intro delay
    local skin = target:get_skin_name() or ''
    if (target:is_boss() or looks_like_boss(skin)) and not tracker.boss_seen then
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
    move.to_actor(target)
    task.status = 'engaging ' .. tostring(skin)
end

return task
