-- activities/nmd/poi_priority.lua

local M = {}

-- Skin patterns that should be SCORED AS OBJECTIVES even when the
-- recorder classified them as the catch-all 'interactable' kind.
--
-- Why: the recorder's actor_capture has expanded its `objective`
-- kind to include DGN_Switch / DGN_Lever / NMD_Pedestal / etc., but
-- existing catalog data captured before that change still tags
-- these as `kind = 'interactable'`.  Without a runtime fallback the
-- old data scores at DEFAULT_WEIGHT (80) and the bot deprioritizes
-- gating interactables behind cosmetic chests.
--
-- Patterns are Lua regex; the matcher uses string.match.  Substring
-- patterns (e.g. 'DGN_Switch') work fine because Lua's match treats
-- a plain string as a literal substring search when no special
-- characters are present.
local OBJECTIVE_SKIN_PATTERNS = require 'activities.nmd.data.objective_patterns'

local POI_REBUILD_INTERVAL_S = 1.5

local TYPE_WEIGHT = {
    objective       = 1200,    -- gating interactables (pedestal, lever, door)
    chest_horadric  =  900,    -- end-of-dungeon reward cache; rare and per-run
    chest           =  500,
    chest_helltide_random = 500,
    shrine          =  300,
    -- Carry-objects: pick-up-and-ferry quest items.  Same gating
    -- priority as a switch -- you can't progress without taking
    -- them somewhere.
    carry_object    = 1200,
    -- NMD-specific glyph stone (post-boss XP upgrade).  High
    -- priority but only after the boss room is open; the runner's
    -- task ordering handles the temporal gating.
    glyph_gizmo     = 1100,
}
local DEFAULT_WEIGHT = 80
local DISTANCE_COEFF = 0.5

-- Memoized "does this skin look like an objective?" -- the regex
-- loop runs once per unique skin per session.  Per-pulse this
-- becomes a single hash lookup for the typical 50-200 catalog
-- entries we score.
local _skin_is_objective_cache = {}
local function skin_is_objective(skin)
    if not skin or skin == '' then return false end
    local cached = _skin_is_objective_cache[skin]
    if cached ~= nil then return cached end
    for _, pat in ipairs(OBJECTIVE_SKIN_PATTERNS) do
        if skin:match(pat) then
            _skin_is_objective_cache[skin] = true
            return true
        end
    end
    _skin_is_objective_cache[skin] = false
    return false
end

local function dist2_player(poi)
    local lp = get_local_player()
    if not lp then return math.huge end
    local pp = lp:get_position()
    if not pp then return math.huge end
    local dx = (poi.x or 0) - pp:x()
    local dy = (poi.y or 0) - pp:y()
    return dx*dx + dy*dy
end

-- Kinds that interact_poi has NO business handling (enemy actors are
-- catalogued by the recorder for navigation hints, but they're
-- kill_monster's job, not interact_poi's).  Without this filter, the
-- queue ends up with champion/elite zombies as low-weight candidates;
-- interact_poi walks to them, can't interact (they're not chests),
-- waits the timeout, marks stale, repeats next pulse for hundreds of
-- catalogued mobs.  Worse, while it's iterating these, kill_monster
-- never gets a turn to actually engage them.
local EXCLUDED_KINDS = {
    champion          = true,
    elite             = true,
    boss              = true,
    miniboss          = true,
    -- Generic 'interactable' is too broad -- includes one-shot
    -- consumables like Receptacle (after use).  We explicitly handle
    -- known sub-kinds (chest_*, shrine, objective) above; anything
    -- else gets default-weight which is fine, but we do NOT want
    -- enemy actors leaking through under default-weight.
}

