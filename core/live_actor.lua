-- ---------------------------------------------------------------------------
-- core/live_actor.lua
--
-- "Find the live game actor that corresponds to a catalog POI."  Used
-- by every interact_* task in WarMachine -- the catalog is a static
-- snapshot of (skin, x, y) coords, and we need to match it against
-- whatever live actor (with the same skin) is currently in the
-- player's stream.
--
-- Why a shared module: each activity's interact_poi.lua had its own
-- copy of nearly-identical matcher code with subtle, accidentally-
-- divergent rules:
--   * NMD: dual-scan (ally + all), substring match on skin "core"
--          (strips _01_Dyn suffix).
--   * Helltide: ally-only, exact match plus a Pyre_Helltide fallback.
--   * Pit: ally-only, exact match.
--   * Undercity: dual-scan, skin-core substring + dual-direction match.
-- Consolidating into one parameterized helper kills 4 copies of the
-- "iterate actors, sniff skin, distance-filter, return closest" loop.
--
-- API:
--   live_actor.find(poi, opts) -> actor | nil
--
-- opts:
--   scan_lists  : 'ally' | 'all' | 'both'   (default 'both')
--                 'ally' = actors_manager:get_ally_actors()
--                 'all'  = actors_manager:get_all_actors()
--                 'both' = scan both lists in order
--                 NMD switches/destructibles live in 'all' only;
--                 helltide chests in 'ally' only.  Default 'both' is
--                 strictly more permissive and rarely wrong.
--
--   match_mode  : 'exact' | 'substring' | 'core'   (default 'core')
--                 'exact'     -> sn == poi.skin
--                 'substring' -> sn:find(poi.skin, 1, true)
--                                or poi.skin:find(sn, 1, true)
--                 'core'      -> strip _NN_Dyn suffixes off both,
--                                lowercase, then mutual substring.
--                                Most permissive; matches the
--                                recorder's stripped skin against
--                                live _Dyn-suffixed variants.
--
--   max_dist_sq : number  (default 64 = 8m)
--                 Catalog coords drift a few meters from runtime
--                 spawns due to physics nudges + Z snapping; this
--                 window absorbs that without picking neighbors.
--
--   extra_match : optional fn(skin, poi) -> bool
--                 Activity-specific override layered on top of the
--                 mode match (e.g. helltide's Pyre_Helltide fallback
--                 when poi.kind == 'pyre').
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Skin "core": strip dynamic suffixes the recorder doesn't capture
-- so a catalog 'DGN_Switch_Lever_01' matches a runtime
-- 'DGN_Switch_Lever_01_Dyn'.  Patterns:
--    _01_Dyn   _02_Dyn   ... _NN_Dyn
--    _Dyn   (bare)
--    trailing _01..NN
-- Lowercased to make the match case-insensitive.
-- ---------------------------------------------------------------------------
local function skin_core(s)
    if not s then return nil end
    local out = s:lower()
    out = out:gsub('_(%d+)_dyn$', '')
    out = out:gsub('_dyn$', '')
    out = out:gsub('_(%d+)$', '')
    return out
end

-- ---------------------------------------------------------------------------
-- Match-mode predicates.  Each takes (live_skin, poi_skin) and returns
-- true on a match.  Inputs already stripped/lowered for 'core'.
-- ---------------------------------------------------------------------------
local function match_exact(live_sn, poi_sn)
    return live_sn == poi_sn
end

local function match_substring(live_sn, poi_sn)
    if not (live_sn and poi_sn) then return false end
    return live_sn:find(poi_sn, 1, true) ~= nil
        or poi_sn:find(live_sn, 1, true) ~= nil
end

local function match_core(live_sn, poi_sn)
    local lc = skin_core(live_sn)
    local pc = skin_core(poi_sn)
    if not (lc and pc) then return false end
    return lc:find(pc, 1, true) ~= nil
        or pc:find(lc, 1, true) ~= nil
end

local MODE_FNS = {
    exact     = match_exact,
    substring = match_substring,
    core      = match_core,
}

-- ---------------------------------------------------------------------------
-- Public: find the live actor matching `poi` in the actor stream.
-- Returns the closest-by-distance match within max_dist_sq, or nil.
-- ---------------------------------------------------------------------------
M.find = function (poi, opts)
    if not poi or not actors_manager then return nil end
    opts = opts or {}
    local scan_lists  = opts.scan_lists  or 'both'
    local match_mode  = opts.match_mode  or 'core'
    local max_d2      = opts.max_dist_sq or 64
    local extra_match = opts.extra_match    -- optional fn

    local target_sn = poi.skin
    if not target_sn or target_sn == '' then
        -- Some POI kinds (carry pickup spawns) don't carry a skin in
        -- the catalog.  Without a skin we can't match -- caller
        -- should fall back to coord-based positioning.
        return nil
    end

    local match_fn = MODE_FNS[match_mode] or MODE_FNS.core
    local target_sn_for_match
    if match_mode == 'core' then
        target_sn_for_match = target_sn   -- core() called inside match_core
    else
        target_sn_for_match = target_sn
    end

    local best, best_d2 = nil, math.huge

    local function scan(list)
        if not list then return end
        for _, a in pairs(list) do
            local sn = a.get_skin_name and a:get_skin_name() or nil
            if sn then
                local matched = match_fn(sn, target_sn_for_match)
                if not matched and extra_match then
                    matched = extra_match(sn, poi)
                end
                if matched then
                    local p = a.get_position and a:get_position() or nil
                    if p then
                        local dx = p:x() - (poi.x or 0)
                        local dy = p:y() - (poi.y or 0)
                        local d2 = dx * dx + dy * dy
                        if d2 < max_d2 and d2 < best_d2 then
                            best, best_d2 = a, d2
                        end
                    end
                end
            end
        end
    end

    if scan_lists == 'ally' or scan_lists == 'both' then
        if actors_manager.get_ally_actors then
            scan(actors_manager:get_ally_actors())
        end
    end
    if scan_lists == 'all' or scan_lists == 'both' then
        if actors_manager.get_all_actors then
            scan(actors_manager:get_all_actors())
        end
    end

    return best
end

-- Expose skin_core for callers that want to do their own custom
-- matching consistent with the rest of WarMachine.
M.skin_core = skin_core

return M
