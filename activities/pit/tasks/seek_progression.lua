-- ---------------------------------------------------------------------------
-- activities/pit/tasks/seek_progression.lua
--
-- Pick the next progression POI (pit_floor_portal / pit_exit /
-- dungeon_entrance) and walk toward it.
--
-- Two implementations, picked at runtime:
--
--   PATH A (preferred): WarPath sequencer.  When WarPathPlugin
--   exposes find_and_take_portal (newer bundles), we hand the goal to
--   the sequencer once per floor descent.  It runs the user's exact
--   pit-floor flow: explore the room until coverage is high AND a
--   pit_floor_portal has been spotted (bookmarked), then walk to the
--   bookmarked portal and click it.  kill_monster (higher in the
--   runner chain) preempts this task whenever an enemy is in
--   kill_range, so the sequencer's combat_guard pauses movement
--   automatically while the bot fights.
--
--   PATH B (legacy): catalog scan + walker.  Used when WarPath is
--   older / not present.  Same logic that shipped before: pick the
--   closest non-stale, non-visited progression POI, set the walker's
--   target, observe whether we're making progress, mark stale on
--   stall.
--
-- The runtime branch is decided per-pulse in shouldExecute -- so a
-- mid-session WarPath upgrade flips to PATH A on the next pulse with
-- no restart needed.  PATH B remains the fallback for zones the
-- preloader hasn't reached yet.
-- ---------------------------------------------------------------------------

local move    = require 'core.move'
local nav     = require 'core.nav'
local zone    = require 'core.zone'
local find    = require 'core.find'
local reach   = require 'core.reach'
local tracker = require 'activities.pit.tracker'

local task = { name = 'seek_progression', status = 'idle' }

-- ---- Tunables (shared) ----
local PROGRESSION_KINDS = {
    pit_floor_portal = true,
    pit_exit         = true,
    dungeon_entrance = true,
}
local ENEMY_KINDS = {
    champion = true,
    elite    = true,
    boss     = true,
}
local INTERACT_RADIUS  = 4.0
-- Back-portal blacklist radius (5y squared).  Updated 2026-05 to
-- match the corrected geometry: pit floor descents spawn the player
-- ON TOP of the back portal, not ~22y away.  Same default as
-- core/entry_portal.  See pit/floor_portal.lua for context.
local BACK_PORTAL_R_SQ = 25
local STUCK_TIMEOUT_S  = 10.0
local STALE_RETRY_S    = 30.0
local PROGRESS_DELTA   = 4.0
local LIVE_PORTAL_NEAR_R = 8.0
local LIVE_PORTAL_PATTERN = 'Portal_Dungeon'
local MAX_CANDIDATE_RANGE = 25.0

-- Sequencer goal coverage threshold.  Lower than 1.0 so we don't
-- waste real time exploring corners of the room when we've already
-- bookmarked the portal.  Higher than 0.5 so we generally wait until
-- the back-portal area has been swept.
local SEQ_COVERAGE_TARGET = 0.7

-- ---- PATH A state (sequencer-driven) ----
-- We start the sequencer once per floor (key = world_id) and let it
-- run.  When the floor changes we abort + restart so the next-floor's
-- new exploration state takes over.
local _seq_world_id = nil
local _seq_started_at = nil

-- ---- PATH B state (legacy walker) ----
local _stale = {}
local _target_key      = nil
local _target_set_t    = nil
local _last_arrived_dist = nil

-- ---- Shared helpers ----

local function poi_key(a)
    return string.format('%s:%d:%d',
        a.skin or '?',
        math.floor(a.x or 0),
        math.floor(a.y or 0))
end

local function in_back_portal_blacklist(a)
    local back = tracker.back_portal_pos
    if not back then return false end
    local dx = (a.x or 0) - back.x
    local dy = (a.y or 0) - back.y
    return (dx*dx + dy*dy) < BACK_PORTAL_R_SQ
end

local function has_live_portal_nearby(pp, radius)
    if not actors_manager or not actors_manager.get_all_actors then return false end
    local r2 = radius * radius
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if sn:find(LIVE_PORTAL_PATTERN, 1, true)
           and not sn:find('Light_NoShadows', 1, true)
        then
            local p = a:get_position()
            if p then
                local dx = p:x() - pp:x()
                local dy = p:y() - pp:y()
                if dx*dx + dy*dy <= r2 then return true end
            end
        end
    end
    return false
end

local function is_stale(key, now)
    local t = _stale[key]
    if not t then return false end
    if (now - t) >= STALE_RETRY_S then
        _stale[key] = nil
        return false
    end
    return true
end

local function get_world_id()
    local w = get_current_world()
    return w and w.get_world_id and w:get_world_id() or nil
