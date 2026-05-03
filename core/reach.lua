-- ---------------------------------------------------------------------------
-- core/reach.lua
--
-- "Can the player walk from A to B?" -- the reachability primitive
-- shared by every WarMachine task that picks a target by position
-- (interact_poi, seek_progression, kill_monster's target.lua picker,
-- nav.lua sequencer goals, ...).
--
-- The host pathfinder (`pathfinder.calculate_and_get_path_points`)
-- runs A* across the LIVE walkable mesh -- it knows about closed
-- doors, off-mesh actors, terrain breaks, etc.  When it returns
-- nil / empty for (player_pos, goal_pos), there is genuinely no
-- route from where the player stands right now.
--
-- Why we need this:  catalog-driven pickers (interact_poi, etc.)
-- used to grab the highest-weighted target by Euclidean distance and
-- hand it to move.to_pos.  When the chosen chest was 30y away
-- through an unopened door, the bot would walk straight at the
-- wall, get stuck, eventually time out via PURSUIT_STALL_S.  The
-- user-spec'd flow:
--
--   "We should be exploring until the objective is near by and
--    actually pathable.  Not just setting an endpoint and making a
--    straight line."
--
-- With this module, pickers FILTER candidates by reachability before
-- choosing.  Unreachable targets get skipped on this pulse; the
-- freeroam/explorer fallback takes the pulse instead and walks the
-- bot toward unexplored space.  Once the bot has walked through
-- enough of the room to make the objective reachable, it gets
-- picked again and we commit.
--
-- Cost concern: pathfinder.calculate_and_get_path_points is NOT free
-- (5-30ms per call on big zones).  Mitigations:
--
--   1) Coarse-cell cache: queries get bucketed by (player_5m_cell,
--      goal_5m_cell).  Same query within a 1-second window hits the
--      cache.  Player drift inside a single 5m cell doesn't
--      invalidate cached answers.
--   2) Budget cap: pickers should pass `budget` to limit per-pulse
--      A* calls.  Beyond budget the picker can either fall through
--      to non-checked picks (with PURSUIT_STALL_S as the safety net)
--      or return nil and yield to the next priority task.
--   3) Skip when host pathfinder is unavailable: the reach check
--      transparently returns true so we don't break activities on
--      hosts that don't expose pathfinder.
-- ---------------------------------------------------------------------------

local M = {}

-- Tunables.
local PATH_CACHE_TTL_S = 1.0
local COARSE_CELL_M    = 5
local CACHE_TRIM_INTERVAL_S = 5.0
local CACHE_TRIM_THRESHOLD  = 256

-- Cache: 'px,py|gx,gy' -> { reachable, t }
local _path_cache = {}
local _cache_last_trim = 0

local function now_s()
    return get_time_since_inject and get_time_since_inject() or 0
end

local function cache_key(px, py, gx, gy)
    return string.format(
        '%d,%d|%d,%d',
        math.floor(px / COARSE_CELL_M),
        math.floor(py / COARSE_CELL_M),
        math.floor(gx / COARSE_CELL_M),
        math.floor(gy / COARSE_CELL_M))
end

local function maybe_trim_cache(now)
    if (now - _cache_last_trim) < CACHE_TRIM_INTERVAL_S then return end
    _cache_last_trim = now
    -- #table on a hash is always 0; count via pairs() with early-out.
    local n = 0
    for _ in pairs(_path_cache) do
        n = n + 1
        if n > CACHE_TRIM_THRESHOLD then break end
    end
    if n <= CACHE_TRIM_THRESHOLD then return end
    for k, v in pairs(_path_cache) do
        if (now - v.t) > PATH_CACHE_TTL_S then _path_cache[k] = nil end
    end
end

-- Internal: run the pathfinder once, store result.
-- Returns true/false; nil result from the host pathfinder means
-- "no path."  Wrapped in pcall so a host-side fault doesn't crash
-- the calling task.
local function compute_reachable(px, py, pz, gx, gy, gz)
    if not pathfinder or not pathfinder.calculate_and_get_path_points then
        return true   -- host doesn't expose pathfinder; trust the caller's other filters
    end
    local from = vec3:new(px, py, pz or 0)
    local to   = vec3:new(gx, gy, gz or pz or 0)
    local ok, path = pcall(pathfinder.calculate_and_get_path_points, from, to)
    if not ok then return false end
    if type(path) ~= 'table' then return false end
    return #path > 0
end

