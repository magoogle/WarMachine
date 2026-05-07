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

-- Module-level "known consumed" map.  When Execute walks the player
-- into close range of an enticement and observes is_interactable=false
-- there, the actor was either consumed (most likely) or it's a
-- broken / mis-classified prop.  Either way, we shouldn't walk to it
-- again -- caching the key here lets find_enticement filter it out
-- BEFORE picking it as a target on the next pulse.  (tracker.visited
-- is checked inside find.closest, so we layer onto that without
-- mutating it directly -- visited is consumer-shared and filling it
-- with non-confirmed entries would pollute interact_poi's view.)
--
-- Cleared on zone change via tracker.zone_changed callback (see below).
local _confirmed_consumed = {}

-- D4 streams enticements as non-interactable when the player is far
-- away.  We can only safely declare "consumed" once we've been close
-- enough that the flag should have flipped to true if it were going
-- to.  CONFIRMED_RANGE_M is the radius inside which a non-interactable
-- enticement is treated as consumed.  Picked at 8y because the click
-- threshold (INTERACT_RANGE) is 3y -- by 8y the bot has been visibly
-- "approaching" for several seconds and D4 has had every chance to
-- flip the flag.
local CONFIRMED_RANGE_M = 8.0

-- Combat-yield range.  When any hostile is within this range,
-- shouldExecute returns false so kill_monster (lower priority) gets
-- the pulse.  Fixes the "walks to enticement, mobs spawn, bot never
-- stops to fight" symptom -- previously interact_enticement just
-- ran straight to the next enticement while mobs chewed the bot.
local COMBAT_YIELD_RANGE_M = 15.0

-- Post-consume anchor.  After clicking an enticement and the actor
-- flips to non-interactable, we set ANCHOR = the enticement's
-- position and HOLD here until no hostile is within
-- ANCHOR_CLEAR_RANGE_M of the anchor.  Two reasons:
--
--   1) Enticement clicks spawn mob waves AT the enticement.  If the
--      bot wanders off to the next-closest enticement before the
--      wave is dead, we leave a contested area behind us full of
--      hostiles that gradually chase + chew the bot.
--   2) The user-spec'd flow: "once no mobs are within 8-10 yards of
--      that enticement, we can move on and consider that specific
--      one done."  Cleared-the-room semantics, not cleared-around-me.
--
-- Anchor expires after ANCHOR_MAX_HOLD_S as a safety net so a stuck
-- mob (off-mesh, behind a wall) can't trap us forever.
local _post_consume_anchor = nil   -- { x, y, set_t }
local ANCHOR_CLEAR_RANGE_M = 10.0
local ANCHOR_MAX_HOLD_S    = 30.0

-- Returns true if any hostile is within `radius` of (ax, ay).  Uses
-- the host's near-target list -- same primitive UR + kill_monster use.
local function any_enemy_near_anchor(ax, ay, radius)
    if not target_selector or not target_selector.get_near_target_list then
        return false
    end
    -- get_near_target_list takes the player position; pass a vec3
    -- centered on the anchor (the host doesn't care that it isn't
    -- actually the player's position for the search call).
    local probe = vec3:new(ax, ay, 0)
    if utility and utility.set_height_of_valid_position then
        local ok, snapped = pcall(utility.set_height_of_valid_position, probe)
        if ok and snapped then probe = snapped end
    end
    local enemies = nil
    pcall(function () enemies = target_selector.get_near_target_list(probe, radius) end)
    if not enemies or #enemies == 0 then return false end
    -- Some hosts return EVERY actor as a stub even when out of range;
    -- recompute distance to be sure.  Cheap on small lists.
    local r2 = radius * radius
    for _, e in pairs(enemies) do
        local hp = e.get_current_health and e:get_current_health() or 0
        if hp > 1 then
            local p = e.get_position and e:get_position() or nil
            if p then
                local dx, dy = p:x() - ax, p:y() - ay
                if (dx*dx + dy*dy) <= r2 then return true end
            end
        end
    end
    return false
end

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

-- Re-find the actor we were last engaged with by skin+coord key.
-- D4 REMOVES the SpiritHearth_Switch / SpiritBeacon_Switch actor from
-- the stream entirely once it's consumed (it doesn't just flip
-- is_interactable=false).  So the actor's absence from the stream
-- IS the success signal -- if find_actor_by_key returns nil while
-- we have an active engagement, the click landed.
local function find_actor_by_key(key)
    if not key or not actors_manager or not actors_manager.get_all_actors then
        return nil
    end
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn then
            local p = a.get_position and a:get_position() or nil
            if p and find.key_for('enticement', a, p) == key then
                return a
            end
        end
    end
    return nil
end

