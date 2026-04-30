-- activities/hordes/tasks/interact_boss_portal.lua
--
-- After the wave-loop completes (locked door appears, all aether collected),
-- a boss-arena portal pylon spawns.  The user picks Bartuc or Council via
-- the regular pylon UI -- but the pylon names differ from boon pylons:
--
--   BSK_Pyl_Bartuc       -- "Bartuc" boss-arena portal (alt path)
--   BSK_Pyl_Council      -- "Council of Hatred" boss-arena portal (default)
--
-- Both teleport the player to the boss arena.  We prefer Bartuc when
-- settings.prefer_bartuc is set (matches HordeDev's `do_bartuc` toggle),
-- with a 6-second fallback to Council if Bartuc fails to interact.
--
-- The regular interact_pylon task ignores these because their names aren't
-- in pylon_priority.lua (which is the boon list).  This task is registered
-- in runner.lua AFTER interact_pylon so boon-picking takes priority during
-- between-wave choices.

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

local function find_portal(prefer_bartuc)
    if not actors_manager or not actors_manager.get_all_actors then return nil end
    local bartuc, council
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        -- Both portals are interactable (the player has to click them).
        local ok = a.is_interactable and a:is_interactable()
        if ok then
            if sn:find('Bartuc',  1, true) and sn:find('BSK_Pyl', 1, true) then
                bartuc = a
            elseif sn:find('Council', 1, true) and sn:find('BSK_Pyl', 1, true) then
                council = a
            end
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
    return find_portal(settings.prefer_bartuc) ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local now = get_time_since_inject and get_time_since_inject() or 0

    -- Pick the preferred portal, fall back to council if Bartuc didn't open
    -- after BARTUC_GIVE_UP_S seconds (Bartuc has occasional interact-fail
    -- where the portal stays interactable but click does nothing).
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