-- ---------------------------------------------------------------------------
-- Public: is the goal position reachable from the player's position?
-- Both args can be vec3 or { x, y, z } tables; the function normalizes.
--
-- Returns boolean.  Defensive: returns false on any malformed input
-- (caller treats unreachable as "skip") -- never throws.
-- ---------------------------------------------------------------------------
local function get_xyz(p)
    if not p then return nil end
    if p.x and type(p.x) == 'function' then
        -- vec3.  Use dot syntax (p.z) for the method-existence check;
        -- colon syntax (p:z) is a syntax error without a call.
        local z = (p.z and p:z()) or 0
        return p:x(), p:y(), z
    end
    if type(p.x) == 'number' then
        return p.x, p.y, p.z or 0
    end
    return nil
end

M.is_reachable = function (player_pos, goal_pos)
    local px, py, pz = get_xyz(player_pos)
    local gx, gy, gz = get_xyz(goal_pos)
    if not (px and gx) then return false end

    local now = now_s()
    maybe_trim_cache(now)

    local key = cache_key(px, py, gx, gy)
    local hit = _path_cache[key]
    if hit and (now - hit.t) < PATH_CACHE_TTL_S then
        return hit.reachable
    end

    local reachable = compute_reachable(px, py, pz, gx, gy, gz)
    _path_cache[key] = { reachable = reachable, t = now }
    return reachable
end

-- ---------------------------------------------------------------------------
-- Public: convenience -- reachability to a live game actor.  Returns
-- false when the actor has no position.  Rest of the contract matches
-- M.is_reachable.
-- ---------------------------------------------------------------------------
M.is_actor_reachable = function (player_pos, actor)
    if not actor or not actor.get_position then return false end
    local ok, ap = pcall(function () return actor:get_position() end)
    if not ok or not ap then return false end
    return M.is_reachable(player_pos, ap)
end

-- ---------------------------------------------------------------------------
-- Public: convenience -- pull current player position + check reach.
-- Caller doesn't have to thread the player position around.
-- ---------------------------------------------------------------------------
local function current_player_pos()
    local lp = get_local_player and get_local_player()
    if not lp then return nil end
    local p = lp.get_position and lp:get_position()
    return p
end

M.from_player_to_pos = function (goal_pos)
    local pp = current_player_pos()
    if not pp then return false end
    return M.is_reachable(pp, goal_pos)
end

M.from_player_to_actor = function (actor)
    local pp = current_player_pos()
    if not pp then return false end
    return M.is_actor_reachable(pp, actor)
end

-- ---------------------------------------------------------------------------
-- Public: pick the first reachable candidate from a sorted list (caller
-- pre-sorted by their priority -- weight, distance, whatever).  Stops
-- after `budget` A* calls -- beyond budget remaining candidates pass
-- through assumed-reachable so the picker has SOMETHING to return.
-- Most callers want budget=5, default 6.
--
-- candidates: array of items the caller cares about.  The `extract`
--   callback maps each item to a { x, y, z } point (or nil to skip).
--
-- Returns: (item, idx_in_list) of the first reachable candidate, or
-- (last_assumed_reachable_item, idx) when budget is exhausted, or
-- (nil, nil) when the list is empty / nothing extractable.
-- ---------------------------------------------------------------------------
M.first_reachable = function (candidates, extract, opts)
    opts = opts or {}
    local budget = opts.budget or 6
    local pp     = opts.player_pos or current_player_pos()
    if not pp then return nil, nil end
    if not candidates or #candidates == 0 then return nil, nil end

    local last_item, last_idx = nil, nil
    for i = 1, #candidates do
        local item = candidates[i]
        local pt = extract and extract(item) or item
        if pt then
            if budget <= 0 then
                -- Budget exhausted: accept the next one without
                -- A*-ing.  PURSUIT_STALL safety net catches genuinely-
                -- unreachable late picks within a few seconds.
                return item, i
            end
            budget = budget - 1
            if M.is_reachable(pp, pt) then
                return item, i
            end
            last_item, last_idx = item, i
        end
    end
    return nil, nil
end

-- Diagnostics for tracker / GUI display.
M.cache_stats = function ()
    local n = 0
    for _ in pairs(_path_cache) do n = n + 1 end
    return { entries = n }
end

-- Drop the cache (e.g. on zone change -- the walkable mesh is likely
-- entirely different on the new zone).
M.clear_cache = function ()
    _path_cache = {}
end

return M
