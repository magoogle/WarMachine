-- ---------------------------------------------------------------------------
-- activities/undercity/tasks/interact_enticement.lua
--
-- Live-stream Spirit Hearth / Spirit Beacon switch interaction.  Ported
-- from the original WonderCity plugin's interact_enticement +
-- get_closest_enticement helpers (Current Scripts/WonderCity/) which
-- worked reliably -- the v0.2 rewrite missed two key behaviors:
--
--   1) Find phase MUST NOT filter on is_interactable().  D4 reports the
--      interactable flag as false while the player is far away and only
--      flips it to true on close approach.  Filtering on it during find
--      means the bot never sees the enticement and never walks toward
--      it -- the user-reported "running right to portal, never
--      activating SpiritHearth/Beacon switches" symptom.
--
--   2) On arrival, if the actor isn't interactable yet, WAIT a few
--      seconds (settings.enticement_timeout) for it to become so.  If
--      it never does (rare; usually means a different actor stole the
--      slot), mark it visited and move on.  Without this, the bot
--      walks to the actor, finds it non-interactable, and never tries
--      again because it doesn't have a state for "I'm here, waiting".
--
-- The static catalog gap (StaticPatherPlugin.get_actors() not having
-- enticements for fresh zones) is what motivated this task originally
-- -- interact_poi can't see what isn't catalogued.  This live-stream
-- task fills that gap.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local zone     = require 'core.zone'
local find     = require 'core.find'
local settings = require 'activities.undercity.settings'
local tracker  = require 'activities.undercity.tracker'

local task = {
    name           = 'interact_enticement',
    status         = 'idle',
    -- Wall-clock of the first click on the current target -- starts the
    -- timeout window so a hung target doesn't trap us forever.
    interact_time  = nil,
    -- Last-click cooldown gate (per CLICK_COOLDOWN_S in Execute) so we
    -- don't spam interact_object every 50ms while the actor is still
    -- transitioning to non-interactable.
    last_click_t   = nil,
    -- Diagnostic / status counter.
    click_count    = nil,
}

local INTERACT_RANGE = 3.0

-- Substring patterns checked against actor skin names (lowercase).
-- Generous: short catch-all substrings double as defense against
-- season-prefixed naming variants observed live (X1_*, S07_*, S09_*).
local ENTICEMENT_PATTERNS = {
    'spiritbeacon',     -- bigger Beacon switch (uncapped)
    'spirithearth',     -- per-room Hearth switch (capped at max_hearths)
    'spirit_beacon',    -- explicit-underscore variant
    'spirit_hearth',    -- explicit-underscore variant
    'enticements_spirit',
    -- Broader catches -- live captures show season-prefixed and
    -- container-suffix variants the strict patterns above miss:
    --   X1_Undercity_Spirit_Beacon_Switch_01_Dyn
    --   Switch_Spirit_Hearth_01
    --   Trigger_SpiritBeacon_01_Dyn
    'spirit_beacon_switch',
    'spirit_hearth_switch',
    'spiritbeaconswitch',
    'spirithearthswitch',
}

local function is_in_undercity()
    local z = zone.current()
    return z and z:sub(1, 12) == 'X1_Undercity' or false
end

local function is_hearth_skin(sn)
    return sn and sn:lower():find('spirithearth', 1, true) ~= nil
end

local function hearth_cap_reached()
    return (tracker.hearth_count or 0) >= (settings.max_hearths or 4)
end

-- Find the closest enticement we haven't interacted with yet.
-- Crucially: NO is_interactable filter -- the actor flips that flag
-- only on close approach, so filtering hides candidates we should be
-- walking toward.  The interactable check happens in Execute.
local function find_enticement()
    return find.closest({
        patterns             = ENTICEMENT_PATTERNS,
        require_interactable = false,
        source               = 'all',   -- switches/destructibles live in get_all_actors
        -- No max_dist_sq: enticements are room-scale objectives and the
        -- actor stream bounds the search naturally.  WonderCity's
        -- comment: "Anything in actor stream is fair game."
        visited              = tracker.visited,
        visited_prefix       = 'enticement',
        filter               = function (a)
            -- Honor hearth cap; beacons are uncapped.
            local sn = a.get_skin_name and a:get_skin_name() or ''
            if is_hearth_skin(sn) and hearth_cap_reached() then
                return false
            end
            return true
        end,
    })
end

