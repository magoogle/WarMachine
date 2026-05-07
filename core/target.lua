-- ---------------------------------------------------------------------------
-- core/target.lua
--
-- Shared kill-target selector.  Replaces the per-activity inlined
-- "boss > closest" logic in NMD / Pit / Undercity kill_monster tasks
-- and adds proper elite-first priority across the board:
--
--   tier 0 (top)  bosses
--   tier 1        champions / elites
--   tier 2        everything else
--
-- Within a tier, closest wins.  An empty higher tier falls through to
-- the next.  This guarantees a 30y elite beats a 5y skeleton archer --
-- the user-reported failure mode where the bot would dance with white
-- mobs while a champion blasted it from across the room.
--
-- Hordes' kill_monster has a richer wave-directive tier system on top
-- of this; it keeps its own pick_target.  The elite-first rule already
-- holds there at tier 2 (above masses / spires / scripted objectives /
-- generic enemies).
-- ---------------------------------------------------------------------------

local M = {}

-- Read the actor's "specialness" -- boss / champion / elite -- via the
-- host predicates, defending against missing methods on prop-like
-- actors that pass through target_selector for some reason.
local function specialness(a)
    local boss  = a.is_boss     and a:is_boss()     or false
    local champ = a.is_champion and a:is_champion() or false
    local elite = a.is_elite    and a:is_elite()    or false
    return boss, (champ or elite)
end

-- Goblin override: any actor whose skin name contains "goblin" (case
-- insensitive) is high kill priority -- bumped above bosses.
-- Treasure goblins flee fast and despawn; the user spec'd "if we see
-- it, we must kill it.  regardless of the module."
--
-- Detection is substring on the skin (matches TreasureGoblin_*,
-- AetherGoblin_* if the host returns them as enemies, etc.); we
-- intentionally don't whitelist a finite set of skins so future
-- season-prefixed variants still trigger.
local function _is_goblin(a)
    if not a or not a.get_skin_name then return false end
    local sn = nil
    pcall(function () sn = a:get_skin_name() end)
    if not sn or sn == '' then return false end
    return sn:lower():find('goblin', 1, true) ~= nil
end

-- Quest-hint override: enemies whose skin substring-matches a current
-- quest objective keyword get TOP priority.  Example: NMD objective
-- "Slay the Aldurkin: 1" -- when the last Aldurkin streams in,
-- hunting it down beats every other tier including goblins.
--
-- See core/quest_hint.lua for the keyword extraction.  Imported
-- lazily (inside the predicate) so the require is deferred -- avoids
-- a circular dep risk + lets target.lua load even when quest_hint
-- happens to error.
local function _is_quest_hint(a)
    if not a or not a.get_skin_name then return false end
    local sn = nil
    pcall(function () sn = a:get_skin_name() end)
    if not sn or sn == '' then return false end
    local ok, qh = pcall(require, 'core.quest_hint')
    if not ok or not qh or not qh.skin_matches_hint then return false end
    local mok, matched = pcall(qh.skin_matches_hint, sn)
    return mok and matched == true
end

-- ---- Unreachable blacklist ----
--
-- Cross-activity registry of actors whose positions the walker (or any
-- caller) has just given up on as unreachable.  pick() skips entries
-- in this list.  Each entry has a TTL after which it's eligible again
-- (in case a closed door has since opened, etc.).
--
-- Keyed by 'skin:rounded_x:rounded_y' so we identify the same actor
-- across pulses without holding actor references.

local _unreachable = {}      -- key -> expiry_t
local UNREACHABLE_TTL_S = 20
-- Pursuit tracking: when M.pick returns the SAME target across multiple
-- pulses without the player closing distance to it, it's almost
-- certainly unreachable (closed door, off-mesh, in a different room).
-- We auto-blacklist after PURSUIT_STALL_S of zero progress.
local _pursuit = nil      -- { key, start_t, start_d }
local PURSUIT_STALL_S    = 5.0
local PURSUIT_PROGRESS_M = 2.0

