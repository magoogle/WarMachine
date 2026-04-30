-- ---------------------------------------------------------------------------
-- activities/pit/tasks/floor_portal.lua
--
-- Pit floor descent.  Two stages:
--   1. Find + click TWR_ExitPortalSwitch -- this opens the next-floor portal.
--   2. Walk into Prefab_Portal_Dungeon_Generic (kind=pit_floor_portal) --
--      this teleports us to the next floor.
--
-- After teleporting we spawn directly on top of the back-portal (the one
-- we just came through).  Without a guard, the bot would step right back
-- onto it.  We snapshot the spawn position on world_id change and
-- exclude any portal within 10y of it.  Cleared on the next world change.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local tracker  = require 'activities.pit.tracker'
local settings = require 'activities.pit.settings'

local task = { name = 'floor_portal', status = 'idle' }

local PORTAL_SWITCH_SKIN = 'X1_TWR_ExitPortalSwitch'   -- pit_exit kind in actor_capture
local FLOOR_PORTAL_PATTERN = 'Portal_Dungeon'           -- pit_floor_portal kind
local INTERACT_RANGE = 3.0
local BACK_PORTAL_RADIUS_SQ = 100   -- 10y squared

local function get_world_id()
    local w = get_current_world()
    return w and w.get_world_id and w:get_world_id() or nil
end

local function in_pit()
    local w = get_current_world()
    if not w or not w.get_name then return false end
    local n = w:get_name()
    return n and n:sub(1, 4) == 'PIT_'
end

-- Detect world_id transitions = floor descent.  Snapshot spawn position
-- so the back-portal blacklist works.
local function update_world_tracking()
    if not in_pit() then return end
    local wid = get_world_id()
    if not wid then return end
    if tracker.last_world_id == wid then return end

    -- World changed.  If we just clicked a portal, this is the floor descent.
    local now = get_time_since_inject() or 0
    if tracker.portal_just_used and (now - (tracker.portal_used_t or 0)) < 5 then
        local lp = get_local_player()
        if lp then
            local pos = lp:get_position()
            if pos then
                tracker.back_portal_pos = { x = pos:x(), y = pos:y() }
                if settings.debug_mode then
                    console.print(string.format(
                        '[Pit] floor change to wid=%s -- back-portal blacklisted near (%.1f,%.1f)',
                        tostring(wid), pos:x(), pos:y()))
                end
            end
        end
        tracker.current_floor = (tracker.current_floor or 1) + 1
        -- Clear the visited dedup since we're on a new floor
        tracker.visited = {}
        tracker.poi_cache = nil
    else
        -- Initial entry, not portal-induced
        tracker.back_portal_pos = nil
    end
    tracker.last_world_id = wid
    tracker.portal_just_used = false
end

local function find_portal_switch()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_ally_actors()) do
        if a:is_interactable() then
            local sn = a:get_skin_name()
            -- Match the pit-exit switch.  Multiple skin variants exist
            -- across the TWR family; substring is the safe match.
            if sn and (sn:find('ExitPortalSwitch', 1, true)
                    or sn:find('TWR_ExitPortal', 1, true)
                    or sn == PORTAL_SWITCH_SKIN) then
                return a
            end
        end
    end
    return nil
end

local function find_floor_portal()
    if not actors_manager then return nil end
    local lp = get_local_player()
    if not lp then return nil end
    local pp = lp:get_position()
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a:get_skin_name() or ''
        if sn:find(FLOOR_PORTAL_PATTERN, 1, true)
           and not sn:find('Light_NoShadows', 1, true)
           and a.is_interactable and a:is_interactable()
        then
            -- Back-portal blacklist
            if tracker.back_portal_pos then
                local p = a:get_position()
                if p then
                    local dx = p:x() - tracker.back_portal_pos.x
                    local dy = p:y() - tracker.back_portal_pos.y
                    if dx*dx + dy*dy < BACK_PORTAL_RADIUS_SQ then
                        goto continue
                    end
                end
            end
            return a
            ::continue::
        end
    end
    return nil
end

task.shouldExecute = function ()
    update_world_tracking()
    if not in_pit() then return false end
    -- Once the boss is dead and glyph upgrade started, exit.lua takes over.
    if tracker.boss_killed_at then return false end
    return find_portal_switch() ~= nil or find_floor_portal() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    -- Prefer the floor portal (it appears AFTER the switch is clicked,
    -- so if both are around, we want the portal).
    local portal = find_floor_portal()
    if portal then
        local p = portal:get_position()
        local dx = p:x() - pp:x()
        local dy = p:y() - pp:y()
        local d  = math.sqrt(dx*dx + dy*dy)
        if d <= INTERACT_RANGE then
            tracker.portal_just_used = true
            tracker.portal_used_t = get_time_since_inject() or 0
            interact_object(portal)
            task.status = 'descending'
            return
        end
        move.to_actor(portal)
        task.status = string.format('walking to floor portal (%.0fm)', d)
        return
    end

    -- No portal yet -- click the switch first.
    local switch = find_portal_switch()
    if switch then
        local p = switch:get_position()
        local dx = p:x() - pp:x()
        local dy = p:y() - pp:y()
        local d  = math.sqrt(dx*dx + dy*dy)
        if d <= INTERACT_RANGE then
            interact_object(switch)
            task.status = 'opening floor portal'
            return
        end
        move.to_actor(switch)
        task.status = string.format('walking to portal switch (%.0fm)', d)
        return
    end

    task.status = 'no portal/switch in stream'
end

return task
