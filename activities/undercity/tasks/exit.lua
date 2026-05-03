-- activities/undercity/tasks/exit.lua

local move          = require 'core.move'
local entry_portal  = require 'core.entry_portal'
local exit_grace    = require 'core.exit_grace'
local settings      = require 'activities.undercity.settings'
local tracker       = require 'activities.undercity.tracker'

local task = { name = 'exit', status = 'idle', debounce_t = nil }

-- Warp-pad interaction tunables.  Mirrors interact_enticement's
-- retry-on-cooldown pattern -- the user reported "walking to warp
-- pad but not interacting, or we need multiple interactions to make
-- sure it fires."  Single interact_object calls were silently
-- rejected sometimes; retrying on a cooldown until the actor flips
-- non-interactable (consumed) OR the zone changes (success) makes
-- entry reliable without spamming clicks.
--
-- WARP_INTERACT_RANGE_M:
--     Click-distance threshold.  D4 walks the player the last few
--     yards on its own from this range, so we don't need to be
--     literally on top of the pad before triggering.
-- WARP_CLICK_COOLDOWN_S:
--     Min seconds between two interact_object calls on the same
--     pad.  Same value (1.0s) the enticement task uses; tight
--     enough that arrival → first click is fast, loose enough that
--     we don't fire 20 clicks before the host can route the first.
-- WARP_TIMEOUT_S:
--     If we've been clicking for this long without a zone change,
--     give up and try a different exit (dungeon reset).  Belt-and-
--     braces against a permanently-broken pad.
local WARP_INTERACT_RANGE_M = 4.0
local WARP_CLICK_COOLDOWN_S = 1.0
local WARP_TIMEOUT_S        = 8.0

