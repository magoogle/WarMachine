-- ---------------------------------------------------------------------------
-- activities/undercity/poi_priority.lua
--
-- Same shape as helltide / pit but tuned for undercity:
--
--   undercity_exit         -- the floor-progression switch (X1_Undercity_PortalSwitch)
--   chest                  -- side-corridor chests + end-of-run attunement chest
--   enticement             -- spirit beacons + hearths (mid-run elite triggers)
--   shrine                 -- buff shrines
--
-- Hearth interactions are capped via tracker.hearth_count + settings.max_hearths.
-- ---------------------------------------------------------------------------

local M = {}

local POI_REBUILD_INTERVAL_S = 1.5

local TYPE_WEIGHT = {
    undercity_exit  = 1500,   -- floor switch -- top priority once revealed
    chest           =  500,
    chest_helltide_random = 500,
    enticement      =  400,
    shrine          =  300,
    objective       =  200,
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

local function is_hearth(poi)
    return poi.skin and poi.skin:find('SpiritHearth_Switch', 1, true) ~= nil
end

local function score_poi(poi, ctx)
    local key = string.format('%s:%d:%d',
        poi.skin or poi.kind or '?',
        math.floor(poi.x or 0),
        math.floor(poi.y or 0))
    if ctx.visited[key] then return nil end

    -- Speed-run mode: once the attunement orb count is at the cap (4/4 by
    -- default), additional enticements / shrines / mid-floor chests don't
    -- buy us any more rewards, so beeline the floor switch + boss room.
    -- Only undercity_exit (floor-progression switch) is left in the
    -- priority list; goto_chest is a separate task that handles the
    -- post-boss attunement chest.
    if ctx.settings.speed_run
       and ctx.hearth_count >= ctx.settings.max_hearths
       and poi.kind ~= 'undercity_exit'
    then
        return nil
    end

    if poi.kind == 'chest' or poi.kind == 'chest_helltide_random' then
        if not ctx.settings.do_chests then return nil end
    elseif poi.kind == 'enticement' then
        if not ctx.settings.do_enticements then return nil end
        -- Hearth cap: skip hearths once the limit is hit; beacons remain
        if is_hearth(poi) and ctx.hearth_count >= ctx.settings.max_hearths then
            return nil
        end
    end

    -- After boss appears, stop chasing enticements -- focus on the boss
    if ctx.boss_seen and (poi.kind == 'enticement' or poi.kind == 'shrine') then
        return nil
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
        visited       = tracker.visited,
        settings      = settings,
        boss_seen     = tracker.boss_seen,
        hearth_count  = tracker.hearth_count,
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
