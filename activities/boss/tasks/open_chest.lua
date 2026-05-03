-- ---------------------------------------------------------------------------
-- activities/boss/tasks/open_chest.lua
--
-- After the boss dies, walk to the closest reward chest and open it -- but
-- only if we have a matching summon-resource key (Greater/Lower Lair Key,
-- or Husk for Belial).  D4's boss reward chest pops a "Pay X to claim"
-- prompt; without keys, clicking it does nothing useful and we'd loop.
--
-- We deliberately do NOT require is_interactable() in find_closest_chest --
-- the chest can briefly be in stream BEFORE its interactable flag flips,
-- and we want to be walking toward it during that window so we don't
-- waste 2-3 seconds standing still.  The actual click is gated on
-- is_interactable() in Execute.
--
-- Reward chest matching covers:
--   EGB_Chest, Chest_Boss, Boss_WT_Belial_*
-- (see boss_data.chest_patterns).
-- ---------------------------------------------------------------------------

local move      = require 'core.move'
local settings  = require 'activities.boss.settings'
local tracker   = require 'activities.boss.tracker'
local boss_data = require 'activities.boss.data.boss_data'

local task = { name = 'open_chest', status = 'idle', last_click_t = nil }

local CLICK_DEBOUNCE_S = 4
local INTERACT_RANGE_M = 3

-- Find the closest reward chest in stream, regardless of interactable
-- state -- callers gate the actual click on is_interactable themselves.
local function find_closest_chest()
    if not actors_manager or not actors_manager.get_all_actors then return nil, math.huge end
    local lp = get_local_player()
    if not lp then return nil, math.huge end
    local pp = lp:get_position()
    if not pp then return nil, math.huge end
    local best, best_d = nil, math.huge
    for _, a in pairs(actors_manager:get_all_actors()) do
        if boss_data.is_reward_chest(a) then
            local p = a.get_position and a:get_position() or nil
            if p then
                local d = math.sqrt((p:x()-pp:x())^2 + (p:y()-pp:y())^2)
                if d < best_d then best, best_d = a, d end
            end
        end
    end
    return best, best_d
end

-- Determine the boss tier we're up against based on the current zone.
-- Returns 'greater' | 'lower' | 'husk' | nil.
local function current_boss_tier()
    local w = get_current_world()
    local zone = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    local boss = boss_data.boss_for_zone(zone)
    return boss and boss.key_tier or nil
end

-- True when we have at least one of the right key for this zone's boss.
-- If we can't determine the tier (unknown zone), we conservatively allow
-- the click attempt -- the game's prompt UI will reject without keys.
local function have_matching_key()
    local tier = current_boss_tier()
    if not tier then return true end
    return boss_data.count_keys(tier) > 0
end

task.shouldExecute = function ()
    if not settings.do_chests then return false end
    if find_closest_chest() == nil then return false end
    -- Skip the chest entirely if we don't have a key -- prevents the loop
    -- of "walk to chest, click prompt, no key in inventory, popup
    -- auto-cancels, walk to chest, click prompt..." that the user reported.
    if not have_matching_key() then
        if settings.debug_mode and not tracker._open_chest_no_key_logged then
            local tier = current_boss_tier() or '?'
            console.print('[Boss] no ' .. tier .. ' key in inventory -- skipping chest')
            tracker._open_chest_no_key_logged = true   -- one-shot per run
        end
        return false
    end
    return true
end

task.Execute = function ()
    local now = get_time_since_inject() or 0
    if task.last_click_t and (now - task.last_click_t) < CLICK_DEBOUNCE_S then
        task.status = 'waiting for chest VFX'
        return
    end
    local chest, d = find_closest_chest()
    if not chest then task.status = 'no chest'; return end

    if d > INTERACT_RANGE_M then
        move.to_actor(chest)
        task.status = string.format('walking to chest (%.0fm)', d)
        return
    end

    -- We're in interact range.  Check the chest's own interactable flag --
    -- it can briefly be false right after spawn.
    if chest.is_interactable and not chest:is_interactable() then
        task.status = 'chest not interactable yet'
        return
    end

    if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
    interact_object(chest)
    -- D4 pops a "Pay 1 Lair Key?" notification.  utility.confirm_sigil_notification
    -- handles the same notification family (sigil consume / chest consume).
    if utility and utility.confirm_sigil_notification then
        pcall(utility.confirm_sigil_notification)
    end
    task.last_click_t      = now
    tracker.chest_opened   = true
    tracker.chest_opened_t = now
    if settings.debug_mode then
        console.print('[Boss] opened chest ' .. tostring(chest:get_skin_name()))
    end
    task.status = 'opened ' .. tostring(chest:get_skin_name())
end

return task
