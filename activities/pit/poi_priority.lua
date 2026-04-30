-- ---------------------------------------------------------------------------
-- activities/pit/poi_priority.lua
--
-- POI queue for in-pit gameplay.  Same shape as the helltide one but with
-- different type weights tuned for pit:
--
--   pit_exit (TWR_ExitPortalSwitch)  -- the floor-descend switch; top priority
--                                       once revealed (clearing the rest of
--                                       the floor wastes time vs descending)
--   pit_floor_portal                 -- the portal that spawns after the
--                                       switch is clicked; walk in to descend
--   chest                            -- mid-run loot chests in corridors
--   shrine                           -- buff shrines
--   glyph_gizmo                      -- handled by upgrade_glyph task, not
--                                       priority queue (special UI flow)
--
-- All filtered through tracker.visited dedup.
-- ---------------------------------------------------------------------------

local M = {}

local POI_REBUILD_INTERVAL_S = 1.5

local TYPE_WEIGHT = {
    pit_exit            = 1500,    -- floor switch -- always go here once seen
    pit_floor_portal    = 1400,    -- next-floor portal -- enter immediately
    chest               =  500,
    chest_helltide_random = 500,
    shrine              =  300,
    objective           =  200,
}

local DEFAULT_WEIGHT = 80
local DISTANCE_COEFF = 0.5

local function dist2_player(poi)
    local lp = get_local_player()
    if not lp then return math.huge end
    local pp = lp:get_position()
    if not pp then return math.huge end
    local dx = (poi.x or 0) - pp:x()
    local dy = (poi.y or 0) - pp:y()
    return dx*dx + dy*dy
end

local function score_poi(poi, ctx)
    -- Visited dedup
    local key = string.format('%s:%d:%d',
        poi.skin or poi.kind or '?',
        math.floor(poi.x or 0),
        math.floor(poi.y or 0))
    if ctx.visited[key] then return nil end

    -- Type-toggle gates
    if poi.kind == 'chest' or poi.kind == 'chest_helltide_random' then
        if not ctx.settings.do_chests then return nil end
    elseif poi.kind == 'shrine' then
        if not ctx.settings.do_shrines then return nil end
    end

    -- Skip pit_floor_portal if it's within back-portal radius (we just
    -- came through it).  ArkhamAsylum-style blacklist.
    if poi.kind == 'pit_floor_portal' and ctx.back_portal_pos then
        local dx = poi.x - ctx.back_portal_pos.x
        local dy = poi.y - ctx.back_portal_pos.y
        if dx*dx + dy*dy < (10 * 10) then return nil end
    end

    local weight = TYPE_WEIGHT[poi.kind] or DEFAULT_WEIGHT
    local d2 = dist2_player(poi)
    local d  = math.sqrt(d2)
    return weight - (d * DISTANCE_COEFF), d
end

M.build = function (tracker, settings)
    local now = get_time_since_inject and get_time_since_inject() or 0
    if tracker.poi_cache and (now - (tracker.last_poi_rebuild_t or -math.huge)) < POI_REBUILD_INTERVAL_S then
        return tracker.poi_cache
    end
    local out = {}
    if not StaticPatherPlugin or not StaticPatherPlugin.get_actors then
        tracker.poi_cache = out
        tracker.last_poi_rebuild_t = now
        return out
    end
    local actors = StaticPatherPlugin.get_actors()
    if not actors or #actors == 0 then
        tracker.poi_cache = out
        tracker.last_poi_rebuild_t = now
        return out
    end
    local ctx = {
        visited          = tracker.visited,
        settings         = settings,
        back_portal_pos  = tracker.back_portal_pos,
    }
    for _, a in ipairs(actors) do
        local s, d = score_poi(a, ctx)
        if s then
            out[#out + 1] = {
                kind = a.kind, skin = a.skin,
                x = a.x, y = a.y, z = a.z, floor = a.floor,
                score = s, dist = d,
            }
        end
    end
    table.sort(out, function (a, b) return a.score > b.score end)
    tracker.poi_cache = out
    tracker.last_poi_rebuild_t = now
    return out
end

return M