end

-- ---------------------------------------------------------------------------
-- PATH A: sequencer-driven
-- ---------------------------------------------------------------------------

local function seq_combat_guard(_ctx)
    -- True = HOLD movement.  Hold whenever an enemy is in kill range,
    -- so kill_monster (higher priority) gets the pulse.  Note:
    -- kill_monster is RUNNER-priority, not sequencer-driven, so even
    -- without this guard kill_monster would preempt seek_progression's
    -- shouldExecute.  But we still set the guard so the sequencer
    -- doesn't try to replan a path mid-fight.
    return find.any_enemy_in_range(15)
end

local function seq_interact_fn(_ctx)
    -- The sequencer arrived at the bookmarked portal.  Find the live
    -- portal actor in the stream and interact with it.  If no live
    -- portal exists this run (the catalog coord wasn't where the
    -- portal actually spawned), we abort so PATH A can re-attempt
    -- with explore_until on the next pulse.
    if not actors_manager or not actors_manager.get_all_actors then return end
    local lp = get_local_player()
    local pp = lp and lp:get_position()
    if not pp then return end
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if sn:find(LIVE_PORTAL_PATTERN, 1, true)
           and not sn:find('Light_NoShadows', 1, true)
           and a.is_interactable and a:is_interactable()
        then
            local p = a:get_position()
            if p then
                local dx = p:x() - pp:x()
                local dy = p:y() - pp:y()
                if dx*dx + dy*dy <= LIVE_PORTAL_NEAR_R * LIVE_PORTAL_NEAR_R then
                    tracker.portal_just_used = true
                    tracker.portal_used_t = get_time_since_inject() or 0
                    interact_object(a)
                    return
                end
            end
        end
    end
end

local function start_sequencer_goal()
    local ok, why = nav.find_and_take_portal({
        target_kind     = 'pit_floor_portal',
        target_coverage = SEQ_COVERAGE_TARGET,
        interact_fn     = seq_interact_fn,
        combat_guard    = seq_combat_guard,
        on_complete = function (_ctx)
            -- Sequencer succeeded; portal click happened.  Floor change
            -- is detected by floor_portal.lua's update_world_tracking
            -- on the next pulse.  Nothing to do here.
        end,
        on_abort = function (_ctx, reason)
            -- Most common: 'fully_explored' / 'no_frontier' -- the
            -- room is fully swept but no portal was spotted.  Drop
            -- back to PATH B for the rest of this floor.
            console.print('[Pit] sequencer aborted: ' .. tostring(reason)
                .. ' -- falling back to legacy seeker')
            _seq_world_id = -1   -- sentinel: don't re-attempt this floor
        end,
    })
    if ok then
        _seq_world_id   = get_world_id()
        _seq_started_at = get_time_since_inject() or 0
    else
        -- WarPath capability check failed; mark this floor as PATH-B
        -- only so we don't keep retrying every pulse.
        _seq_world_id = -1
    end
end

-- Returns true when PATH A is currently driving, false when PATH B
-- should run (or the activity is between goals).
local function path_a_active()
    if not nav.has_sequencer() then return false end
    local wid = get_world_id()
    if not wid then return false end
    -- Floor change?  Restart the goal.
    if _seq_world_id ~= wid and _seq_world_id ~= -1 then
        if nav.is_active() then nav.abort('floor_change') end
        start_sequencer_goal()
    end
    -- Sentinel: this floor was abandoned by the sequencer; PATH B owns it.
    if _seq_world_id == -1 then return false end
    -- Goal not started yet?
    if not nav.is_active() then
        start_sequencer_goal()
        return nav.is_active()
    end
    return true
end

-- ---------------------------------------------------------------------------
-- PATH B: legacy catalog scan
-- ---------------------------------------------------------------------------

-- Reachability budget for catalog scan.  Cap A* calls per pulse so
-- a long candidate list can't pin the game thread.
local SEEK_REACH_BUDGET = 4