local function actor_key(a)
    if not a then return nil end
    local sn = a.get_skin_name and a:get_skin_name() or '?'
    local p  = a.get_position  and a:get_position()  or nil
    if not p then return nil end
    return string.format('%s:%d:%d', sn, math.floor(p:x()), math.floor(p:y()))
end

local function is_unreachable(key, now)
    if not key then return false end
    local exp = _unreachable[key]
    if not exp then return false end
    if now >= exp then
        _unreachable[key] = nil
        return false
    end
    return true
end

-- Public: mark an actor as unreachable for UNREACHABLE_TTL_S seconds.
-- Call this from kill_monster (or any caller) when a target has been
-- pursued for too long without dying or closing distance -- pathfinder
-- can't get to it (closed door, off-navmesh, in a future room, etc.).
M.mark_unreachable = function (actor)
    local key = actor_key(actor)
    if not key then return end
    _unreachable[key] = (get_time_since_inject() or 0) + UNREACHABLE_TTL_S
end

-- Public: clear the entire blacklist.  Useful on activity transitions
-- so old state doesn't bleed across.
M.clear_unreachable = function ()
    _unreachable = {}
end

-- ---- Walkability check ----
-- O(1) navmesh test using utility.is_point_walkeable -- the same
-- primitive WarMapRecorder uses for its grid.  Defends against
-- candidates that the host can't actually path to (off-mesh actors
-- like flying ranged units in some cases, or out-of-bounds props).
local function is_actor_walkable_destination(a)
    if not utility or not utility.is_point_walkeable then return true end
    local p = a.get_position and a:get_position() or nil
    if not p then return false end
    local probe = vec3:new(p:x(), p:y(), p:z() or 0)
    if utility.set_height_of_valid_position then
        local sok, snapped = pcall(utility.set_height_of_valid_position, probe)
        if sok and snapped then probe = snapped end
    end
    local ok, walkable = pcall(utility.is_point_walkeable, probe)
    return ok and walkable == true
end

-- ---- Vertical-distance reject ----
-- Mobs across a cliff / on a lower floor / in the void below a
-- balcony report on-navmesh positions and sometimes pass the
-- pathfinder reachability check via a long roundabout route the
-- host found.  Result: bot picks a target that is technically
-- reachable but practically unreachable from the player's current
-- position, walks to the cliff edge, and gets stuck pathing-toward.
--
-- Cheap pre-filter before the heavier reach check: reject any
-- target whose Z is more than MAX_Z_DELTA away from the player.
-- 5 yards is roughly the smallest cliff drop in D4 zones (typical
-- floor-to-floor is 8-10y; stairs/ramps stay under 3y).  Targets
-- across a real elevation break get filtered; same-floor targets
-- with normal slope variance pass through.
local MAX_Z_DELTA = 5.0

local function z_distance_ok(pp, a)
    if not utility or not utility.is_point_walkeable then return true end
    local ap = a.get_position and a:get_position() or nil
    if not ap or not pp then return true end
    local pz = pp:z() or 0
    local az = ap:z() or 0
    return math.abs(az - pz) <= MAX_Z_DELTA
end

-- ---- Path-based reachability check ----
--
-- is_point_walkeable says "this cell is on the navmesh"; it does NOT
-- say "the player can walk there from here."  An NMD champion 20y
-- east through a closed door is on the navmesh AND within 25y range,
-- and gets picked by the closest-special tier even though path
-- distance is infinite.
--
-- v3: this used to be a local cache + check inline here.  Factored
-- into core/reach.lua so other tasks (interact_poi, seek_progression,
-- etc.) share the same A*-with-coarse-cell-cache primitive.  Same
-- contract: passing budget=REACH_CHECK_BUDGET caps per-pick A* calls
-- so a 30-mob pile can't pin the game thread.
local reach = require 'core.reach'

local REACH_CHECK_BUDGET = 6   -- A* calls per pick; rest assumed reachable

local function is_actor_reachable(pp, a)
    return reach.is_actor_reachable(pp, a)
end

