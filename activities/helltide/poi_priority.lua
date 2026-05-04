-- ---------------------------------------------------------------------------
-- activities/helltide/poi_priority.lua
--
-- The brain of the new helltide module.  Replaces ~1000 lines of waypoint
-- patrols + frontier-BFS exploration in the old plugin with a priority
-- queue over actors in StaticPather's merged WarMap data.
--
-- Each POI is a table:
--   { kind, skin, x, y, z, floor,            -- copied from StaticPather actor entry
--     score,                                 -- computed priority (higher = pick first)
--     dist,                                  -- meters from player at score time
--     blocked_reason }                       -- string | nil; why we can't currently take it
--
-- The priority queue is built fresh every ~1.5s (POI_REBUILD_INTERVAL_S).
-- Stale beyond that and we recompute -- distances change as the player
-- moves and cinder counts as we open chests.
-- ---------------------------------------------------------------------------

local enums       = require 'activities.helltide.data.enums'
local quest_state = require 'activities.helltide.quest_state'

local M = {}

local POI_REBUILD_INTERVAL_S = 1.5

-- ---------------------------------------------------------------------------
-- Type weights.  Bigger = pick first regardless of distance.  Tortured
-- Gifts (cinder chests) trump everything else when affordable; pyres
-- trump in maiden mode; shrines and ores tie on a distance contest.
-- ---------------------------------------------------------------------------
local TYPE_WEIGHT = {
    chest_helltide_targeted = 1000,   -- Tortured Gifts (rare, costs cinders)
    chest_helltide_random   =  800,   -- standard helltide chest (free)
    chest_helltide_silent   =  700,   -- silent chest (key required)
    chest                   =  500,   -- generic chest
    pyre                    =  600,   -- maiden pyre (boost in maiden_mode below)
    shrine                  =  300,
    ore                     =  150,
    herb                    =  150,
    objective               =  400,   -- random world events
    portal_helltide         =  900,   -- maiden portal (chambers)
}

local DEFAULT_WEIGHT = 100

-- Distance falls off linearly: 100m far -> -50 score, 0m near -> 0 score.
-- So a 1000-weight Tortured Gift at 100m beats a 800-weight chest at 0m.
-- Tune coefficient to taste; lower = more "go to whatever's closest".
local DISTANCE_COEFF = 0.5