-- Pick the closest reachable catalog actor matching `kind_set`.  Uses
-- core/reach.first_reachable for the budgeted A* walk, layered on
-- pit-specific filters (back-portal blacklist, MAX_CANDIDATE_RANGE,
-- walkability probe).
local function pick_closest_kind(pp, now, kind_set)
    local plug = rawget(_G, 'WarPathPlugin') or rawget(_G, 'StaticPatherPlugin')
    if not plug or not plug.get_actors then return nil end
    local ok, actors = pcall(plug.get_actors)
    if not ok or not actors then return nil end

    -- Build distance-sorted candidate list passing the cheap filters.
    -- Activity-specific bits stay inline: pit's back_portal blacklist,
    -- MAX_CANDIDATE_RANGE, the walkability probe.
    local candidates = {}
    for _, a in ipairs(actors) do
        if kind_set[a.kind or ''] then
            local key = poi_key(a)
            if not (tracker.visited and tracker.visited[key])
               and not in_back_portal_blacklist(a)
               and not is_stale(key, now)
            then
                local dx = (a.x or 0) - pp:x()
                local dy = (a.y or 0) - pp:y()
                local d  = math.sqrt(dx*dx + dy*dy)
                if d <= MAX_CANDIDATE_RANGE then
                    local walkable = true
                    if utility and utility.is_point_walkeable then
                        local probe = vec3:new(a.x or 0, a.y or 0, a.z or pp:z())
                        local sok, w = pcall(utility.is_point_walkeable, probe)
                        walkable = sok and w == true
                    end
                    if walkable then
                        candidates[#candidates + 1] = { actor = a, dist = d, key = key }
                    end
                end
            end
        end
    end
    table.sort(candidates, function (u, v) return u.dist < v.dist end)
    if #candidates == 0 then return nil, math.huge end

    -- Reach-filtered pick via the shared primitive.  Soft-stale any
    -- candidate that the picker walked past as unreachable so we
    -- don't re-A* it every pulse while exploring around it.
    local picked, picked_idx = reach.first_reachable(
        candidates,
        function (c)
            return vec3:new(c.actor.x or 0, c.actor.y or 0, c.actor.z or pp:z())
        end,
        { player_pos = pp, budget = SEEK_REACH_BUDGET }
    )
    if not picked then return nil, math.huge end

    -- Mark every candidate the picker walked past stale (the ones it
    -- A*-checked and rejected).  Picked_idx tells us where it stopped.
    for i = 1, (picked_idx or 0) - 1 do
        _stale[candidates[i].key] = now
    end
    return picked.actor, picked.dist
end

local function pick_closest(pp, now)
    local poi, d = pick_closest_kind(pp, now, PROGRESSION_KINDS)
    if poi then return poi, d end
    return pick_closest_kind(pp, now, ENEMY_KINDS)
end

-- ---------------------------------------------------------------------------
-- shouldExecute / Execute
-- ---------------------------------------------------------------------------

task.shouldExecute = function ()
    if not zone.in_pit() then
        if nav.is_active() then nav.abort('left_pit') end
        return false
    end
    if find.any_enemy_in_range(25) then return false end   -- yield to combat

    -- PATH A: if WarPath sequencer is available, let it own the floor.
    -- shouldExecute returns false here because the sequencer drives
    -- movement via WarPath's own on_update tick; we don't need this
    -- task's Execute to fire.  We just keep checking each pulse so
    -- floor changes / aborts re-attach.
    if path_a_active() then
        task.status = 'sequencer driving (' .. tostring(get_world_id()) .. ')'
        return false
    end

    -- PATH B: legacy.
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end
    local now = get_time_since_inject() or 0
    local poi, d = pick_closest(pp, now)
    if not poi then return false end
    if d <= INTERACT_RADIUS then
        if not has_live_portal_nearby(pp, LIVE_PORTAL_NEAR_R) then
            _stale[poi_key(poi)] = now
        end
        return false
    end
    task._poi = poi
    task._d   = d
    return true
end

task.Execute = function ()
    -- This only fires on PATH B.  PATH A never reaches Execute because
    -- shouldExecute returned false while it was active.
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local now = get_time_since_inject() or 0
    local poi = task._poi
    if not poi then task.status = 'no POI'; return end
    local key = poi_key(poi)

    if _target_key ~= key then
        _target_key            = key
        _target_set_t          = now
        _last_arrived_dist     = task._d
    end

    local elapsed = now - (_target_set_t or now)
    if elapsed >= STUCK_TIMEOUT_S then
        local progressed = _last_arrived_dist and (_last_arrived_dist - task._d) >= PROGRESS_DELTA
        if not progressed then
            _stale[key] = now
            _target_key = nil
            move.clear()
            task.status = string.format('stale %s @ (%.0f,%.0f) -- retry in %ds',
                poi.kind or '?', poi.x or 0, poi.y or 0, STALE_RETRY_S)
            return
        end
        _target_set_t      = now
        _last_arrived_dist = task._d
    end

    move.to_pos({ x = poi.x, y = poi.y, z = poi.z or pp:z() },
                { arrive_radius = INTERACT_RADIUS })
    task.status = string.format('walking to %s @ (%.0f,%.0f) %.0fm (legacy)',
        poi.kind or '?', poi.x or 0, poi.y or 0, task._d)
end

return task
