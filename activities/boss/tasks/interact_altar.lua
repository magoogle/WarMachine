-- activities/boss/tasks/interact_altar.lua
--
-- Walk to the boss-summon altar and click it.  Skin matched against
-- boss_data.altar_skin_set (any of the 13 known altar skins).  A
-- successful click manifests as the altar actor disappearing from the
-- stream within 2-3 frames; we set tracker.altar_activated when we
-- detect that transition.  Until then we keep clicking on a 2s
-- cooldown (matches Reaper's INTERACT_COOLDOWN).
--
-- Recovery: if altar_activated has been true for > settings.altar_stuck_secs
-- and no reward chest has appeared, something went wrong -- reset_run
-- and (in standalone mode) reset_all_dungeons.

local move      = require 'core.move'
local settings  = require 'activities.boss.settings'
local tracker   = require 'activities.boss.tracker'
local boss_data = require 'activities.boss.data.boss_data'

local task = {
    name             = 'interact_altar',
    status           = 'idle',
    last_click_t     = nil,
}
local CLICK_COOLDOWN_S = 2.0
local INTERACT_RANGE_M = 2.5

-- IMPORTANT: filter on is_interactable().  D4 keeps the altar actor in
-- the stream after being clicked -- it just becomes non-interactable.
-- Without this filter, find_altar() keeps returning a valid actor after
-- click and the bot walks back, tries to re-click (silently rejected),
-- gets summon adds spawning around it, kill_monster pulls it away, the
-- altar is "still there" so interact_altar reclaims the pulse, walks
-- back, fails to click again -- forever.  See user-reported loop.
local function find_altar()
    if not actors_manager or not actors_manager.get_all_actors then return nil end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if boss_data.is_altar(a) and a.is_interactable and a:is_interactable() then
            return a
        end
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

-- A boss-class actor in the actor stream means the altar successfully
-- summoned -- second success signal alongside altar-becomes-non-
-- interactable.  Catches cases where the altar's interactable flag
-- doesn't flip cleanly (network jitter, multi-stage summons).
local function any_boss_in_stream()
    if not actors_manager or not actors_manager.get_all_actors then return false end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a.is_boss and a:is_boss() and a.is_dead and not a:is_dead() then
            return true
        end
    end
    return false
end

-- Helper: latch altar_activated and return false.  Used by every
-- "we're past the altar phase" branch in shouldExecute.
local function mark_activated()
    if not tracker.altar_activated then
        tracker.altar_activated  = true
        tracker.altar_activate_t = get_time_since_inject() or 0
        if settings.debug_mode then console.print('[Boss] altar phase complete') end
    end
end

task.shouldExecute = function ()
    -- Already past the altar phase
    if tracker.altar_activated then
        -- Stuck-recovery probe: if altar_activated has been set for
        -- > altar_stuck_secs AND no chest appeared yet, the boss-fight
        -- itself jammed; reset the run.
        local now = get_time_since_inject() or 0
        if tracker.altar_activate_t
           and (now - tracker.altar_activate_t) > settings.altar_stuck_secs
           and not any_chest_visible()
        then
            if settings.debug_mode then
                console.print(string.format(
                    '[Boss] altar_activated %.0fs ago + no chest -- resetting run',
                    now - tracker.altar_activate_t))
            end
            tracker.reset_run()
            -- Don't fire reset_all_dungeons here; exit.lua handles that
            -- with the right standalone-vs-WarPlan branching.
        end
        return false
    end
    -- Already-spawned chest means the boss is dead from a previous run --
    -- jump past altar phase.
    if any_chest_visible() then mark_activated(); return false end
    -- Boss is alive in the room -> altar must have been clicked already.
    if any_boss_in_stream() then mark_activated(); return false end
    -- We clicked previously and the altar is no longer interactable
    -- (despawned or consumed).  Without this latch we'd never observe
    -- the success transition because Execute only runs while shouldExecute
    -- returns true -- but find_altar() now filters on is_interactable
    -- and returns nil post-click, so shouldExecute returns false and
    -- the disappearance branch in Execute never fired.
    if task.last_click_t and not find_altar() then mark_activated(); return false end
    return find_altar() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local now = get_time_since_inject() or 0

    local altar = find_altar()
    if not altar then
        -- Altar disappeared since shouldExecute fired -- treat as success.
        if task.last_click_t then
            tracker.altar_activated  = true
            tracker.altar_activate_t = now
            if settings.debug_mode then console.print('[Boss] altar despawned -> activated') end
        end
        task.status = 'no altar'
        return
    end
    tracker.altar_seen = true

    local pp = lp:get_position()
    local ap = altar:get_position()
    -- Latch the altar's world position the first time we see it so
    -- walk_boss_room can use it as the in-arena tether anchor.  Latch-
    -- once: if the altar actor jitters or relocates (it shouldn't, but
    -- be defensive), we keep the original spawn position.
    if not tracker.altar_position and ap then
        tracker.altar_position = vec3:new(ap:x(), ap:y(), ap:z())
    end
    local d  = math.sqrt((ap:x()-pp:x())^2 + (ap:y()-pp:y())^2)
    if d > INTERACT_RANGE_M then
        move.to_actor(altar)
        task.status = string.format('walking to altar (%.0fm)', d)
        return
    end
    if task.last_click_t and (now - task.last_click_t) < CLICK_COOLDOWN_S then
        task.status = 'waiting for altar interact'
        return
    end
    if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
    interact_object(altar)
    task.last_click_t = now
    if settings.debug_mode then console.print('[Boss] clicking altar') end
    task.status = 'clicking altar'
end

return task