task.shouldExecute = function ()
    if not is_in_undercity() then return false end
    if settings.do_enticements == false then return false end
    if tracker.boss_seen then return false end       -- focus boss once visible
    if settings.speed_run == true and hearth_cap_reached() then return false end
    return find_enticement() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local actor = find_enticement()
    if not actor then
        task.interact_time = nil
        task.last_click_t  = nil
        task.click_count   = nil
        task.target_key    = nil
        task.status = 'no enticement'
        return
    end
    local p = actor:get_position()
    if not p then return end

    local sn = actor:get_skin_name() or '?'
    local d  = find.dist2d(pp, p)

    -- If the find returned a DIFFERENT actor than last pulse, reset the
    -- timers so the new target gets a fresh window.  Otherwise the old
    -- target's clicks would count against the new one.
    local cur_key = find.key_for('enticement', actor, p)
    if task.target_key ~= cur_key then
        task.target_key    = cur_key
        task.interact_time = nil
        task.last_click_t  = nil
        task.click_count   = nil
    end

    -- Per-actor timeout: hearths use enticement_timeout; beacons get a
    -- longer window because they're event-triggers (more time before
    -- declaring the actor "stuck").  Mirrors the original WonderCity
    -- distinction; we approximate the missing beacon_timeout with 2x
    -- of enticement_timeout when settings doesn't expose it.
    local timeout = settings.enticement_timeout or 4
    if not is_hearth_skin(sn) then
        timeout = (settings.beacon_timeout or (timeout * 2))
    end

    -- Timeout path: been waiting too long, mark visited + move on.  The
    -- next find_enticement() call will pick a different one (or nil).
    if task.interact_time and (task.interact_time + timeout) < (get_time_since_inject() or 0) then
        tracker.visited = tracker.visited or {}
        tracker.visited[find.key_for('enticement', actor, p)] = true
        if settings.debug_mode then
            console.print('[Undercity] enticement timeout, skipping: ' .. sn)
        end
        task.interact_time = nil
        task.status = 'timeout, skipped ' .. sn
        return
    end

    -- Walk phase: too far, move toward the actor via core.move (which
    -- now drives the internal walker -- no more direct Batmobile calls).
    if d > INTERACT_RANGE then
        move.to_actor(actor)
        task.status = string.format('walking to %s (%.0fm)', sn, d)
        return
    end

    -- Arrived.  Stop the walker so we don't drift past the actor.
    local wok, walker = pcall(require, 'core.walker')
    if wok and walker and walker.stop then walker.stop() end

    -- Click phase.  Retry-until-dead: keep firing interact_object on a
    -- cooldown until the actor's is_interactable() flips false (=
    -- consumed/dead) OR we hit the timeout (= probably stuck).  We do
    -- NOT mark visited on click -- only on success (no longer
    -- interactable) or timeout.  User-reported: clicks were sometimes
    -- silently rejected, and the previous "mark visited on click" path
    -- moved past the beacon without retrying.
    local now = get_time_since_inject() or 0
    if actor.is_interactable and actor:is_interactable() then
        -- Still interactable -> click again on cooldown.
        local CLICK_COOLDOWN_S = 1.0
        if (now - (task.last_click_t or 0)) >= CLICK_COOLDOWN_S then
            if orbwalker and orbwalker.set_clear_toggle then
                orbwalker.set_clear_toggle(false)
            end
            interact_object(actor)
            task.last_click_t = now
            task.click_count  = (task.click_count or 0) + 1
            -- Start the timeout window on the FIRST click (so a hung
            -- non-interactable transition doesn't get billed against
            -- a fresh approach).
            task.interact_time = task.interact_time or now
            if settings.debug_mode then
                console.print(string.format(
                    '[Undercity] click #%d on %s', task.click_count, sn))
            end
        end
        task.status = string.format('clicking %s (#%d)',
            sn, task.click_count or 0)
        return
    end

    -- Actor is no longer interactable -> success!  This is the canonical
    -- "consumed" signal regardless of whether our last click or some
    -- other event finished it.  Mark visited, accumulate the hearth
    -- count, restore orbwalker.
    tracker.visited = tracker.visited or {}
    tracker.visited[find.key_for('enticement', actor, p)] = true
    if is_hearth_skin(sn) then
        tracker.hearth_count = (tracker.hearth_count or 0) + 1
    end
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    if settings.debug_mode then
        console.print(string.format(
            '[Undercity] enticement consumed: %s (clicks=%d, hearth_count=%d)',
            sn, task.click_count or 0, tracker.hearth_count or 0))
    end
    task.interact_time = nil
    task.last_click_t  = nil
    task.click_count   = nil
    task.status = 'activated ' .. sn
end

return task