-- Find the closest enticement we haven't interacted with yet.
-- Crucially: NO is_interactable filter at the find layer -- the
-- actor flips that flag only on close approach, so filtering on it
-- in find would hide candidates we should be walking toward.  The
-- interactable check happens in Execute.
--
-- BUT we DO filter:
--   * Actors marked in tracker.visited (consumed earlier this run)
--   * Actors marked in _confirmed_consumed (we got close, saw the
--     flag false, treated as consumed -- prevents walking to dead
--     enticements still in stream)
--   * Hearths past the cap
local function find_enticement()
    return find.closest({
        patterns             = ENTICEMENT_PATTERNS,
        require_interactable = false,
        source               = 'all',   -- switches/destructibles live in get_all_actors
        visited              = tracker.visited,
        visited_prefix       = 'enticement',
        filter               = function (a, p)
            -- Skip "we already learned this one is consumed" -- bot got
            -- close, observed is_interactable=false, treats as done.
            local key = find.key_for('enticement', a, p)
            if _confirmed_consumed[key] then return false end

            -- Honor hearth cap; beacons are uncapped.
            local sn = a.get_skin_name and a:get_skin_name() or ''
            if is_hearth_skin(sn) and hearth_cap_reached() then
                return false
            end

            -- (No is_dead filter.  The host's is_dead predicate is
            -- defined on every game.object and its return value for
            -- non-living world props -- switches, levers, hearths --
            -- is unreliable: some hosts default it to true for objects
            -- with no health, which silently filtered out every fresh
            -- SpiritHearth_Switch.  The _confirmed_consumed close-range
            -- check + tracker.visited cover the "already clicked" case
            -- without the false-positive risk.)
            return true
        end,
    })
end

-- Public hook: clear the consumed map when the player changes zones,
-- since on a fresh enter every enticement is potentially fresh again.
-- runner / tracker can call this if they wire it up; harmless if not.
local function _reset_consumed_for_zone()
    _confirmed_consumed = {}
end

