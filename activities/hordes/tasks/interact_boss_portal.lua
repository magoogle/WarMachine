-- activities/hordes/tasks/interact_boss_portal.lua
--
-- After the wave-loop completes there are TWO interactables in sequence:
--
-- 1. Locked boss-room door -- separates the wave arena from the pylon room.
--    Skins observed (HordeDev/tasks/horde.lua:254-256):
--       Hell_Fort_BSK_Door_A_01_Dyn          (the actual door actor)
--       BSK_MapIcon_LockedDoor               (presence indicator on map)
--    DGN_Standard_Door_Lock_Sigil_Ancients_Zak_Evil = "still in wave",
--    used as a NEGATIVE signal -- if this is up, waves aren't done yet.
--
-- 2. Bartuc / Council pylon-choice gizmo -- inside the pylon room.  Click
--    one to teleport to the boss arena.
--    Skins observed (HordeDev/data/enums.lua:32-34):
--       BSK_PylChoiceGizmo_SelectBartuc      (alt boss path)
--       BSK_PylChoiceGizmo_SelectCouncil     (default Council of Hatred)
--
-- We handle both in this one task -- check door first, then pylons.
-- Bartuc has a 6s give-up window (HordeDev's bartuc_pylon_give_up_time);
-- if Bartuc was preferred but didn't open after that long, fall back to
-- Council.

local move     = require 'core.move'
local settings = require 'activities.hordes.settings'
local tracker  = require 'activities.hordes.tracker'

local task = {
    name              = 'interact_boss_portal',
    status            = 'idle',
    last_click_t      = nil,
    bartuc_started_t  = nil,
    bartuc_failed     = false,
}
local CLICK_DEBOUNCE_S      = 3
local BARTUC_GIVE_UP_S      = 6   -- HordeDev's bartuc_pylon_give_up_time

-- Pylon-choice gizmo skins (from HordeDev data/enums.lua boss_pylons).
local PYLON_BARTUC  = 'BSK_PylChoiceGizmo_SelectBartuc'
local PYLON_COUNCIL = 'BSK_PylChoiceGizmo_SelectCouncil'

local function find_locked_door()
    if not actors_manager or not actors_manager.get_all_actors then return nil end
    local door, locked, in_wave
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if sn == 'Hell_Fort_BSK_Door_A_01_Dyn' then door = a end
        if sn == 'BSK_MapIcon_LockedDoor'      then locked = true end
        if sn == 'DGN_Standard_Door_Lock_Sigil_Ancients_Zak_Evil' then in_wave = true end
    end
    if in_wave or not locked then return nil end
    -- Latch the wave-completion flag here too so the gate works
    -- regardless of which of (this task, walk_boss_room) ran first.
    if not tracker.locked_door_seen then
        tracker.locked_door_seen = true
        if settings.debug_mode then
            console.print('[Hordes] locked-door latch flipped (interact_boss_portal)')
        end
    end
    return door
end

local function find_portal(prefer_bartuc)
    if not actors_manager or not actors_manager.get_all_actors then return nil end
    local bartuc, council
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        local ok = a.is_interactable and a:is_interactable()
        if ok then
            if     sn == PYLON_BARTUC  then bartuc  = a
            elseif sn == PYLON_COUNCIL then council = a end
        end
    end
    if prefer_bartuc and bartuc then return bartuc, 'bartuc'  end
    if council                  then return council, 'council' end
    if bartuc                   then return bartuc,  'bartuc'  end
    return nil
end

task.shouldExecute = function ()
    if not settings.do_boss_portals then return false end
    if tracker.boss_killed then return false end       -- already past portal
    -- Defense in depth: the locked-door latch in walk_boss_room
    -- requires BOTH the door icon AND the absence of the in-wave
    -- sigil before declaring waves complete.  Honoring it here too
    -- protects against an unreliable in-wave-sigil reading -- if
    -- find_locked_door() fires a false positive (icon up but the
    -- in-wave sigil intermittently dropped), we won't run the bot
    -- at the door mid-wave.  Once walk_boss_room latches the flag,
    -- both tasks agree the wave loop is over.
    local door = find_locked_door()
    if door ~= nil and tracker.locked_door_seen then return true end
    return find_portal(settings.prefer_bartuc) ~= nil  -- then pylons
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local now = get_time_since_inject and get_time_since_inject() or 0

    -- Phase 1: locked boss-room door.  If it's up (waves done, door not
    -- yet opened), walk + click it.  Once clicked it disappears so the
    -- next pulse falls through to Phase 2.
    local door = find_locked_door()
    if door then
        if task.last_click_t and (now - task.last_click_t) < CLICK_DEBOUNCE_S then
            task.status = 'waiting for door'
            return
        end
        local pp = lp:get_position()
        local dp = door:get_position()
        local d  = math.sqrt((dp:x()-pp:x())^2 + (dp:y()-pp:y())^2)
        if d <= 3 then
            if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
            interact_object(door)
            task.last_click_t = now
            if settings.debug_mode then console.print('[Hordes] clicking boss-room door') end
            task.status = 'clicked door'
            return
        end
        move.to_actor(door)
        task.status = string.format('walking to door (%.0fm)', d)
        return
    end

    -- Phase 2: Bartuc / Council pylon-choice gizmo.  Pick preferred,
    -- fall back to Council if Bartuc didn't open after BARTUC_GIVE_UP_S.
    local prefer_bartuc = settings.prefer_bartuc and not task.bartuc_failed
    local actor, which = find_portal(prefer_bartuc)
    if not actor then
        task.status = 'no portal'
        return
    end

    if which == 'bartuc' then
        if not task.bartuc_started_t then task.bartuc_started_t = now end
        if (now - task.bartuc_started_t) > BARTUC_GIVE_UP_S then
            if settings.debug_mode then
                console.print('[Hordes] Bartuc portal timed out; falling back to Council')
            end
            task.bartuc_failed = true
            task.bartuc_started_t = nil
            return            -- next pulse re-resolves to Council
        end
    end

    -- Click debounce (mirrors interact_pylon.lua)
    if task.last_click_t and (now - task.last_click_t) < CLICK_DEBOUNCE_S then
        task.status = 'waiting for portal teleport (' .. which .. ')'
        return
    end

    local pp = lp:get_position()
    local ap = actor:get_position()
    local d  = math.sqrt((ap:x()-pp:x())^2 + (ap:y()-pp:y())^2)
    if d <= 3 then
        if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
        interact_object(actor)
        task.last_click_t = now
        if settings.debug_mode then console.print('[Hordes] clicking ' .. which .. ' portal') end
        task.status = 'clicked ' .. which .. ' portal'
        return
    end
    move.to_actor(actor)
    task.status = string.format('walking to %s portal (%.0fm)', which, d)
end

return task