-- Enemy-kind catalog entries (recorded for navigation hints but not
-- interact targets).  Blocking them here keeps ghost elites out of the
-- queue entirely instead of letting them flow through at DEFAULT_WEIGHT
-- and wasting budget + walk time.
local EXCLUDED_KINDS = {
    champion = true,
    elite    = true,
    boss     = true,
    miniboss = true,
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function get_cinders()
    if get_helltide_coin_cinders then
        local ok, n = pcall(get_helltide_coin_cinders)
        if ok and type(n) == 'number' then return n end
    end
    return 0
end

local function chest_cost(poi)
    if not poi.skin then return nil end
    return enums.chest_types[poi.skin]
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

-- ---------------------------------------------------------------------------
-- Score a single POI.  Returns nil if the POI is filterable-out (visited,
-- toggled-off, unaffordable), else a numeric score.
-- ---------------------------------------------------------------------------
local function score_poi(poi, ctx)
    if EXCLUDED_KINDS[poi.kind or ''] then return nil end

    if ctx.visited[string.format('%s:%d:%d',
        poi.skin or poi.kind or '?',
        math.floor(poi.x or 0),
        math.floor(poi.y or 0))]
    then
        return nil   -- already done this run
    end

    -- Setting-toggle gates
    if poi.kind == 'chest' or poi.kind == 'chest_helltide_random' or poi.kind == 'chest_helltide_targeted' then
        if not ctx.settings.do_chests then return nil end
    elseif poi.kind == 'chest_helltide_silent' then
        if not ctx.settings.do_silent_chests then return nil end
    elseif poi.kind == 'ore' then
        if not ctx.settings.do_ores then return nil end
    elseif poi.kind == 'herb' then
        if not ctx.settings.do_herbs then return nil end
    elseif poi.kind == 'shrine' then
        if not ctx.settings.do_shrines then return nil end
    elseif poi.kind == 'pyre' then
        if not ctx.settings.do_pyres then return nil end
    elseif poi.kind == 'objective' then
        if not ctx.settings.do_events then return nil end
    end

    -- Cinder gate for Tortured Gifts: don't queue chests we can't afford.
    -- (We still REMEMBER them via tracker so we can come back when we have
    -- enough cinders -- handled in farm_chest task, not here.)
    local cost = chest_cost(poi)
    if cost and cost > 0 then
        local cinders = ctx.cinders
        if cinders < cost then
            return nil   -- not affordable yet
        end
    end

    local weight = TYPE_WEIGHT[poi.kind] or DEFAULT_WEIGHT

    -- Maiden mode: pyres + portal_helltide rocket to the top.
    if ctx.maiden_active then
        if poi.kind == 'pyre' or poi.kind == 'portal_helltide' then
            weight = weight + 500
        end
    end

    -- WarPlan directive bonus: when a Helltide WarPlan is active and its
    -- objective is asking for a specific chest type, bump that type's
    -- weight so the bot prioritizes it over generic chests.  Without
    -- this bias the priority queue would still WORK (Tortured Gifts
    -- already top the table at 1000), but multi-step objectives like
    -- "open 3 silent chests" would walk past silents to grab tortured
    -- gifts that don't tick the counter.
    if ctx.directive then
        if ctx.directive == 'tortured_gifts'
           and poi.kind == 'chest_helltide_targeted'
        then weight = weight + 400 end
        if ctx.directive == 'silent_chests'
           and poi.kind == 'chest_helltide_silent'
        then weight = weight + 400 end
        if ctx.directive == 'random_chests'
           and (poi.kind == 'chest_helltide_random' or poi.kind == 'chest')
        then weight = weight + 400 end
    end

    -- Distance penalty
    local d2 = dist2_player(poi)
    local d  = math.sqrt(d2)
    local score = weight - (d * DISTANCE_COEFF)
    return score, d
end

-- ---------------------------------------------------------------------------
-- Build the priority queue.  Caller passes:
--   tracker        from activities/helltide/tracker.lua (for visited dedup)
--   settings       from activities/helltide/settings.lua (for toggles)
--   maiden_active  bool -- true while the maiden event is going
--
-- Returns: array of POI tables, sorted by score descending.  Empty array
-- if StaticPather has no data for this zone (caller falls back to Batmobile).
-- ---------------------------------------------------------------------------
M.build = function (tracker, settings, maiden_active)
    -- Use cache if fresh; rebuilding every pulse churns
    -- StaticPatherPlugin.get_actors().
    local now = get_time_since_inject and get_time_since_inject() or 0
    if tracker.poi_cache and (now - tracker.last_poi_rebuild_t) < POI_REBUILD_INTERVAL_S then
        return tracker.poi_cache
    end

    local out = {}
    if not StaticPatherPlugin or not StaticPatherPlugin.get_actors then
        tracker.poi_cache = out
        tracker.last_poi_rebuild_t = now
        return out
    end

    local actors = StaticPatherPlugin.get_actors()   -- all kinds, current zone
    if not actors or #actors == 0 then
        tracker.poi_cache = out
        tracker.last_poi_rebuild_t = now
        return out
    end

    -- Read the live WarPlan helltide objective (if any) so we can bias
    -- chest scoring toward whatever the quest is asking for.  Standalone
    -- mode returns nil here -- ctx.directive stays nil and the priority
    -- queue runs in its default "open the most valuable thing nearest"
    -- mode, which is what the user wants for standalone ("just run
    -- around opening as many chests as we can").
    local wp = quest_state.read()
    local directive = wp and wp.directive or nil

    local ctx = {
        visited       = tracker.visited,
        settings      = settings,
        cinders       = get_cinders(),
        maiden_active = maiden_active,
        directive     = directive,
    }
    for _, a in ipairs(actors) do
        local s, d = score_poi(a, ctx)
        if s then
            local poi = {
                kind = a.kind, skin = a.skin,
                x = a.x, y = a.y, z = a.z, floor = a.floor,
                score = s, dist = d,
            }
            out[#out + 1] = poi
        end
    end

    -- Live actor stream scan: capture helltide POIs visible right now that
    -- aren't in the catalog (sparse zones, rotation variants, etc.).
    -- Runs every build() cycle alongside the catalog scan so zones with
    -- zero catalog data still populate the queue as chests come into view.
    if actors_manager and actors_manager.get_ally_actors then
        for _, a in pairs(actors_manager:get_ally_actors()) do
            local sn = a.get_skin_name and a:get_skin_name() or ''
            local kind = nil
            if sn:find('usz_rewardGizmo', 1, true) then
                kind = 'chest_helltide_targeted'
            elseif sn:find('usz_silentChest', 1, true) then
                kind = 'chest_helltide_silent'
            elseif sn:find('Pyre_Helltide', 1, true) then
                kind = 'pyre'
            end
            if kind then
                local ap = a.get_position and a:get_position()
                if ap then
                    local live_poi = {
                        kind = kind, skin = sn,
                        x = ap:x(), y = ap:y(), z = ap:z(),
                    }
                    local s, d = score_poi(live_poi, ctx)
                    if s then
                        out[#out + 1] = {
                            kind = kind, skin = sn,
                            x = ap:x(), y = ap:y(), z = ap:z(),
                            score = s, dist = d,
                            live_actor = a,   -- stash so interact_poi can skip the stream search
                        }
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
