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
-- Back-portal blacklist radius.  D4 spawns the player some yards
-- AWAY from the destination portal after a teleport (live data: ~22y
-- gap between spawn point and the back portal actor).
local BACK_PORTAL_RADIUS_SQ = 625   -- 25y squared
-- back_portal_pos auto-clears after this many seconds.  Without a
-- timeout, if the bot accidentally bounces back to the same floor
-- (e.g. clicked a portal that actually went backward), the floor's
-- only forward portal stays permanently within the blacklist and the
-- bot can't escape.  Per the user-reported "didn't go back down"
-- after a back-up cycle.
local BACK_PORTAL_TIMEOUT_S = 30
local back_portal_set_t = nil

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
    -- Auto-clear an aged back_portal_pos so a single-portal floor
    -- doesn't lock us out forever after an accidental cycle.  Cheap
    -- check; safe to run every pulse.
    if tracker.back_portal_pos and back_portal_set_t then
        local now = get_time_since_inject() or 0
        if (now - back_portal_set_t) >= BACK_PORTAL_TIMEOUT_S then
            tracker.back_portal_pos = nil
            back_portal_set_t = nil
        end
    end
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
                back_portal_set_t = now
                if settings.debug_mode then
                    console.print(string.format(
                        '[Pit] floor change to wid=%s -- back-portal blacklisted near (%.1f,%.1f)',
                        tostring(wid), pos:x(), pos:y()))
                end
            end
        end
        tracker.current_floor = (tracker.current_floor or 1) + 1
        -- DON'T clear tracker.visited on floor change.  It now contains
        -- "portals we've already used" marks set by interact-time --
        -- wiping it would re-allow seek_progression to pick the same
        -- portal we just descended through (the catalog entry shares
        -- coords across floors), causing the user-reported "stuck
        -- going in and out of portals over and over" loop.
        --
        -- We DO still drop the priority cache so the next-floor queue
        -- rebuilds against the current catalog state.
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
            local skip = false
            if tracker.back_portal_pos then
                local p = a:get_position()
                if p then
                    local dx = p:x() - tracker.back_portal_pos.x
                    local dy = p:y() - tracker.back_portal_pos.y
                    if dx*dx + dy*dy < BACK_PORTAL_RADIUS_SQ then
                        skip = true
                    end
                end
            end
            if not skip then return a end
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
            -- Note: we do NOT mark this portal visited.  Each pit-floor
            -- portal has TWO catalog entries (the floor-N side and the
            -- floor-N+1 side) at different coords.  Marking one side
            -- visited doesn't help because we'll see the other side
            -- next floor; worse, when we re-visit floor N (e.g. after
            -- bouncing back through the floor-N+1 back portal), the
            -- floor-N portal we want to re-use is locked out -- the
            -- "went down then back up then didn't go back down" stuck
            -- the user reported.  Rely entirely on back_portal_pos
            -- (now 25y radius) for cycle prevention.
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
