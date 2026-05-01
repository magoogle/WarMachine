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

-- Pick a kill target from the host's near-target list.
--
-- opts.range    (required) max engagement distance in y
-- opts.filter   optional fn(actor, dist) -> bool; return false to skip
--
-- Returns the chosen actor, or nil.  Callers gate shouldExecute on
-- whether this returns non-nil.
M.pick = function (opts)
    local lp = get_local_player()
    if not lp then _G.WARMACHINE_TARGET = nil; return nil end
    local pp = (get_player_position and get_player_position()) or lp:get_position()
    if not pp then _G.WARMACHINE_TARGET = nil; return nil end
    if not target_selector or not target_selector.get_near_target_list then
        _G.WARMACHINE_TARGET = nil; return nil end
    local range = opts and opts.range or 25
    local enemies = target_selector.get_near_target_list(pp, range)
    if not enemies then _G.WARMACHINE_TARGET = nil; return nil end

    local now = get_time_since_inject() or 0
    local best = { boss = nil, boss_d = math.huge,
                   spec = nil, spec_d = math.huge,
                   any  = nil, any_d  = math.huge }

    for _, e in pairs(enemies) do
        local hp = e.get_current_health and e:get_current_health() or 0
        if hp > 1 then
            local p = e.get_position and e:get_position() or nil
            if p then
                local dx, dy = p:x() - pp:x(), p:y() - pp:y()
                local d = math.sqrt(dx*dx + dy*dy)
                if d <= range and (not opts or not opts.filter or opts.filter(e, d)) then
                    -- Universal filters (per user spec, applied to
                    -- every activity's kill_monster):
                    --   * Skip enemies whose position isn't on the
                    --     navmesh -- can't be reached even in theory.
                    --   * Skip enemies recently marked unreachable by
                    --     a stuck-detect (closed door, off-mesh, etc.).
                    -- Both filters are O(1); is_point_walkeable is the
                    -- recorder's primitive and the unreachable check is
                    -- a hash lookup.
                    local key = actor_key(e)
                    local skip = is_unreachable(key, now)
                                 or not is_actor_walkable_destination(e)
                    if not skip then
                        local boss, special = specialness(e)
                        if boss then
                            if d < best.boss_d then best.boss, best.boss_d = e, d end
                        elseif special then
                            if d < best.spec_d then best.spec, best.spec_d = e, d end
                        else
                            if d < best.any_d  then best.any,  best.any_d  = e, d end
                        end
                    end
                end
            end
        end
    end

    local picked = best.boss or best.spec or best.any
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
                _G.WARMACHINE_TARGET = nil
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
    -- Publish the chosen target to UniversalRotation via _G.WARMACHINE_TARGET
    -- so its spell loop casts at OUR pick instead of its own closest-mob
    -- selection.  Without this, UR was firing at whichever monster the
    -- enemy stream put first, and orbwalker's facing followed UR's cast,
    -- yanking the bot's heading away from the structure / elite WarMachine
    -- was walking toward.  Set/clear directly (no require) to keep
    -- core/target free of a bridge import.  picked may be nil here
    -- (empty enemies list / all filtered) -- nil clears the override.
    _G.WARMACHINE_TARGET = picked
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