task.shouldExecute = function ()
    if not is_in_undercity() then return false end
    if settings.do_enticements == false then return false end
    if tracker.boss_seen then return false end       -- focus boss once visible
    if settings.speed_run == true and hearth_cap_reached() then return false end

    -- POST-CONSUME ANCHOR.  After clicking an enticement, hold here
    -- (don't pick a new target) until the spawned mob wave is dead.
    -- "Dead" = no hostile within ANCHOR_CLEAR_RANGE_M of the anchor
    -- position.  Anchor expires after ANCHOR_MAX_HOLD_S so a stuck /
    -- off-mesh mob can't pin us forever.
    if _post_consume_anchor then
        local now = get_time_since_inject() or 0
        if (now - _post_consume_anchor.set_t) > ANCHOR_MAX_HOLD_S then
            if settings.debug_mode then
                console.print('[Undercity] anchor timed out, releasing')
            end
            _post_consume_anchor = nil
        elseif any_enemy_near_anchor(
                  _post_consume_anchor.x, _post_consume_anchor.y,
                  ANCHOR_CLEAR_RANGE_M) then
            -- Yield to kill_monster (lower priority) so it engages the
            -- mobs near the anchor.  We'll reclaim once they're dead.
            return false
        else
            -- Mobs cleared near anchor.  Release it; the next claim
            -- below will pick the next-closest enticement.
            _post_consume_anchor = nil
        end
    end

    -- COMBAT YIELD.  Clicking an enticement spawns a mob wave; if we
    -- don't stop to fight them they shred us while we walk to the next
    -- enticement (the user-reported "walks to enticement but doesn't
    -- stay to fight" symptom).  Yield to kill_monster (lower runner
    -- priority) whenever a hostile is within COMBAT_YIELD_RANGE_M --
    -- it claims the pulse, fights, and when the wave is dead its
    -- shouldExecute returns false again, letting interact_enticement
    -- reclaim and walk to the next target.
    if find.any_enemy_in_range(COMBAT_YIELD_RANGE_M) then return false end

    return find_enticement() ~= nil
end

-- Fire the success path for a previously-engaged enticement that has
-- disappeared from the actor stream.  Uses cached pos/skin since the
-- live actor is gone.  Idempotent: clears all engagement state.
local function _on_consumed(now)
    local key = task.target_key
    local p   = task.target_pos
    local sn  = task.target_skin or '?'
    if key then
        tracker.visited = tracker.visited or {}
        tracker.visited[key] = true
        _confirmed_consumed[key] = true
    end
    if p then
        _post_consume_anchor = { x = p.x, y = p.y, set_t = now }
    end
    if is_hearth_skin(sn) then
        tracker.hearth_count = (tracker.hearth_count or 0) + 1
    end
    tracker.enticements_this_floor = (tracker.enticements_this_floor or 0) + 1
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    if settings.debug_mode then
        console.print(string.format(
            '[Undercity] enticement consumed (actor removed): %s ' ..
            '(clicks=%d, hearth_count=%d, floor=%d)',
            sn, task.click_count or 0,
            tracker.hearth_count or 0,
            tracker.enticements_this_floor or 0))
    end
    move.resume()
    task.target_key    = nil
    task.target_pos    = nil
    task.target_skin   = nil
    task.interact_time = nil
    task.last_click_t  = nil
    task.click_count   = nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local now = get_time_since_inject() or 0

    -- ----------------------------------------------------------------
    -- Step 1: if we have an active engagement, check whether the
    -- engaged actor is still in the actor stream.  Disappearance ==
    -- consumed (D4 removes the actor entirely once activated, NOT
    -- just flipping is_interactable=false -- per user observation).
    -- ----------------------------------------------------------------
    if task.target_key then
        local engaged = find_actor_by_key(task.target_key)
        if not engaged then
            _on_consumed(now)
            task.status = 'activated ' .. (task.target_skin or 'enticement')
            return
        end
        -- Engaged actor still in stream.  Continue the walk/click
        -- loop on it.  We re-use the `engaged` reference below so we
        -- never operate on a stale object.
    end

    -- ----------------------------------------------------------------
    -- Step 2: pick a target.  Prefer the engaged actor (continuity);
    -- otherwise pick the next closest unvisited enticement.
    -- ----------------------------------------------------------------
    local actor = task.target_key and find_actor_by_key(task.target_key)
                  or find_enticement()
    if not actor then
        task.interact_time = nil
        task.last_click_t  = nil
        task.click_count   = nil
        task.target_key    = nil
        task.target_pos    = nil
        task.target_skin   = nil
        move.resume()
        task.status = 'no enticement'
        return
    end
    local p = actor:get_position()
    if not p then return end

    local sn = actor:get_skin_name() or '?'
    local d  = find.dist2d(pp, p)

    -- If the find returned a DIFFERENT actor than last pulse, reset the
    -- timers so the new target gets a fresh window.  Snapshot the
    -- pos+skin onto the task so the success path can reference them
    -- after the live actor disappears from the stream.
    local cur_key = find.key_for('enticement', actor, p)
    if task.target_key ~= cur_key then
        task.target_key    = cur_key
        task.target_pos    = { x = p:x(), y = p:y(), z = p:z() }
        task.target_skin   = sn
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
        -- Release the nav so freeroam / other tasks can take over.
        move.resume()
        task.status = 'timeout, skipped ' .. sn
        return
    end

    -- Walk phase: too far, move toward the actor via nav.  We use
    -- move.to_pos() rather than move.to_actor() because D4 ignores
    -- interact_object() on actors that aren't yet interactable -- Spirit
    -- Hearths and Beacons report is_interactable=false until the player
    -- is close, so move.to_actor (= interact_object) is silently dropped
    -- and the bot never moves.  move.to_pos drives nav to the actor's
    -- world position, which works regardless of interactable state.
    if d > INTERACT_RANGE then
        -- Make sure nav isn't paused from a prior arrival on a
        -- different enticement.
        if move.is_paused and move.is_paused() then move.resume() end
        move.to_pos({ x = p:x(), y = p:y(), z = p:z() }, INTERACT_RANGE)
        task.status = string.format('walking to %s (%.0fm)', sn, d)
        return
    end

    -- Arrived.  PAUSE the nav (sticky) so the explorer's frontier
    -- picker doesn't grab a new target the moment we stop calling
    -- move.to_pos.  Without this, the nav reports "reached" the
    -- enticement, the internal explorer immediately picks a 28y
    -- frontier, and the player gets dragged away mid-click -- the
    -- user-reported "click #1, then walks off, click #2 misses,
    -- timeout" symptom.  move.resume() is called on every exit path
    -- below (consume / timeout / target-changed).
    move.pause()
    local wok, walker = pcall(require, 'core.walker')
    if wok and walker and walker.stop then walker.stop() end

    -- Click loop.  Per user direction: D4 REMOVES the actor entirely
    -- once an enticement is activated -- it doesn't just flip
    -- is_interactable=false.  So the actor's disappearance from the
    -- stream is the success signal (handled at the top of Execute via
    -- find_actor_by_key).  We click on cooldown REGARDLESS of the
    -- is_interactable flag -- D4's host treats interact_object on a
    -- non-interactable actor as a no-op, and the click stops being
    -- wasted as soon as the actor flips interactable on close approach.
    local CLICK_COOLDOWN_S = 1.0
    if (now - (task.last_click_t or 0)) >= CLICK_COOLDOWN_S then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(actor)
        task.last_click_t = now
        task.click_count  = (task.click_count or 0) + 1
        -- Start the timeout window on the FIRST click so a hung
        -- non-interactable transition doesn't get billed against a
        -- fresh approach.
        task.interact_time = task.interact_time or now
        if settings.debug_mode then
            console.print(string.format(
                '[Undercity] click #%d on %s', task.click_count, sn))
        end
    end
    task.status = string.format('clicking %s (#%d)',
        sn, task.click_count or 0)
end

return task
