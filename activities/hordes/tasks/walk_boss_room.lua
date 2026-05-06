-- ---------------------------------------------------------------------------
-- activities/hordes/tasks/walk_boss_room.lua
--
-- Quest-directed positioning task for Infernal Hordes.
--
-- Priority of "where should the bot be" while no enemy is in kill_range:
--
--   1. Quest directive 'spire'  -> walk to the closest live Soulspire
--      ("stay near the soulspire" / "destroy the soulspires" objectives).
--      kill_monster handles the actual destruction; this task just gets
--      us within fighting range.
--
--   2. Quest directive 'boss'/'miniboss' AFTER the wave loop has finished
--      (locked-door latch seen in tracker)  ->  walk to the boss room.
--      The latch is the canonical "waves are done" signal -- mirrors
--      HordeDev's tracker.locked_door_found.  Without it, the parser
--      sometimes flags the directive as 'boss' from the very start of
--      the run (the host returns the final Council/Bartuc objective
--      alongside the active wave objective and our matcher trips on the
--      boss noun first), which is what made the bot try to run straight
--      to the boss room as soon as it joined.
--
--   3. Default  ->  anchor the bot at the wave-arena center so it stays
--      in the fight zone instead of wandering off to chase whatever
--      happens to be the nearest enemy at the edge of the arena.  Same
--      center coordinates HordeDev uses (horde_center_position).
--
-- kill_monster (lower priority in the runner) preempts whenever there's
-- a valid combat target, so this task only fires in the brief gaps
-- between waves / while we're already at the anchor and idle.
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local find        = require 'core.find'
local settings    = require 'activities.hordes.settings'
local tracker     = require 'activities.hordes.tracker'
local quest_state = require 'activities.hordes.quest_state'

local task = { name = 'walk_boss_room', status = 'idle' }

-- Boss room center.  Lifted from HordeDev/tasks/horde.lua's
-- horde_boss_room_position.
local BOSS_ROOM     = { x = -36.17675, y = -36.3222,  z = 2.2 }
-- Wave-arena center (HordeDev's horde_center_position).  This is where
-- the bot anchors during waves -- spawns happen all around this point.
local ARENA_CENTER  = { x =   9.20410, y =   8.91504, z = 0.0 }
local ARRIVED_DIST  = 3   -- "close enough" radius for fixed positions
local SPIRE_NEAR_R  = 4   -- "standing on the spire" radius
local ARENA_HOLD_R  = 12  -- ok to be anywhere within this of arena center

-- Locked-door skin patterns.  The presence of BSK_MapIcon_LockedDoor
-- means the wave loop has finished and the door (currently locked) has
-- spawned.  The Sigil_Ancients_Zak_Evil door, when present, signals
-- "still in a wave"; if either it OR no map-icon is present, waves are
-- not yet done.
local LOCKED_DOOR_ICON  = 'BSK_MapIcon_LockedDoor'
local IN_WAVE_DOOR_SKIN = 'DGN_Standard_Door_Lock_Sigil_Ancients_Zak_Evil'

local function in_hordes()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and (z:find('BSK_', 1, true) ~= nil)
end

-- Scan the live actor stream for the locked-door / in-wave indicators.
-- Latches tracker.locked_door_seen the moment we observe "door visible
-- AND not in a wave".  Once latched, never unset for this run -- the
-- door persists until the player clicks it (interact_boss_portal),
-- after which we're past the gate anyway.
local function update_door_latch()
    if tracker.locked_door_seen then return true end
    if not actors_manager or not actors_manager.get_all_actors then return false end
    local has_icon, has_in_wave = false, false
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if sn == LOCKED_DOOR_ICON  then has_icon = true end
        if sn == IN_WAVE_DOOR_SKIN then has_in_wave = true end
    end
    if has_icon and not has_in_wave then
        tracker.locked_door_seen = true
        if settings.debug_mode then
            console.print('[Hordes] locked-door latch flipped -- waves complete')
        end
        return true
    end
    return false
end

-- Closest live Soulspire enemy.  Soulspires live in the enemy actor
-- stream (they have HP); skin is "Soulspire*" with various seasonal
-- prefixes.  HordeDev uses `name:match("Soulspire")` -- mirrored here.
local function closest_soulspire()
    return find.closest({
        patterns             = { 'soulspire' },
        require_interactable = false,
        source               = 'all',
        filter               = function (a)
            local hp = a.get_current_health and a:get_current_health() or 0
            return hp > 1
        end,
    })
end

-- Resolve the "where should the bot be" target based on the live quest
-- directive + door latch.  Returns:
--   { x, y, z, kind, arrive_radius, status_label }   or nil
local function resolve_target()
    local directive = quest_state.read_directive()

    if directive == 'spire' then
        local actor = closest_soulspire()
        if actor then
            local p = actor:get_position()
            if p then
                return {
                    x = p:x(), y = p:y(), z = p:z(),
                    kind = 'spire',
                    arrive_radius = SPIRE_NEAR_R,
                    status_label  = 'walking to soulspire',
                }
            end
        end
        -- Spire directive but no live spire in stream -- fall through
        -- to arena anchor so we don't drift off chasing other things.
    end

    -- Boss-room walk gated on the locked-door latch.  Without this gate
    -- the misparsed-directive case ("boss" returned at run start before
    -- the wave loop even begins) sent the bot running through the arena
    -- toward the still-locked door.
    --
    -- Note: 'miniboss' directive is NOT routed here.  In hordes the only
    -- "bosses" in the boss-room sense are the three Council members and
    -- Bartuc; minibosses ("Defeat 1 Miniboss" wave objectives) refer to
    -- BSK_Miniboss / BSK_*_boss script-spawn enemies in the WAVE arena.
    -- Minibosses are handled by kill_monster's tier-1 directive match
    -- where they are -- routing them to BOSS_ROOM would walk the bot
    -- away from the actual fight.
    if directive == 'boss' and tracker.locked_door_seen then
        return {
            x = BOSS_ROOM.x, y = BOSS_ROOM.y, z = BOSS_ROOM.z,
            kind = 'boss_room',
            arrive_radius = ARRIVED_DIST,
            status_label  = 'walking to boss room',
        }
    end

    -- Default: anchor at the wave-arena center.  Returning ARENA_CENTER
    -- here (instead of nil) is the fix for "bot just runs around
    -- between waves" -- it now actively re-anchors instead of letting
    -- whatever last move target win.
    return {
        x = ARENA_CENTER.x, y = ARENA_CENTER.y, z = ARENA_CENTER.z,
        kind = 'arena_center',
        arrive_radius = ARENA_HOLD_R,
        status_label  = 'holding wave arena',
    }
end

local function any_enemies_in_range()
    return find.any_enemy_in_range(settings.kill_range or 25)
end

task.shouldExecute = function ()
    if not in_hordes() then return false end
    local lp = get_local_player()
    if not lp then return false end

    -- Refresh the wave-completion latch every pulse (cheap; a single
    -- skin-name scan over the live actor list).
    update_door_latch()

    -- Combat preempts.  kill_monster (lower in the runner chain) takes
    -- the pulse whenever something is killable in range.
    if any_enemies_in_range() then return false end

    local target = resolve_target()
    if not target then return false end

    local pp = lp:get_position()
    if not pp then return false end
    local dx, dy = target.x - pp:x(), target.y - pp:y()
    if math.sqrt(dx*dx + dy*dy) <= target.arrive_radius then
        return false   -- already there; nothing to do
    end

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

    move.to_pos(vec3:new(goal.x, goal.y, goal.z),
                { arrive_radius = goal.arrive_radius })
    task.status = goal.status_label
end

return task
