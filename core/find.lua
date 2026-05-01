-- ---------------------------------------------------------------------------
-- core/find.lua
--
-- Shared actor-stream scanning helpers.  Every task that walks to a
-- skin-pattern-matched actor previously inlined the same loop:
--
--   for _, a in pairs(actors_manager:get_ally_actors()) do
--       local sn = a.get_skin_name and a:get_skin_name() or nil
--       if sn and a.is_interactable and a:is_interactable() then
--           local sl = sn:lower()
--           local match = false
--           for _, pat in ipairs(PATTERNS) do
--               if sl:find(pat, 1, true) then match = true; break end
--           end
--           if match then ... end
--       end
--   end
--
-- This module collapses that into one call.  It also provides the
-- "visited dedup key" formatter used across loot_chest / cursed_shrine /
-- ambush / interact_shrine to track per-actor "we already clicked this
-- one" without revisiting.
-- ---------------------------------------------------------------------------

local M = {}

-- Build a player-distance helper once per call.  Returns
-- (px, py, dist_sq_fn) where dist_sq_fn(p) -> squared 2D distance to p.
local function player_distance_fn()
    local lp = get_local_player()
    if not lp then return nil end
    local pp = lp:get_position()
    if not pp then return nil end
    local px, py = pp:x(), pp:y()
    return px, py, function (p)
        if not p then return math.huge end
        local dx, dy = p:x() - px, p:y() - py
        return dx*dx + dy*dy
    end
end

-- Generate a stable dedup key for an actor at a position.
-- prefix:  short string identifying the consumer ('chest', 'shrine', ...)
-- actor:   the game actor whose skin name is keyed
-- p:       optional position vec3 (defaults to actor:get_position())
-- Returns: 'prefix:skin:floor(x):floor(y)'
M.key_for = function (prefix, actor, p)
    p = p or (actor and actor.get_position and actor:get_position() or nil)
    local sn = actor and actor.get_skin_name and actor:get_skin_name() or '?'
    local x  = p and p:x() or 0
    local y  = p and p:y() or 0
    return string.format('%s:%s:%d:%d', prefix or 'a', sn, math.floor(x), math.floor(y))
end

-- Iterate the host-provided actor stream.  Default uses ally actors
-- (interactables, NPCs, friendlies); pass `source = 'all'` to get every
-- actor (enemies, decorations, etc.).
local function iter_actors(source)
    if not actors_manager then return ipairs({}) end
    if source == 'all' then
        if actors_manager.get_all_actors then
            return pairs(actors_manager:get_all_actors())
        end
    end
    if actors_manager.get_ally_actors then
        return pairs(actors_manager:get_ally_actors())
    end
    return ipairs({})
end

-- Lowercase the skin name and substring-match against any of `patterns`.
-- Returns true on first match.  Patterns must already be lowercase.
local function skin_matches_any(sn, patterns)
    if not sn then return false end
    local sl = sn:lower()
    for i = 1, #patterns do
        if sl:find(patterns[i], 1, true) then return true end
    end
    return false
end

-- Find the closest actor in the stream matching the given criteria.
--
-- opts (table):
--   patterns         (required) list of LOWERCASE substrings to match
--                    against the actor's skin name
--   require_interactable  default true; if true, skips actors where
--                    is_interactable() is false
--   source           'ally' | 'all'.  'ally' (default) covers chests,
--                    shrines, NPCs, portals.  'all' covers everything.
--   max_dist_sq      max squared distance from the player; default
--                    no limit
--   visited          optional table; an actor is skipped if its
--                    M.key_for(visited_prefix, actor, p) is in
--                    `visited` (i.e. visited[key] == true)
--   visited_prefix   prefix string for the visited key (defaults to 'a')
--   filter           optional fn(actor, p) -> bool to additionally
--                    filter candidates (e.g. domain-specific checks)
--
-- Returns (actor, dist_sq) or (nil, math.huge).
M.closest = function (opts)
    if not opts or not opts.patterns or #opts.patterns == 0 then
        return nil, math.huge
    end
    local px, py, dist_sq = player_distance_fn()
    if not dist_sq then return nil, math.huge end

    local require_interact = opts.require_interactable
    if require_interact == nil then require_interact = true end
    local max_d2 = opts.max_dist_sq or math.huge
    local source = opts.source or 'ally'
    local visited = opts.visited
    local vprefix = opts.visited_prefix or 'a'

    local best, best_d2 = nil, math.huge
    for _, a in iter_actors(source) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn and skin_matches_any(sn, opts.patterns) then
            local interact_ok = true
            if require_interact then
                interact_ok = a.is_interactable and a:is_interactable() or false
            end
            if interact_ok then
                local p = a.get_position and a:get_position() or nil
                if p then
                    local d2 = dist_sq(p)
                    if d2 < max_d2 and d2 < best_d2 then
                        local skip = false
                        if visited then
                            local key = M.key_for(vprefix, a, p)
                            if visited[key] then skip = true end
                        end
                        if not skip and (not opts.filter or opts.filter(a, p)) then
                            best, best_d2 = a, d2
                        end
                    end
                end
            end
        end
    end
    return best, best_d2
end

-- Convenience: 2D Euclidean distance between two positions.  Saves the
-- math.sqrt(dx*dx+dy*dy) boilerplate each task otherwise spells out.
M.dist2d = function (a, b)
    if not a or not b then return math.huge end
    local dx, dy
    if type(a) == 'table' then dx = (b:x() or 0) - (a.x or 0); dy = (b:y() or 0) - (a.y or 0)
    else dx = b:x() - a:x(); dy = b:y() - a:y() end
    return math.sqrt(dx*dx + dy*dy)
end

-- True when ANY enemy is within `range` of the player.  Wraps
-- target_selector.get_near_target_list with the sane default check.
M.any_enemy_in_range = function (range)
    if not target_selector or not target_selector.get_near_target_list then return false end
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end
    local list = target_selector.get_near_target_list(pp, range or 25)
    return list and next(list) ~= nil
end

-- True when ANY actor in the stream is a non-dead boss.
M.any_live_boss = function ()
    if not actors_manager or not actors_manager.get_all_actors then return false end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a.is_boss and a:is_boss() then
            local dead = a.is_dead and a:is_dead()
            if not dead then return true end
        end
    end
    return false
end

return M
