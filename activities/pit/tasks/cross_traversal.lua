-- ---------------------------------------------------------------------------
-- activities/pit/tasks/cross_traversal.lua
--
-- Force-walk + interact fallback for `Traversal_Gizmo` actors (climb up,
-- climb down, jump, slide).  D4's pathfinder operates on flat 2D walkable
-- tiles and CANNOT route through traversals -- when the next floor portal
-- (or kill target, or pit objective) sits on the other side of a cliff,
-- WarMachineNav's set_target rejects the goal as unreachable and the
-- bot stalls.
--
-- This task takes priority over the regular movement chain whenever an
-- interactable Traversal_Gizmo is in stream within TRAV_SEARCH_RADIUS.
-- It bypasses the pathfinder entirely:
--   1. Pick the best gizmo (direction-aware: prefer the trav whose Z
--      direction matches the visible Portal_Dungeon's offset, default
--      "Up" for pit-typical ascents).
--   2. Force-walk straight to it via move.to_pos with a tight arrive
--      radius -- the pathfinder approximates a 2D line; for a single-
--      cliff trav that's good enough since the player is already
--      standing close to the edge.
--   3. Once within INTERACT_DIST, fire interact_object(trav) on a
--      cooldown.  D4 plays the climb / jump animation and teleports
--      the player to the other side.
--   4. Detect the cross via player position delta >= CROSS_DETECT_DIST
--      (climb teleport snaps the player far in 1 frame).  After the
--      cross, suppress re-engagement for POST_CROSS_COOLDOWN seconds
--      so the inverse trav at the landing spot can't re-fire and pull
--      us back across.
--   5. Time out the engagement after ENGAGEMENT_TIMEOUT and blacklist
--      ineffective travs (INEFFECTIVE_THRESHOLD interacts with no
--      player movement = trav is unusable for some reason -- different
--      Z than expected, animation didn't play, etc.).
--
-- Pattern ported from ArkhamAsylum-1.0.6/tasks/cross_traversal.lua,
-- adapted to use WarMachine's core.move (no Batmobile dependency).
-- ---------------------------------------------------------------------------

local move    = require 'core.move'
local find    = require 'core.find'
local zone    = require 'core.zone'

local task = {
    name   = 'cross_traversal',
    status = 'idle',
}

local TRAV_SEARCH_RADIUS    = 30      -- yards; matches Arkham's nav cap
local INTERACT_DIST         = 3       -- yards; range for interact_object to fire
local INTERACT_COOLDOWN     = 1.5     -- seconds between interact retries
local ENGAGEMENT_TIMEOUT    = 12      -- seconds before bailing on a stuck trav
local CROSS_DETECT_DIST     = 10      -- yards player-position-delta = cross succeeded
local POST_CROSS_COOLDOWN   = 5       -- seconds to suppress re-engage after a cross
local INEFFECTIVE_THRESHOLD = 3       -- interact retries with no movement = trav unusable
local TRAV_BLACKLIST_TTL    = 60      -- seconds; ineffective travs ignored this long
local TRAV_SCAN_TTL         = 0.25    -- find_best_trav cache window

-- Module state (one engagement at a time).
local _last_interact_t      = -math.huge
local _last_cross_t         = -math.huge
local _engagement_start     = -math.huge
local _engagement_pos       = nil
local _interact_count       = 0
local _pos_at_last_interact = nil

-- find_best_trav cache: scanning all actors every pulse to look for a
-- gizmo is wasteful when the answer doesn't change frame-to-frame.
local _cached_trav      = nil
local _cached_trav_dist = nil
local _cached_trav_t    = -math.huge

-- Per-trav blacklist: keyed by rounded (x, y, z); stamped when an
-- engagement times out without crossing.
local _blacklist = {}

local function blacklist_key(p)
    return string.format('%d:%d:%d',
        math.floor(p:x()), math.floor(p:y()), math.floor(p:z()))
end

local function is_blacklisted(now, p)
    local key = blacklist_key(p)
    local exp = _blacklist[key]
    if not exp then return false end
    if now > exp then
        _blacklist[key] = nil
        return false
    end
    return true
end

local function blacklist(now, p, reason)
    _blacklist[blacklist_key(p)] = now + TRAV_BLACKLIST_TTL
    -- (Diag printed by caller via task.status; no console spam here.)
end

-- Determine which Z direction the bot wants to travel.  We sniff for the
-- nearest interactable Portal_Dungeon (the floor portal we're trying to
-- reach) and bias toward its Z offset.  If no portal visible, default Up
-- since pit floors are stacked vertically and ascent is the typical
-- forward direction.
local function preferred_z_dir(player_z)
    if not actors_manager or not actors_manager.get_all_actors then return 1 end
    local actors = actors_manager:get_all_actors()
    for _, a in pairs(actors) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn and sn:find('Portal_Dungeon', 1, true)
           and not sn:find('Light_NoShadows', 1, true)
           and a.is_interactable and a:is_interactable()
        then
            local p = a.get_position and a:get_position() or nil
            if p then
                local dz = p:z() - player_z
                if dz >  1 then return  1 end
                if dz < -1 then return -1 end
            end
        end
    end
    return 1
end

-- Find the best Traversal_Gizmo within range.  Direction-aware:
-- wrong-direction climbs are excluded entirely so we don't bounce
-- between an Up and Down gizmo at the same cliff edge.  Returns
-- (actor, distance) or (nil, nil).
local function find_best_trav()
    local now = get_time_since_inject() or 0
    if (now - _cached_trav_t) < TRAV_SCAN_TTL then
        return _cached_trav, _cached_trav_dist
    end

    local lp = get_local_player()
    if not lp then
        _cached_trav, _cached_trav_dist, _cached_trav_t = nil, nil, now
        return nil, nil
    end
    local pp = lp:get_position()
    if not pp or not actors_manager or not actors_manager.get_all_actors then
        _cached_trav, _cached_trav_dist, _cached_trav_t = nil, nil, now
        return nil, nil
    end

    local want_dir = preferred_z_dir(pp:z())
    local best, best_d, best_score = nil, math.huge, -math.huge

    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn and sn:find('Traversal_Gizmo', 1, true)
           and a.is_interactable and a:is_interactable()
        then
            local p = a.get_position and a:get_position() or nil
            if p then
                local d = find.dist2d(pp, p)
                if d <= TRAV_SEARCH_RADIUS and not is_blacklisted(now, p) then
                    -- Direction inferred from skin substring; Up/Down
                    -- are the only ones we care about.  Direction-
                    -- neutral (Jump_, Slide_) gets dir = 0 and stays
                    -- eligible regardless of want_dir.
                    local trav_dir = 0
                    if     sn:find('Up',   1, true) then trav_dir =  1
                    elseif sn:find('Down', 1, true) then trav_dir = -1 end

                    if trav_dir == 0 or trav_dir == want_dir then
                        local score = (trav_dir == want_dir and 100 or 0) - d
                        if score > best_score then
                            best, best_d, best_score = a, d, score
                        end
                    end
                end
            end
        end
    end

    _cached_trav, _cached_trav_dist, _cached_trav_t = best, (best and best_d or nil), now
    return best, best_d
end

local function reset_engagement()
    _engagement_start     = -math.huge
    _engagement_pos       = nil
    _interact_count       = 0
    _pos_at_last_interact = nil
end

-- ---------------------------------------------------------------------------
-- Task lifecycle
-- ---------------------------------------------------------------------------
task.shouldExecute = function ()
    if not zone.in_pit() then return false end

    local now = get_time_since_inject() or 0
    -- Post-cross suppression: after a successful teleport we wait so the
    -- inverse trav at the landing spot doesn't immediately re-engage.
    if (now - _last_cross_t) < POST_CROSS_COOLDOWN then return false end

    local trav = find_best_trav()
    return trav ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local now = get_time_since_inject() or 0

    local trav, dist = find_best_trav()
    if not trav then
        reset_engagement()
        task.status = 'no trav'
        return
    end

    -- New engagement: stamp start + initial position.
    if _engagement_pos == nil then
        _engagement_start     = now
        _engagement_pos       = pp
        _interact_count       = 0
        _pos_at_last_interact = nil
    end

    local tp = trav:get_position()
    if not tp then return end
    local sn = trav:get_skin_name() or 'Traversal_Gizmo'

    -- Engagement timeout: blacklist this trav so future scans skip it.
    if (now - _engagement_start) > ENGAGEMENT_TIMEOUT then
        blacklist(now, tp, 'timeout')
        reset_engagement()
        move.clear()
        task.status = 'trav timeout, blacklisted ' .. sn
        return
    end

    -- Cross-detection: player teleported >= CROSS_DETECT_DIST in 1 frame.
    if _engagement_pos and find.dist2d(pp, _engagement_pos) >= CROSS_DETECT_DIST then
        _last_cross_t = now
        reset_engagement()
        move.clear()
        task.status = 'crossed via ' .. sn
        return
    end

    -- Out of interact range: walk toward the trav.
    if dist > INTERACT_DIST then
        move.to_pos(tp, { arrive_radius = INTERACT_DIST - 0.5 })
        task.status = string.format('walking to %s (%.1fm)', sn, dist)
        return
    end

    -- In range.  Stop the walker so we don't drift past the gizmo while
    -- the climb animation plays.
    move.pause()

    -- Cooldown gate: keep firing until cross detected or ineffectiveness
    -- threshold hit.  Some climbs need 2-3 retries because the actor's
    -- "ready" flag can desync with the player's facing.
    if (now - _last_interact_t) >= INTERACT_COOLDOWN then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(trav)
        _last_interact_t = now
        _interact_count  = _interact_count + 1

        -- Track player movement between consecutive interacts.  If we
        -- click N times in a row without the player budging at all, the
        -- trav is broken (wrong Z, animation locked, etc.) -- blacklist
        -- and bail.
        if _pos_at_last_interact then
            local moved = find.dist2d(pp, _pos_at_last_interact)
            if moved < 1 and _interact_count >= INEFFECTIVE_THRESHOLD then
                blacklist(now, tp, 'ineffective')
                reset_engagement()
                move.resume()
                task.status = 'trav ineffective, blacklisted ' .. sn
                return
            end
        end
        _pos_at_last_interact = pp
    end

    task.status = string.format('crossing %s (#%d)', sn, _interact_count)
end

return task
