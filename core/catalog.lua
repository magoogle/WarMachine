-- ---------------------------------------------------------------------------
-- core/catalog.lua
--
-- Single chokepoint for reading the WarPath/StaticPather merged actor
-- catalog.  All activity-side POI builders go through this instead of
-- calling StaticPatherPlugin.get_actors() directly so we can apply
-- cross-cutting filters (and only have to update them in one place).
--
-- Why this exists -- the user-reported "stuck looking for an elite not
-- here" bug:
--
--   WarPath's catalog is keyed by world/zone name.  For PROCEDURALLY
--   GENERATED dungeons (Pit, NMD, Undercity), each instance has a
--   different actor layout, but the catalog merges every run of the
--   same world type into one master entry.  Result: champion / elite /
--   boss positions from PRIOR runs leak into THIS run's catalog as
--   "actors at (x, y) of skin Z" -- a phantom enemy that doesn't
--   exist in the live actor stream.
--
--   The proper fix lives in WarPath (per-run isolation + N-of-M
--   consistency check before merging into master; see DESIGN NOTE
--   below).  This module is the WarMachine-side stop-gap: enemy-kind
--   actors should NEVER come from the catalog into POI / nav code,
--   because:
--     * Their LIVE positions come from target_selector / actors_manager
--       (host stream) -- the catalog adds nothing useful.
--     * The catalog WILL have stale positions in procedural zones.
--     * Walking to a stale enemy stalls the bot at empty geometry.
--
-- ---------------------------------------------------------------------------
-- DESIGN NOTE -- WarPath-side fix the user wants:
--
--   Zone taxonomy (already partly present via key_type in get_status):
--     * STATIC (merge OK):   towns + overworld (Scos_*, Skov_*, Frac_*,
--                            Kehj_*, Step_*, Sanc_*), fixed boss arenas
--                            (Boss_WT*, Boss_Kehj_Belial), Hordes (BSK_*).
--     * PROCEDURAL (per-run): Pit (PIT_*), NMD (NMD_*, dungeon_x1_*),
--                            Undercity (X1_Undercity_*), random dungeons
--                            (DGN_*, season-prefixed S*_DGN_*).
--
--   For PROCEDURAL zones:
--     1. Each run gets its OWN catalog snapshot (keyed by run id, not
--        just world name).  Live consumers read THIS RUN's snapshot
--        first.
--     2. After the run ends, candidate-merge into the master catalog
--        for that world.  Master entry gets an actor only if it appears
--        in N of last M runs at consistent position (suggests
--        skin = '<staticly placed>') -- e.g. floor portal positions,
--        boss arena anchor, fixed gizmo locations.
--     3. Per-run noise (one-shot enemy positions, random shrine spots)
--        never reaches master.  Master stays small + accurate.
--
--   For STATIC zones: existing merge behavior is fine (towns are
--   genuinely static; Hordes arena is always the same room).
-- ---------------------------------------------------------------------------

local M = {}

-- Resolve the WarPath plugin global (rename-tolerant).
local function plugin()
    return rawget(_G, 'WarPathPlugin')
        or rawget(_G, 'StaticPatherPlugin')
        or nil
end

-- ---------------------------------------------------------------------------
-- Kinds that NEVER make sense to read from the catalog.  The bot uses
-- the live actor stream (target_selector.get_near_target_list) for
-- combat targets; catalog entries for these are 100% noise (procedural
-- zones) or static-arena enemy spawn hints we don't need (the live
-- stream surfaces them as soon as they spawn anyway).
--
-- Adding to this list is cheap: any kind here gets stripped on every
-- get_actors() call, regardless of caller.
-- ---------------------------------------------------------------------------
local ENEMY_KINDS = {
    champion = true,
    elite    = true,
    boss     = true,
    miniboss = true,
    monster  = true,    -- generic enemy fallback, if the recorder ever uses it
    enemy    = true,    -- generic enemy fallback, if the recorder ever uses it
}

-- Public: is this kind an enemy?  Exposed so callers that have other
-- reasons to walk a list can apply the same predicate without
-- duplicating the table.
M.is_enemy_kind = function (kind)
    return kind ~= nil and ENEMY_KINDS[kind] == true
end

-- ---------------------------------------------------------------------------
-- Public: filtered actor list.  Drop-in replacement for
-- StaticPatherPlugin.get_actors() that strips enemy-kind entries.
-- Returns an array (possibly empty); never returns nil.
--
-- opts.include_enemies  -- override the filter (rare; debug-only).
-- opts.kinds            -- restrict to a whitelist set if provided.
-- ---------------------------------------------------------------------------
M.get_actors = function (opts)
    local p = plugin()
    if not p or not p.get_actors then return {} end
    local ok, actors = pcall(p.get_actors)
    if not ok or not actors then return {} end

    local include_enemies = opts and opts.include_enemies == true
    local kind_filter     = opts and opts.kinds or nil

    local out = {}
    for _, a in ipairs(actors) do
        local kind = a.kind or ''
        local keep = true
        if kind_filter and not kind_filter[kind] then keep = false end
        if keep and not include_enemies and ENEMY_KINDS[kind] then
            keep = false
        end
        if keep then out[#out + 1] = a end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Public: catalog availability check.  True when WarPath is loaded and
-- exposes get_actors.  POI builders bail to "no catalog -> rely on live
-- stream + freeroam" when this returns false.
-- ---------------------------------------------------------------------------
M.is_available = function ()
    local p = plugin()
    return p ~= nil and p.get_actors ~= nil
end

-- ---------------------------------------------------------------------------
-- Public: closest catalog actor matching a predicate.  Convenience for
-- "where's the nearest <thing>" callers; threads the filter so they
-- still get enemy-stripping without writing the loop themselves.
--
--   pred(actor) -> bool
--   opts        -- forwarded to get_actors (kinds whitelist, etc.)
--
-- Returns: the actor table, the squared distance, or (nil, nil).
-- ---------------------------------------------------------------------------
M.closest_to_player = function (pred, opts)
    local lp = get_local_player()
    if not lp then return nil, nil end
    local pp = lp.get_position and lp:get_position() or nil
    if not pp then return nil, nil end
    local px, py = pp:x(), pp:y()
    local best, best_d2 = nil, math.huge
    for _, a in ipairs(M.get_actors(opts)) do
        if not pred or pred(a) then
            local dx = (a.x or 0) - px
            local dy = (a.y or 0) - py
            local d2 = dx*dx + dy*dy
            if d2 < best_d2 then best, best_d2 = a, d2 end
        end
    end
    return best, (best and best_d2 or nil)
end

return M
