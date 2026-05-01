-- ---------------------------------------------------------------------------
-- activities/hordes/tasks/walk_boss_room.lua
--
-- Quest-directed positioning task.  Reads the live Hordes quest objective
-- via quest_state.read_directive() and walks the bot to the right place:
--
--   directive = 'boss'   -> the Bartuc/Council boss room
--   directive = 'spire'  -> the closest Soulspire actor in stream
--                           (per user spec: "if we have soulspire
--                           objective we should be standing on the soul
--                           spire and fighting there")
--   any other directive  -> NO-OP (kill_monster handles the in-place
--                           combat for masses / hellborne / lords / etc.)
--
-- Was bug: previous implementation fired any time the bot was in a BSK
-- zone with no enemies in immediate range, which made it walk to the
-- boss room door (locked until after the final boon) between mob
-- groups.  User report: "keeps trying to walk to the boss room, hangs
-- out at the door that's locked".
--
-- kill_monster (lower priority) preempts this task whenever there's a
-- valid combat target so we don't walk past spawning waves.
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local find        = require 'core.find'
local settings    = require 'activities.hordes.settings'
local quest_state = require 'activities.hordes.quest_state'

local task = { name = 'walk_boss_room', status = 'idle' }

-- Boss room center.  Lifted from HordeDev/tasks/horde.lua's
-- horde_boss_room_position.  Will need refresh if Blizzard reshuffles
-- the BSK arena layout next season.
local BOSS_ROOM    = { x = -36.17675, y = -36.3222, z = 2.2 }
local ARRIVED_DIST = 3   -- "close enough" radius
local SPIRE_NEAR_R = 4   -- "standing on the spire" radius

local function in_hordes()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and (z:find('BSK_', 1, true) ~= nil)
end

-- Closest Soulspire enemy actor.  Substring match against `Soulspire`
-- per kill_monster.lua's is_soulspire helper.  Soulspires are enemies,
-- not allies, so we use 'all' source.
local function closest_soulspire()
    return find.closest({
        patterns             = { 'soulspire' },
        require_interactable = false,
        source               = 'all',
        filter               = function (a)
            -- Skip dead / no-HP entries.
            local hp = a.get_current_health and a:get_current_health() or 0
            return hp > 1
        end,
    })
end

-- Resolve the live "where should the bot be" target based on the quest
-- directive.  Returns:
--   { x, y, z, kind, arrive_radius, status_label }   or nil
local function resolve_objective_target()
    local directive, _text = quest_state.read_directive()

    if directive == 'spire' then
        local actor = closest_soulspire()
        if actor then
            local p = actor:get_position()
            if p then
                return {
                    x = p:x(), y = p:y(), z = p:z(),
                    kind = 'spire',
                    arrive_radius = SPIRE_NEAR_R,
                    status_label = 'walking to soulspire',
                }
            end
        end
        return nil
    end

    if directive == 'boss' or directive == 'miniboss' then
        return {
            x = BOSS_ROOM.x, y = BOSS_ROOM.y, z = BOSS_ROOM.z,
            kind = 'boss_room',
            arrive_radius = ARRIVED_DIST,
            status_label = 'walking to boss room',
        }
    end

    -- Other directives ('mass' | 'hellborne' | 'goblin' | 'lord' |
    -- 'hellseeker' | 'aether_collect' | 'aether_structure' | nil)
    -- have no positional repositioning -- kill_monster handles them by
    -- engaging in place, and interact_aether/interact_pylon handle the
    -- structure-clicks.  Don't walk anywhere.
    return nil
end

-- Are there enemies in kill_range?  If yes, defer to kill_monster.
-- (kill_monster preempts us by being lower in the runner chain only
-- if ITS shouldExecute returns true; in practice kill_monster runs
-- AFTER us in TASK_FILES order, so we explicitly check here.)
local function any_enemies_in_range()
    return find.any_enemy_in_range(settings.kill_range or 25)
end

task.shouldExecute = function ()
    if not in_hordes() then return false end
    local lp = get_local_player()
    if not lp then return false end

    -- Combat preempts repositioning.  Without this, we'd interrupt fights
    -- to walk a few yards.  kill_monster takes the pulse instead.
    if any_enemies_in_range() then return false end

    local target = resolve_objective_target()
    if not target then return false end

    local pp = lp:get_position()
    if not pp then return false end
    local dx, dy = target.x - pp:x(), target.y - pp:y()
    if math.sqrt(dx*dx + dy*dy) <= target.arrive_radius then
        return false   -- already there
    end

    -- Stash the resolved target on the task object so Execute doesn't
    -- have to re-resolve (and so the directive can't change between
    -- shouldExecute and Execute, which would be confusing).
    task._goal = target
    return true
end

task.Execute = function ()
    local goal = task._goal
    if not goal then task.status = 'no goal'; return end

    if orbwalker and orbwalker.set_clear_toggle then
        -- Travel-flavored: don't burn skills on stragglers along the way.
        orbwalker.set_clear_toggle(false)
    end

    local target = vec3:new(goal.x, goal.y, goal.z)
    move.to_pos(target, { arrive_radius = goal.arrive_radius })
    task.status = goal.status_label
end

return task
