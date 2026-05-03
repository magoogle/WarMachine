-- ---------------------------------------------------------------------------
-- activities/undercity/tasks/floor_portal.lua
--
-- Walks to + clicks the floor-descent switch (X1_Undercity_PortalSwitch).
--
-- Gating: this task INTENTIONALLY waits for any in-stream Spirit Beacons /
-- Hearths to be consumed first.  interact_enticement runs at higher
-- priority, but if its find_enticement() ever returns nil while a beacon
-- is actually on the floor, floor_portal would fire and warp us away
-- before the beacon got clicked.  We add a defensive check here that
-- mirrors the same actor-stream search interact_enticement uses; if it
-- returns a candidate, we DON'T descend.
--
-- Skin matching is flexible (skin_core + substring + get_all_actors)
-- because exact-match `get_ally_actors` lookups silently miss the switch
-- when the runtime decorates the skin with `_01_Dyn` or season prefixes.
-- ---------------------------------------------------------------------------

local move          = require 'core.move'
local find          = require 'core.find'
local zone          = require 'core.zone'
local entry_portal  = require 'core.entry_portal'
local tracker       = require 'activities.undercity.tracker'
local settings      = require 'activities.undercity.settings'

local task = {
    name = 'floor_portal', status = 'idle',
    last_interact_t = nil,
    last_click_t    = nil,
    click_count     = 0,
}

local PORTAL_PATTERNS = {
    'undercity_portalswitch',
    'undercity_portal_switch',
    'portalswitch',
    'portal_switch',
}
local INTERACT_RANGE   = 3.0
local CLICK_COOLDOWN_S = 1.0

-- Substring patterns for any beacon/hearth that would block descent.
-- Mirrors interact_enticement.ENTICEMENT_PATTERNS so the gate stays in
-- sync if beacons get renamed.
local BLOCKING_PATTERNS = {
    'spiritbeacon', 'spirithearth',
    'spirit_beacon', 'spirit_hearth',
    'spirit_beacon_switch', 'spirit_hearth_switch',
    'enticements_spirit',
}

local function in_undercity()
    local z = zone.current()
    return z and z:sub(1, #'X1_Undercity_') == 'X1_Undercity_' or false
end

local function find_switch()
    -- Don't filter on is_interactable here -- D4 sometimes flips that
    -- flag false when far from the switch, then true on close approach.
    -- The Execute path calls is_interactable + retries on cooldown.
    --
    -- Entry-portal exclusion: skip portal switches sitting at our
    -- spawn-in position.  After descending, the back-portal switch
    -- streams in next to us with the same skin as the FORWARD switch
    -- on this floor; without the filter the bot would re-click it
    -- and bounce up a floor.  See core/entry_portal.lua.
    return find.closest({
        patterns             = PORTAL_PATTERNS,
        require_interactable = false,
        source               = 'all',
        visited              = nil,
        filter               = function (a)
            return not entry_portal.is_actor_near_entry(a)
        end,
    })
end

-- True if there's any unvisited beacon/hearth in stream we should click
-- before descending.  When `do_enticements` is off the user has opted
-- out, so this gate is disabled.
local function enticements_pending()
    if settings.do_enticements == false then return false end
    if settings.speed_run and (tracker.hearth_count or 0) >= (settings.max_hearths or 4) then
        return false
    end
    local cand = find.closest({
        patterns             = BLOCKING_PATTERNS,
        require_interactable = false,
        source               = 'all',
        visited              = tracker.visited,
        visited_prefix       = 'enticement',
    })
    return cand ~= nil
end

local function update_world_tracking()
    if not in_undercity() then return end
    local w = get_current_world()
    local wid = w and w.get_world_id and w:get_world_id() or nil
    if not wid then return end
    if tracker.last_world_id and tracker.last_world_id ~= wid then
        tracker.current_floor = (tracker.current_floor or 1) + 1
        -- New floor -- reset visited dedup + per-target click state
        tracker.visited = {}
        tracker.poi_cache = nil
        task.last_click_t = nil
        task.click_count  = 0
    end
    tracker.last_world_id = wid
end

task.shouldExecute = function ()
    update_world_tracking()
    if not in_undercity() then return false end
    if tracker.boss_seen then return false end   -- final floor: no descent
    if enticements_pending() then
        if settings.debug_mode then
            console.print('[Undercity] floor_portal waiting on pending enticement')
        end
        return false
    end
    return find_switch() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local switch = find_switch()
    if not switch then task.status = 'no switch'; return end
    local pp = lp:get_position()
    local sp = switch:get_position()
    if not pp or not sp then return end
    local d = math.sqrt((sp:x()-pp:x())^2 + (sp:y()-pp:y())^2)

    if d > INTERACT_RANGE then
        move.to_actor(switch)
        task.status = string.format('walking to switch (%.0fm)', d)
        return
    end

    -- In range.  Stop the walker so we don't drift past the pad.
    local wok, walker = pcall(require, 'core.walker')
    if wok and walker and walker.stop then walker.stop() end

    -- Retry the click on cooldown until is_interactable() flips false
    -- (= consumed -> world transition pending).  The single-shot
    -- interact_object() call sometimes silently fails (host-side input
    -- timing) -- the user-reported "standing on the warp pad but not
    -- activating it" symptom.
    local now = get_time_since_inject() or 0
    local interactable = switch.is_interactable and switch:is_interactable()
    if interactable then
        if not task.last_click_t or (now - task.last_click_t) >= CLICK_COOLDOWN_S then
            if orbwalker and orbwalker.set_clear_toggle then
                orbwalker.set_clear_toggle(false)
            end
            interact_object(switch)
            task.last_click_t   = now
            task.last_interact_t = now
            task.click_count    = (task.click_count or 0) + 1
            if settings.debug_mode then
                console.print(string.format(
                    '[Undercity] portal click #%d on %s',
                    task.click_count, switch:get_skin_name() or '?'))
            end
        end
        task.status = string.format('descending (#%d)', task.click_count or 0)
        return
    end

    -- Switch is no longer interactable -> world transition is in flight.
    task.status = 'descending'
end

return task
