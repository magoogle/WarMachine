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
-- The "WarpPad" is a separate, BIGGER actor the player visually stands
-- on -- not interactable.  PortalSwitch (the actual click target) is
-- a smaller actor that sits on/near the WarpPad and often isn't in
-- the actor stream until the player walks close to the WarpPad.
-- WonderCity's working pattern (tasks/portal.lua):
--     1. find PortalSwitch -- if interactable + close, click it
--     2. else navigate to WarpPad to bring PortalSwitch into stream
-- Without WarpPad routing the bot couldn't path to a not-yet-streamed
-- PortalSwitch, freeroam-thrashed near the descent area, and never
-- descended -- the user-reported "stuck on warp pad" symptom.
local WARP_PAD_PATTERNS = {
    'undercity_warppad',
    'warp_pad',
    'warppad',
}
-- Two-band approach for the same hysteresis reason as
-- interact_enticement: walk to a tight WALK_TO_RANGE so post-arrival
-- drift doesn't push us back outside the click range and starve the
-- click loop in a walk-then-drift ping-pong.
local INTERACT_RANGE   = 5.0
local WALK_TO_RANGE    = 1.5
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

local function find_warp_pad()
    -- WarpPad is a navigation BEACON: bigger, visible, often in stream
    -- when the smaller PortalSwitch isn't yet.  Walking to it brings
    -- the PortalSwitch into stream so the click loop can engage.
    -- Same entry-portal exclusion as find_switch (post-descent the
    -- back-WarpPad streams in too).
    return find.closest({
        patterns             = WARP_PAD_PATTERNS,
        require_interactable = false,
        source               = 'all',
        visited              = nil,
        filter               = function (a)
            return not entry_portal.is_actor_near_entry(a)
        end,
    })
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
--
-- Mirrors interact_enticement.find_enticement's hearth-cap filter so
-- this gate and that task agree on "is there something clickable?".
-- Without the mirror, hitting the hearth cap with only hearths in
-- stream produces a deadlock: enticements_pending says yes (no cap
-- check) -> floor_portal yields -> interact_enticement yields (cap)
-- -> nothing claims the pulse and the bot stops descending.
-- Gate-timeout state for the "waiting for more enticements" hold.
-- When the gate has been blocking for GATE_MAX_WAIT_S without any new
-- enticement getting consumed (counter doesn't advance), we release
-- it -- otherwise a floor that doesn't spawn enough enticements to
-- meet `min_enticements_before_descent` would trap the bot forever
-- (freeroam thrash + trap-detector loop in the live log).
local GATE_MAX_WAIT_S = 30.0
local _gate_block_since        = nil   -- monotonic seconds when block started
local _gate_consumed_at_block  = 0     -- enticements_this_floor at that time

local function enticements_pending()
    if settings.do_enticements == false then return false end
    if settings.speed_run and (tracker.hearth_count or 0) >= (settings.max_hearths or 4) then
        return false
    end

    -- Per-floor minimum gate.  When > 0, descent is blocked until this
    -- many enticements have been consumed on the current floor, even if
    -- no more enticements are visible in stream.  Counter resets on
    -- world_id change in update_world_tracking.
    local min_required = settings.min_enticements_before_descent or 0
    local consumed_this_floor = tracker.enticements_this_floor or 0

    local cap_reached = (tracker.hearth_count or 0) >= (settings.max_hearths or 4)
    local cand = find.closest({
        patterns             = BLOCKING_PATTERNS,
        require_interactable = false,
        source               = 'all',
        visited              = tracker.visited,
        visited_prefix       = 'enticement',
        filter               = function (a)
            if not cap_reached then return true end
            local sn = a.get_skin_name and a:get_skin_name() or ''
            -- At cap, hearths no longer count as "pending"; beacons still do.
            return sn:lower():find('spirithearth', 1, true) == nil
        end,
    })

    -- A live candidate ALONE blocks descent (existing behavior).
    -- Reset the gate-timeout tracker so the next "no candidate" round
    -- starts a fresh wait window.
    if cand ~= nil then
        _gate_block_since        = nil
        _gate_consumed_at_block  = consumed_this_floor
        return true
    end

    -- No live candidate, but we haven't met the per-floor minimum AND
    -- the user actively wants enticements.  Hold the descent gate so
    -- the bot has time to wander the floor and find more enticements.
    if min_required > 0 and consumed_this_floor < min_required then
        local now = get_time_since_inject() or 0

        -- First time we're blocking on the min-not-met path -- start
        -- the timeout window.  Snapshot the current consumed count so
        -- we can detect "we're making progress, reset timer."
        if _gate_block_since == nil then
            _gate_block_since        = now
            _gate_consumed_at_block  = consumed_this_floor
        elseif consumed_this_floor > _gate_consumed_at_block then
            -- We HAVE consumed something since the block started.
            -- That's progress -- reset the timer; gate stays active
            -- pending the next consume.
            _gate_block_since        = now
            _gate_consumed_at_block  = consumed_this_floor
        elseif (now - _gate_block_since) >= GATE_MAX_WAIT_S then
            -- Stuck waiting too long with no progress.  Give up on
            -- the min and let descent proceed -- the floor probably
            -- doesn't have enough enticements to satisfy the cap.
            if settings.debug_mode then
                console.print(string.format(
                    '[Undercity] enticement gate timed out after %.0fs ' ..
                    '(consumed %d/%d); proceeding to descent',
                    GATE_MAX_WAIT_S, consumed_this_floor, min_required))
            end
            _gate_block_since       = nil
            _gate_consumed_at_block = 0
            return false
        end
        return true
    end

    -- Min met (or off).  Reset gate state and release.
    _gate_block_since       = nil
    _gate_consumed_at_block = 0
    return false
end

local function update_world_tracking()
    if not in_undercity() then return end
    local w = get_current_world()
    local wid = w and w.get_world_id and w:get_world_id() or nil
    if not wid then return end
    if tracker.last_world_id and tracker.last_world_id ~= wid then
        tracker.current_floor = (tracker.current_floor or 1) + 1
        -- New floor -- reset visited dedup + per-target click state +
        -- per-floor enticement counter (so the
        -- min_enticements_before_descent gate enforces per-floor, not
        -- per-session) + gate-timeout state.
        tracker.visited                 = {}
        tracker.poi_cache               = nil
        tracker.enticements_this_floor  = 0
        task.last_click_t               = nil
        task.click_count                = 0
        _gate_block_since               = nil
        _gate_consumed_at_block         = 0
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
    -- Fire when EITHER actor is in stream.  WarpPad routes us toward
    -- the descent area so PortalSwitch streams in; PortalSwitch is
    -- the actual click target.
    return find_switch() ~= nil or find_warp_pad() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local switch = find_switch()

    -- ----------------------------------------------------------------
    -- Phase 0: PortalSwitch not yet in stream -- navigate to WarpPad
    -- to bring it in.  WarpPad is the BIG visible pad on the floor;
    -- PortalSwitch is the small interactable that sits on/near it.
    -- This mirrors WonderCity's working flow.  Without this fallback
    -- the bot couldn't path to the switch and freeroam-thrashed near
    -- the descent area.
    -- ----------------------------------------------------------------
    if not switch then
        local pad = find_warp_pad()
        if not pad then task.status = 'no switch / no warp pad'; return end
        local pad_p = pad:get_position()
        if not pad_p then task.status = 'no warp-pad position'; return end
        local pad_d = math.sqrt((pad_p:x()-pp:x())^2 + (pad_p:y()-pp:y())^2)
        if pad_d > 2.0 then
            move.to_pos({ x = pad_p:x(), y = pad_p:y(), z = pad_p:z() }, {
                arrive_radius = 1.5,
                long_path     = true,
            })
            task.status = string.format('walking to warp pad (%.0fm)', pad_d)
            return
        end
        -- We're ON the pad but the switch hasn't streamed in yet.
        -- Stand still; D4 should populate the actor stream within a
        -- frame or two and the next pulse will find the switch.
        move.pause()
        task.status = 'on warp pad, waiting for switch stream'
        return
    end

    local sp = switch:get_position()
    if not sp then task.status = 'no switch position'; return end
    local d = math.sqrt((sp:x()-pp:x())^2 + (sp:y()-pp:y())^2)

    if d > INTERACT_RANGE then
        -- Use move.to_pos with long_path=true rather than move.to_actor.
        -- move.to_actor calls interact_object which uses D4's host-side
        -- click-to-walk -- that's an INCOMPLETE path planner: the host
        -- returns short partial routes (4-7 nodes ~ 8-15y), and when
        -- the warp pad sits past geometry the player needs to detour
        -- around, the partial paths end up FURTHER from the goal each
        -- pulse and the bot oscillates 18-20y away forever.  long_path
        -- forces a complete A* route through the detour.
        move.to_pos({ x = sp:x(), y = sp:y(), z = sp:z() }, {
            arrive_radius = WALK_TO_RANGE,
            long_path     = true,
        })
        task.status = string.format('walking to switch (%.0fm)', d)
        return
    end

    -- In range.  Stop the walker so we don't drift past the pad, and
    -- pause the nav (sticky) so the explorer can't pick a new
    -- frontier mid-click.
    move.pause()
    local wok, walker = pcall(require, 'core.walker')
    if wok and walker and walker.stop then walker.stop() end

    -- Click loop.  User-reported pattern: "We have to be on it,
    -- standstill, and try interacting a few times".  D4's
    -- is_interactable() flag for the PortalSwitch flickers false
    -- on close approach (same way the enticement switches do), and
    -- the prior `if interactable then click` gate would silently
    -- skip clicks while the bot stood on the pad waiting for the
    -- flag.  Per the matching enticement fix: just hammer
    -- interact_object on the cooldown -- D4 no-ops the click when
    -- the actor isn't ready, and the click lands as soon as it is.
    local now = get_time_since_inject() or 0
    if not task.last_click_t or (now - task.last_click_t) >= CLICK_COOLDOWN_S then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(switch)
        task.last_click_t    = now
        task.last_interact_t = now
        task.click_count     = (task.click_count or 0) + 1
        if settings.debug_mode then
            console.print(string.format(
                '[Undercity] portal click #%d on %s (interactable=%s)',
                task.click_count,
                switch:get_skin_name() or '?',
                tostring(switch.is_interactable and switch:is_interactable())))
        end
    end
    task.status = string.format('descending (#%d)', task.click_count or 0)
end

return task
