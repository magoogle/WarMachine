-- activities/hordes/tasks/open_chest.lua
--
-- After the boss dies in the boss arena, 2-3 reward chests spawn.  We walk
-- to the closest interactable Chest_* and click it; the legacy HordeDev
-- open_chests.lua adds GA-priority + materials/gold ordering + inventory
-- salvage interrupts, but for v1 we just open whichever chest is closest
-- and let the player pre-configure GUI toggles for which they want.
--
-- Once at least one chest has been clicked, tracker.chest_opened is set
-- so exit.lua can fire the run-done handoff.  Any remaining chests get
-- opened on subsequent pulses (each click bumps last_click_t and we wait
-- the debounce window before clicking the next one).

local move     = require 'core.move'
local settings = require 'activities.hordes.settings'
local tracker  = require 'activities.hordes.tracker'

local task = { name = 'open_chest', status = 'idle', last_click_t = nil }
local CLICK_DEBOUNCE_S = 4         -- chest VFX takes ~2-3s to play out

-- A "horde chest" is any interactable actor whose skin starts with Chest_
-- and lives inside a BSK zone.  HordeDev categorizes by enum (GA / GOLD /
-- MATERIALS) but the names are all Chest_* prefixed so substring match is
-- enough for "click them all."
local function find_closest_chest()
    if not actors_manager or not actors_manager.get_all_actors then return nil, math.huge end
    local lp = get_local_player()
    if not lp then return nil, math.huge end
    local pp = lp:get_position()
    if not pp then return nil, math.huge end

    local best, best_d = nil, math.huge
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if sn:find('Chest', 1, true)
           and a.is_interactable and a:is_interactable() then
            local p = a:get_position()
            if p then
                local dx = p:x() - pp:x()
                local dy = p:y() - pp:y()
                local d  = math.sqrt(dx*dx + dy*dy)
                if d < best_d then best, best_d = a, d end
            end
        end
    end
    return best, best_d
end

task.shouldExecute = function ()
    if not settings.do_chests then return false end
    -- Don't bother scanning until the boss is down -- chests don't spawn
    -- before that anyway, and the actor scan in find_closest_chest is
    -- O(actors) so we save a bit of work each pulse.
    if not tracker.boss_killed and not tracker.chest_opened then
        -- Even without a confirmed boss-kill flag, if a chest is somehow
        -- already interactable in a BSK zone we should try it -- assume
        -- the boss-kill detector missed and let the click attempt prove
        -- it.  Only the actor scan happens; nothing destructive runs.
        local chest = find_closest_chest()
        if chest then
            tracker.boss_killed = true        -- back-fill the flag
            return true
        end
        return false
    end
    return find_closest_chest() ~= nil
end

task.Execute = function ()
    local now = get_time_since_inject and get_time_since_inject() or 0
    if task.last_click_t and (now - task.last_click_t) < CLICK_DEBOUNCE_S then
        task.status = 'waiting for chest VFX'
        return
    end

    local chest, d = find_closest_chest()
    if not chest then task.status = 'no chest'; return end

    if d <= 3 then
        if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
        interact_object(chest)
        task.last_click_t = now
        tracker.chest_opened = true
        if settings.debug_mode then
            console.print('[Hordes] opened chest ' .. tostring(chest:get_skin_name()))
        end
        task.status = 'opened ' .. tostring(chest:get_skin_name())
        return
    end
    move.to_actor(chest)
    task.status = string.format('walking to chest (%.0fm)', d)
end

return task