local function score_poi(poi, ctx)
    local kind = poi.kind or ''
    if EXCLUDED_KINDS[kind] then return nil end

    local key = string.format('%s:%d:%d',
        poi.skin or kind or '?',
        math.floor(poi.x or 0),
        math.floor(poi.y or 0))
    if ctx.visited[key] then return nil end

    -- Effective kind: promote 'interactable' to 'objective' when the
    -- skin matches one of the OBJECTIVE_SKIN_PATTERNS.  This catches
    -- the old-data case where a DGN_Switch was captured before the
    -- recorder knew to call it an objective -- without this, those
    -- entries score at DEFAULT_WEIGHT (80) and the bot deprioritizes
    -- gating switches behind chests.  New captures arrive already
    -- tagged 'objective' so this branch is a no-op for fresh data.
    local effective_kind = kind
    if kind == 'interactable' and skin_is_objective(poi.skin) then
        effective_kind = 'objective'
    end

    if effective_kind == 'chest' or effective_kind == 'chest_helltide_random' or effective_kind == 'chest_horadric' then
        if not ctx.settings.do_chests then return nil end
    elseif effective_kind == 'shrine' then
        if not ctx.settings.do_shrines then return nil end
    elseif effective_kind == 'objective' or effective_kind == 'carry_object' then
        if not ctx.settings.do_objectives then return nil end
        -- Skip sealed doors and gates whose position is currently not
        -- walkable (objective-sealed boss-room doors, etc.).  This breaks
        -- the 6s soft-stale retry loop for permanently-blocked entries.
        -- NOTE: Blocker-type actors (key-gated side rooms) are intentionally
        -- excluded from this check -- the bot should keep retrying them
        -- ("interact/kill until the key drops") so they stay in the queue.
        local sn_lower = (poi.skin or ''):lower()
        if (sn_lower:find('door', 1, true) or sn_lower:find('gate', 1, true))
           and not sn_lower:find('blocker', 1, true)
           and utility and utility.is_point_walkeable
        then
            local probe = vec3:new(poi.x or 0, poi.y or 0, poi.z or ctx.player_z)
            local wok, walkable = pcall(utility.is_point_walkeable, probe)
            if wok and not walkable then return nil end
        end
    end

    local weight = TYPE_WEIGHT[effective_kind] or DEFAULT_WEIGHT
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
    local player_z = 0
    local lp = get_local_player and get_local_player()
    if lp then
        local lp_pos = lp:get_position()
        if lp_pos then player_z = lp_pos:z() end
    end
    local ctx = { visited = tracker.visited, settings = settings, player_z = player_z }

    -- Catalog scan: portals, chests, shrines, and any objectives that
    -- the recorder has already classified.  Many dungeons have partial
    -- or no catalog data -- the live scan below fills that gap.
    if StaticPatherPlugin and StaticPatherPlugin.get_actors then
        local actors = StaticPatherPlugin.get_actors()
        if actors then
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
        end
    end

    -- Live actor scan: catch gating objectives (switch, lever, pedestal …)
    -- that are in the D4 actor stream but not yet in the static catalog.
    -- 26/28 dungeon zones have zero objectives recorded; without this scan
    -- the bot arrives near the quest marker, stops (within 8m arrive radius),
    -- and wanders via freeroam without clicking the gating interactable.
    -- score_poi already deduplicates catalog entries that also appear here.
    if get_all_actors and ctx.settings.do_objectives then
        local all = get_all_actors()
        if all then
            for _, a in ipairs(all) do
                local sn = a.get_skin_name and a:get_skin_name() or ''
                if sn ~= '' and skin_is_objective(sn) then
                    if a.is_interactable and a:is_interactable() then
                        local ap = a.get_position and a:get_position()
                        if ap then
                            local live_poi = {
                                kind = 'objective', skin = sn,
                                x = ap:x(), y = ap:y(), z = ap:z(),
                            }
                            local s, d = score_poi(live_poi, ctx)
                            if s then
                                out[#out + 1] = {
                                    kind = 'objective', skin = sn,
                                    x = ap:x(), y = ap:y(), z = ap:z(),
                                    score = s, dist = d,
                                    live_actor = a,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(out, function (a, b) return a.score > b.score end)
    tracker.poi_cache = out
    tracker.last_poi_rebuild_t = now
    return out
end

return M