-- Pick a kill target from the host's near-target list.
--
-- opts.range    (required) max engagement distance in y
-- opts.filter   optional fn(actor, dist) -> bool; return false to skip
--
-- Returns the chosen actor, or nil.  Callers gate shouldExecute on
-- whether this returns non-nil.
M.pick = function (opts)
    local lp = get_local_player()
    if not lp then _G.EXTERNAL_ROTATION_TARGET = nil; return nil end
    local pp = (get_player_position and get_player_position()) or lp:get_position()
    if not pp then _G.EXTERNAL_ROTATION_TARGET = nil; return nil end
    if not target_selector or not target_selector.get_near_target_list then
        _G.EXTERNAL_ROTATION_TARGET = nil; return nil end
    local range = opts and opts.range or 25
    local enemies = target_selector.get_near_target_list(pp, range)
    if not enemies then _G.EXTERNAL_ROTATION_TARGET = nil; return nil end

    local now = get_time_since_inject() or 0

    -- Two-phase pick:
    --   Phase 1: collect all candidates passing the cheap O(1) filters
    --            (HP > 1, in range, on-navmesh, not blacklisted).
    --   Phase 2: walk the candidates in (tier, distance) order asking
    --            the host pathfinder if the player can REACH each one.
    --            First reachable per tier wins.  This keeps the
    --            "30y elite beats 5y skeleton" guarantee while
    --            rejecting elites stuck behind a closed door.
    --
    -- Phase 2 is bounded by REACH_CHECK_BUDGET so a 30-mob pile can't
    -- pin the game thread doing A* per candidate.  Beyond the budget
    -- we trust the navmesh check + the PURSUIT_STALL_S safety net.
    local candidates = { quest = {}, goblin = {}, boss = {}, spec = {}, any = {} }

    for _, e in pairs(enemies) do
        local hp = e.get_current_health and e:get_current_health() or 0
        if hp > 1 then
            local p = e.get_position and e:get_position() or nil
            if p then
                local dx, dy = p:x() - pp:x(), p:y() - pp:y()
                local d = math.sqrt(dx*dx + dy*dy)
                if d <= range and (not opts or not opts.filter or opts.filter(e, d)) then
                    local key = actor_key(e)
                    local skip = is_unreachable(key, now)
                                 or not is_actor_walkable_destination(e)
                                 or not z_distance_ok(pp, e)
                    if not skip then
                        local bucket
                        -- QUEST-HINT OVERRIDE: actor's skin matches
                        -- a current quest objective keyword.  Top
                        -- priority across the board so the bot
                        -- finishes the run instead of farming chaff.
                        if _is_quest_hint(e) then
                            bucket = 'quest'
                        -- GOBLIN OVERRIDE: any actor whose skin
                        -- contains 'goblin' beats bosses (loot
                        -- urgency) -- see _is_goblin.
                        elseif _is_goblin(e) then
                            bucket = 'goblin'
                        else
                            local boss, special = specialness(e)
                            bucket = boss and 'boss' or (special and 'spec' or 'any')
                        end
                        candidates[bucket][#candidates[bucket] + 1] = { actor = e, dist = d, key = key }
                    end
                end
            end
        end
    end

    -- Sort each tier ascending by distance.  Lua's table.sort is
    -- stable enough for these small lists (<30 typical).
    for _, list in pairs(candidates) do
        table.sort(list, function (a, b) return a.dist < b.dist end)
    end

    -- Walk tiers in priority order; for each, scan candidates in
    -- distance order asking the pathfinder for reachability.  First
    -- reachable wins.  Auto-blacklist anything we found unreachable so
    -- the next pulse doesn't re-A* it.
    --   1. quest   -- objective-relevant (e.g. "Slay the Aldurkin")
    --   2. goblin  -- treasure goblin / aether goblin
    --   3. boss    -- regular boss tier
    --   4. spec    -- elite / champion
    --   5. any     -- white mobs
    local picked = nil
    local reach_budget = REACH_CHECK_BUDGET
    for _, tier in ipairs({ 'quest', 'goblin', 'boss', 'spec', 'any' }) do
        for _, c in ipairs(candidates[tier]) do
            if reach_budget <= 0 then
                -- Budget exhausted -- accept the closest remaining in
                -- this tier without path-check; PURSUIT_STALL_S will
                -- catch genuinely-unreachable picks within 5s.
                picked = c.actor
                break
            end
            reach_budget = reach_budget - 1
            if is_actor_reachable(pp, c.actor) then
                picked = c.actor
                break
            else
                -- Not reachable from current position.  Soft-blacklist
                -- so we don't re-A* this same actor over and over.  TTL
                -- matches UNREACHABLE_TTL_S (20s) -- if the door opens
                -- inside that window the bot will just take a beat
                -- longer to engage; the next pulse after expiry
                -- re-evaluates.
                if c.key then _unreachable[c.key] = now + UNREACHABLE_TTL_S end
            end
        end
        if picked then break end
    end
    -- Pursuit-stall blacklist.  If we keep picking the same target and
    -- the distance isn't closing, it's unreachable (closed door, off-
    -- mesh, in another room).  Blacklist it for UNREACHABLE_TTL_S so
    -- the next pulse picks a different one.
    if picked then
        local key = actor_key(picked)
        local p   = picked.get_position and picked:get_position() or nil
        local d   = (p and pp) and math.sqrt(
            (p:x() - pp:x())^2 + (p:y() - pp:y())^2) or 0
        if _pursuit and _pursuit.key == key then
            local elapsed = now - _pursuit.start_t
            local closed  = _pursuit.start_d - d
            if elapsed >= PURSUIT_STALL_S and closed < PURSUIT_PROGRESS_M then
                -- Stalled.  Blacklist + bail this pulse; caller's
                -- next call will pick a different target.
                if key then _unreachable[key] = now + UNREACHABLE_TTL_S end
                _pursuit = nil
                _G.EXTERNAL_ROTATION_TARGET = nil
                return nil
            end
            -- Made progress -- update the start_d snapshot so the
            -- progress check stays meaningful as we close.
            if closed >= PURSUIT_PROGRESS_M then
                _pursuit.start_t = now
                _pursuit.start_d = d
            end
        else
            _pursuit = { key = key, start_t = now, start_d = d }
        end
    else
        _pursuit = nil
    end
    -- Publish the chosen target to UniversalRotation via
    -- _G.EXTERNAL_ROTATION_TARGET so its spell loop casts at OUR pick
    -- instead of its own closest-mob selection.  Without this, UR was
    -- firing at whichever monster the enemy stream put first, and
    -- orbwalker's facing followed UR's cast, yanking the bot's heading
    -- away from the structure / elite WarMachine was walking toward.
    -- Set/clear directly (no require) to keep core/target free of a
    -- bridge import.  picked may be nil here (empty enemies list / all
    -- filtered) -- nil clears the override.
    _G.EXTERNAL_ROTATION_TARGET = picked
    return picked
end

-- Helpers re-exported so other modules don't have to inline the same
-- predicate triple.  pick_target consumers usually only need the chosen
-- actor, but boss-room latches (boss_seen) want a single boolean.
M.is_boss          = function (a) local boss, _    = specialness(a); return boss end
M.is_special       = function (a) local boss, spec = specialness(a); return boss or spec end
M.is_elite_or_champ = function (a) local _,    spec = specialness(a); return spec end

-- Distance from player to actor (yards).  Returns math.huge if either
-- can't be resolved.  Used by kill_monster to decide "in attack range
-- already, don't pull the walker toward this guy".
M.distance_to = function (a)
    local lp = get_local_player()
    if not lp or not a or not a.get_position then return math.huge end
    local pp = lp:get_position()
    local ap = a:get_position()
    if not pp or not ap then return math.huge end
    local dx, dy = ap:x() - pp:x(), ap:y() - pp:y()
    return math.sqrt(dx*dx + dy*dy)
end

-- Default "we're already in attack range, no need to move" radius.
-- Tuned for the user-visible "orbwalker point is WAYYY too far"
-- symptom: when an enemy is within this radius we skip move.to_actor
-- entirely so the walker doesn't get a fresh target it'll then chase
-- past the actual fight.  Each kill_monster can override this.
M.IN_RANGE_DEFAULT = 8.0

return M
