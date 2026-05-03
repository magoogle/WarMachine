-- ---------------------------------------------------------------------------
-- activities/pit/tasks/shortcut_portal.lua
--
-- Bonus loot room: when Warplans_Pit_ChoronsShortcut_Portal_Gizmo appears
-- in the actor stream, walk to it and interact to enter the extra room.
-- The game warps the player back out automatically after collecting; the
-- floor_portal task's world-id tracker handles the re-entry back-portal
-- via the shared portal_just_used / portal_used_t flags.
-- ---------------------------------------------------------------------------

local move    = require 'core.move'
local tracker = require 'activities.pit.tracker'

local task = { name = 'shortcut_portal', status = 'idle' }

local INTERACT_RANGE = 3.0

local function in_pit()
    local w = get_current_world()
    if not w or not w.get_name then return false end
    local n = w:get_name()
    return n and n:sub(1, 4) == 'PIT_'
end

local function find_shortcut()
    if not actors_manager then return nil end
    -- Ally actors first (most interactables live there).
    for _, a in pairs(actors_manager:get_ally_actors()) do
        local sn = a:get_skin_name() or ''
        if sn:find('ChoronsShortcut', 1, true)
           and a.is_interactable and a:is_interactable()
        then
            return a
        end
    end
    -- Fallback: all actors (in case it streams as a non-ally).
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a:get_skin_name() or ''
        if sn:find('ChoronsShortcut', 1, true)
           and a.is_interactable and a:is_interactable()
        then
            return a
        end
    end
    return nil
end

task.shouldExecute = function ()
    if not in_pit() then return false end
    if tracker.boss_killed_at then return false end
    return find_shortcut() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local portal = find_shortcut()
    if not portal then
        task.status = 'shortcut portal gone'
        return
    end

    local p = portal:get_position()
    local dx = p:x() - pp:x()
    local dy = p:y() - pp:y()
    local d  = math.sqrt(dx*dx + dy*dy)

    if d <= INTERACT_RANGE then
        -- Signal floor_portal's world-id tracker so it snapshots the
        -- back-portal position after the warp, preventing us from
        -- immediately stepping back through the entry portal.
        tracker.portal_just_used = true
        tracker.portal_used_t    = get_time_since_inject() or 0
        interact_object(portal)
        task.status = 'entering shortcut loot room'
        return
    end

    move.to_actor(portal)
    task.status = string.format('walking to shortcut portal (%.0fm)', d)
end

return task