local function in_undercity()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    local z = w:get_current_zone_name()
    return z and z:sub(1, #'X1_Undercity_') == 'X1_Undercity_'
end

local function find_warp_pad()
    if not actors_manager then return nil end
    -- Scan both ally and all-actor lists.  D4 sometimes classifies
    -- destructible-style props (which the warp pad behaves like) into
    -- get_all_actors only -- mirrors the same fix interact_poi got.
    --
    -- Entry-portal exclusion: skip warp pads sitting right where the
    -- player teleported in.  In undercity that warp pad IS our exit
    -- (good!) but also IS the entry pad we just used (we'd click it
    -- the moment we land and bounce right back to town).  The
    -- post-teleport settle delay in tasks/warplan/enter_undercity.lua
    -- mostly covers this, but a redundant check here protects against
    -- any teleport flow that doesn't go through that delay path.
    local function scan(list)
        if not list then return nil end
        for _, a in pairs(list) do
            if a.get_skin_name and a:get_skin_name() == 'X1_Undercity_WarpPad' then
                if not entry_portal.is_actor_near_entry(a) then
                    return a
                end
            end
        end
        return nil
    end
    if actors_manager.get_ally_actors then
        local a = scan(actors_manager:get_ally_actors())
        if a then return a end
    end
    if actors_manager.get_all_actors then
        return scan(actors_manager:get_all_actors())
    end
    return nil
end

task.shouldExecute = function ()
    if not in_undercity() then return false end
    -- Universal 15s loot grace.  After chest_looted flips true,
    -- hold the run-done state long enough for ground-drop loot to
    -- be picked up.  Only the chest_looted path gates on this --
    -- the auto_reset_after timeout is already long enough that no
    -- additional grace is sensible there.
    if tracker.chest_looted and settings.exit_after_chest then
        if exit_grace.has_elapsed(tracker.chest_looted_t) then return true end
        task.status = string.format('looting (%.0fs left)',
            exit_grace.remaining(tracker.chest_looted_t))
        return false
    end
    -- The warp-pad branch is "the warp pad is visible because the run
    -- already ended on its own" -- no additional grace; if the user
    -- ran enabled-and-fast the chest_looted flow gated above already
    -- waited the full 15s.
    if find_warp_pad() then return true end
    if tracker.run_start_t
       and (tracker.run_start_t + settings.auto_reset_after) < get_time_since_inject()
    then return true end
    return false
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end

    -- Prefer warp pad when visible
    local warp = find_warp_pad()
    if warp then
        local pp = lp:get_position()
        local wp = warp:get_position()
        local d = math.sqrt((wp:x()-pp:x())^2 + (wp:y()-pp:y())^2)

        local now = get_time_since_inject() or 0

        if d <= WARP_INTERACT_RANGE_M then
            -- Stop the walker so we don't drift past the pad while
            -- we're trying to click it.  Mirrors the enticement
            -- arrival path.
            local wok, walker = pcall(require, 'core.walker')
            if wok and walker and walker.stop then walker.stop() end

            -- Retry-until-success.  Keep firing interact_object on a
            -- cooldown until either:
            --   * the pad flips non-interactable (consumed -- the
            --     warp completed)
            --   * the zone changes (we successfully exited)
            --   * WARP_TIMEOUT_S elapses (give up; the dungeon
            --     reset path below will handle exit).
            -- The previous one-shot interact_object lost a lot of
            -- click attempts to the host's race between "actor in
            -- stream" and "actor accepting interact" -- the cooldown
            -- retry mirrors interact_enticement's reliable pattern.
            if warp.is_interactable and not warp:is_interactable() then
                -- Already consumed -- shouldn't normally see this
                -- (we'd have zoned out), but treat as success.
                task.click_count = nil
                task.first_click_t = nil
                task.last_click_t  = nil
                task.status = 'warp pad consumed'
                return
            end

            -- Initialize counters on first click of a fresh pad.
            if not task.first_click_t then
                task.first_click_t = now
                task.click_count   = 0
                task.last_click_t  = -math.huge
            end

            -- Timeout: if we've been clicking forever, give up so the
            -- dungeon-reset path can run (set in shouldExecute by the
            -- run_start_t + auto_reset_after gate).
            if (now - task.first_click_t) > WARP_TIMEOUT_S then
                if settings.debug_mode then
                    console.print(string.format(
                        '[Undercity] warp pad: %d clicks, %.1fs, no exit -- giving up',
                        task.click_count or 0, now - task.first_click_t))
                end
                task.first_click_t = nil
                task.click_count   = nil
                task.last_click_t  = nil
                task.status = 'warp pad unresponsive'
                return
            end

            -- Cooldown gate.
            if (now - (task.last_click_t or 0)) >= WARP_CLICK_COOLDOWN_S then
                if orbwalker and orbwalker.set_clear_toggle then
                    orbwalker.set_clear_toggle(false)
                end
                interact_object(warp)
                task.last_click_t = now
                task.click_count  = (task.click_count or 0) + 1
                if settings.debug_mode then
                    console.print(string.format(
                        '[Undercity] warp pad click #%d', task.click_count))
                end
            end
            task.status = string.format('using warp pad (#%d)', task.click_count or 0)
            return
        end

        -- Out of range -- walk closer.  Reset retry state so the
        -- click counter starts fresh once we arrive (otherwise a
        -- previous-arrival's stale timer would rule us out).
        task.first_click_t = nil
        task.click_count   = nil
        task.last_click_t  = nil
        move.to_actor(warp)
        task.status = string.format('walking to warp pad (%.0fm)', d)
        return
    end

    -- No warp pad: dungeon reset
    local now = get_time_since_inject() or 0
    if task.debounce_t and (task.debounce_t + 5 > now) then
        task.status = 'reset issued, waiting'
        return
    end
    task.debounce_t = now
    if settings.debug_mode then console.print('[Undercity] reset_all_dungeons') end
    if reset_all_dungeons then reset_all_dungeons() end
    task.status = 'reset_all_dungeons'
end

return task
