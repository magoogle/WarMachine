-- ---------------------------------------------------------------------------
-- activities/pit/tasks/push_monsters.lua
--
-- Cluster-based mob pulling for high-tier pit clears.  Vanilla
-- kill_monster picks the nearest enemy one at a time and engages,
-- which is fine for sparse encounters but slow when you need to
-- progress-bar a Pit T100+ in a time limit -- you want to PULL dense
-- packs together and AOE them down, not pick off individuals.
--
-- Behavior:
--   1. Scan all enemies within `push_max_pull_dist` (default 50y).
--   2. Filter to those BEYOND `PUSH_ENGAGE_RANGE` (15y) -- enemies
--      already-near are owned by kill_monster, no need to walk anywhere.
--   3. Greedy-cluster the distant enemies: each enemy joins the nearest
--      centroid within PUSH_CLUSTER_RADIUS, else starts a new cluster.
--      Centroids are weighted by rank (boss > champion > elite > mob).
--   4. Score clusters in two tiers:
--      Tier 1: weighted-size >= push_threshold  -> big-pack bonus +
--               closeness; always preferred over tier 2.
--      Tier 2: weighted / distance.
--   5. Walk toward the chosen cluster's weighted centroid via core/move.
--   6. Watch nav progress; if no progress for PUSH_NAV_TIMEOUT seconds,
--      blacklist the cluster's 5y grid cell for PUSH_CLUSTER_COOLDOWN
--      so a single unreachable cluster can't trap us indefinitely.
--   7. Yield to kill_monster the moment weighted enemies near the
--      player exceed the threshold (the pull worked -- now AOE).
--
-- Disabled when:
--   * Boss visible (kill_monster owns boss combat).
--   * Walker reports trapped (escape system owns traversal routing).
--   * Glyphstone present (post-boss safe zone).
--   * speed_run setting (skip mid-floor encounters entirely).
--
-- Pattern ported from ArkhamAsylum-1.0.6/tasks/push_monsters.lua,
-- adapted to use WarMachine's core.move and core.find.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local find     = require 'core.find'
local zone     = require 'core.zone'
local settings = require 'activities.pit.settings'
local tracker  = require 'activities.pit.tracker'

-- Constants (mirroring Arkham's tunings; if a future user wants these
-- knob-able, hoist into settings + GUI sliders).
local PUSH_ENGAGE_RANGE     = 15      -- enemies inside this radius are "engaged"
local PUSH_CLUSTER_RADIUS   = 15      -- enemies within this of a centroid join it
local PUSH_MIN_PULL_DIST    = 8       -- ignore clusters already at our feet
local PUSH_ARRIVAL_DIST     = 5       -- "we got there" check radius
local PUSH_STUCK_TIMEOUT    = 5       -- seconds without movement -> reset walker
local PUSH_NAV_TIMEOUT      = 12      -- seconds without nav progress -> abandon cluster
local PUSH_CLUSTER_COOLDOWN = 30      -- seconds to ignore an abandoned cluster

-- Default tunings -- exposed via the settings table so the GUI can knob
-- them later.  All defaulted here so this task works even if the user
-- hasn't added the sliders yet.
local function s_get(name, default)
    local v = rawget(settings, name)
    if type(v) == 'number' then return v end
    if type(v) == 'boolean' then return v end
    return default
end

local function push_threshold()      return s_get('push_threshold',         5)   end
local function push_max_pull_dist()  return s_get('push_max_pull_dist',     50)  end
local function push_min_cluster()    return s_get('push_min_cluster_weight', 1)  end
local function w_boss()              return s_get('push_boss_weight',        4)  end
local function w_champion()          return s_get('push_champion_weight',    2)  end
local function w_elite()             return s_get('push_elite_weight',     1.5)  end

-- Module state (single in-flight pull at a time).
local _pull_target        = nil       -- vec3
local _actively_pulling   = false     -- prevents flicker between push/kill
local _nav = { pos = nil, time = 0, dist = nil }
local _stuck_pos          = nil
local _stuck_time         = 0

-- Cluster cooldown: positions abandoned due to nav timeout, keyed on a
-- 5y grid cell so centroid drift around the same impassable spot stays
-- inside the same blacklist entry.
local _cluster_cooldown = {}

local function cluster_key(pos)
    return string.format('%d:%d',
        math.floor((pos.x or pos:x()) / 5),
        math.floor((pos.y or pos:y()) / 5))
end

local function mark_cluster_unreachable(pos)
    _cluster_cooldown[cluster_key(pos)] =
        (get_time_since_inject() or 0) + PUSH_CLUSTER_COOLDOWN
end

local function is_cluster_on_cooldown(pos)
    local key = cluster_key(pos)
    local exp = _cluster_cooldown[key]
    if not exp then return false end
    if (get_time_since_inject() or 0) > exp then
        _cluster_cooldown[key] = nil
        return false
    end
    return true
end

-- Per-actor weight; used both for cluster scoring AND for the
-- "weighted enemies near player" engagement-threshold check.
local function actor_weight(a)
    if a.is_boss     and a:is_boss()     then return w_boss(),     true  end
    if a.is_champion and a:is_champion() then return w_champion(), false end
    if a.is_elite    and a:is_elite()    then return w_elite(),    false end
    return 1, false
end

-- Live enemies in range.  Filters out:
--   * different floor (Z >= 5y off): can't be reached without traversal
--     and the pathfinder would reject a target there.
--   * dead (HP <= 1): leftovers about to despawn.
--   * untargetable: invuln or hidden.
local function get_enemies(player_pos, range)
    if not target_selector or not target_selector.get_near_target_list then return {} end
    local raw = target_selector.get_near_target_list(player_pos, range) or {}
    local out = {}
    for _, e in pairs(raw) do
        local hp = e.get_current_health and e:get_current_health() or 0
        local pz = e.get_position and e:get_position():z() or player_pos:z()
        if hp > 1
           and math.abs(pz - player_pos:z()) <= 5
           and not (e.is_untargetable and e:is_untargetable())
        then
            out[#out + 1] = e
        end
    end
    return out
end

local function weighted_count(enemies)
    local sum, has_boss = 0, false
    for _, e in ipairs(enemies) do
        local w, b = actor_weight(e)
        sum = sum + w
        if b then has_boss = true end
    end
    return sum, has_boss
end

-- Mass-weighted centroid of an enemy list.  Heavier ranks pull the
-- center harder so a single elite anchored at the back of a 4-mob pack
-- shifts the target toward where the elite stands.
local function weighted_centroid(enemies)
    local cx, cy, cz, total = 0, 0, 0, 0
    for _, e in ipairs(enemies) do
        local w = actor_weight(e)
        local p = e:get_position()
        cx = cx + p:x() * w
        cy = cy + p:y() * w
        cz = cz + p:z() * w
        total = total + w
    end
    if total == 0 then return nil end
    return vec3:new(cx / total, cy / total, cz / total)
end

-- Cluster distant enemies (those beyond PUSH_ENGAGE_RANGE) and pick the
-- best pull target.  Two-tier scoring -- big packs always beat small
-- ones, with closeness as the tiebreaker.
local function find_pull_target(player_pos)
    local all = get_enemies(player_pos, push_max_pull_dist())

    -- Distant subset: enemies past the engage range.
    local distant = {}
    for _, e in ipairs(all) do
        local d = find.dist2d(player_pos, e:get_position())
        if d > PUSH_ENGAGE_RANGE then distant[#distant + 1] = e end
    end
    if #distant == 0 then return nil end

    -- Greedy clustering.  Each enemy joins the nearest centroid within
    -- PUSH_CLUSTER_RADIUS or starts a new one.  Centroid is recomputed
    -- incrementally as enemies join.
    local clusters = {}
    for _, e in ipairs(distant) do
        local ep = e:get_position()
        local best_cluster, best_dist = nil, PUSH_CLUSTER_RADIUS
        for _, c in ipairs(clusters) do
            local cdist = find.dist2d(vec3:new(c.cx, c.cy, c.cz), ep)
            if cdist < best_dist then
                best_dist, best_cluster = cdist, c
            end
        end
        local w = actor_weight(e)
        if best_cluster then
            local n = best_cluster.count
            best_cluster.cx = (best_cluster.cx * n + ep:x()) / (n + 1)
            best_cluster.cy = (best_cluster.cy * n + ep:y()) / (n + 1)
            best_cluster.cz = (best_cluster.cz * n + ep:z()) / (n + 1)
            best_cluster.count    = n + 1
            best_cluster.weighted = best_cluster.weighted + w
        else
            clusters[#clusters + 1] = {
                cx = ep:x(), cy = ep:y(), cz = ep:z(),
                count = 1, weighted = w,
            }
        end
    end

    -- Score & pick.
    local TIER_BONUS = 1000
    local thresh     = push_threshold()
    local min_w      = push_min_cluster()
    local best_score, best_centroid = -1, nil
    for _, c in ipairs(clusters) do
        if c.weighted >= min_w then
            local centroid = vec3:new(c.cx, c.cy, c.cz)
            if not is_cluster_on_cooldown(centroid) then
                local d = find.dist2d(player_pos, centroid)
                if d >= PUSH_MIN_PULL_DIST then
                    local score
                    if c.weighted >= thresh then
                        score = TIER_BONUS + c.weighted - d
                    else
                        score = c.weighted / d
                    end
                    if score > best_score then
                        best_score    = score
                        best_centroid = centroid
                    end
                end
            end
        end
    end
    return best_centroid
end

-- ---------------------------------------------------------------------------
-- Task lifecycle
-- ---------------------------------------------------------------------------
local task = { name = 'push_monsters', status = 'idle' }

task.shouldExecute = function ()
    if not settings.kill_monsters then return false end
    if not zone.in_pit() then return false end
    -- Off by default until the user knobs it on; a stale run that
    -- doesn't have push_mode in settings will disable cleanly.
    if not s_get('push_mode', false) then return false end
    -- Boss owns combat (kill_monster handles the boss directly).
    if tracker.boss_seen and not tracker.boss_killed_at then return false end
    -- Post-boss safe zone (glyphstone phase).  Once we've stamped the
    -- boss-kill timestamp, kill_monster + push_monsters both yield;
    -- upgrade_glyph + exit own the rest of the run.
    if tracker.boss_killed_at then return false end
    -- Walker trapped: yield so escape logic can run.
    local n = rawget(_G, 'WarMachineNav')
    if n and n.is_trapped and n.is_trapped() then
        _pull_target      = nil
        _actively_pulling = false
        return false
    end

    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end

    local enemies_near = get_enemies(pp, PUSH_ENGAGE_RANGE)
    local weighted, has_boss = weighted_count(enemies_near)

    -- Always yield to kill_monster for bosses.
    if has_boss then
        _pull_target      = nil
        _actively_pulling = false
        return false
    end

    -- Already pulling: keep going (stickiness avoids flicker).
    if _actively_pulling then return true end

    -- No enemies anywhere near -> let seek_progression / freeroam find them.
    if weighted == 0 then return false end

    -- Enemies nearby but below threshold -> push mode handles by pulling
    -- a denser cluster IF one exists; if no cluster found, kill_monster
    -- handles the few-mobs case.
    if weighted >= push_threshold() then return false end
    return find_pull_target(pp) ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local now = get_time_since_inject() or 0

    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end

    local enemies_near        = get_enemies(pp, PUSH_ENGAGE_RANGE)
    local weighted, has_boss  = weighted_count(enemies_near)

    -- Phase 1: continue toward the existing pull target.
    if _pull_target then
        local d = find.dist2d(pp, _pull_target)

        -- Arrived.
        if d < PUSH_ARRIVAL_DIST then
            _pull_target      = nil
            _actively_pulling = false
            _nav.pos          = nil
            -- Fall through to the engage-or-rescan branch.
        else
            -- Threshold met mid-pull -> the pulled mobs are clumped on
            -- top of us now; stop pulling, let kill_monster engage.
            if weighted >= push_threshold() then
                _pull_target      = nil
                _actively_pulling = false
                _nav.pos          = nil
                move.clear()
            else
                -- Nav progress check.  Reset when we change target
                -- substantially or close ground; abandon when stuck.
                if _nav.pos == nil
                   or find.dist2d(_pull_target, _nav.pos) > 5
                then
                    _nav.pos  = _pull_target
                    _nav.time = now
                    _nav.dist = d
                elseif d < (_nav.dist or math.huge) - 2 then
                    _nav.dist = d
                    _nav.time = now
                elseif (now - _nav.time) > PUSH_NAV_TIMEOUT then
                    mark_cluster_unreachable(_pull_target)
                    _pull_target      = nil
                    _actively_pulling = false
                    _nav.pos          = nil
                    move.clear()
                    task.status = 'cluster nav timeout, cooled down'
                    return
                end
            end
        end

        if _pull_target then
            -- Stuck recovery: if the player hasn't moved more than 3y
            -- in PUSH_STUCK_TIMEOUT seconds, kick the walker.
            if _stuck_pos == nil or find.dist2d(pp, _stuck_pos) > 3 then
                _stuck_pos  = pp
                _stuck_time = now
            elseif (now - _stuck_time) > PUSH_STUCK_TIMEOUT then
                move.clear()
                _stuck_pos  = nil
                _stuck_time = now
            end

            -- Drive the walker.
            local d_to = find.dist2d(pp, _pull_target)
            move.to_pos(_pull_target,
                { arrive_radius = PUSH_ARRIVAL_DIST,
                  long_path     = d_to > 25 })
            _actively_pulling = true
            task.status = string.format('pulling cluster (%.0fm)', d_to)
            return
        end

        -- Recompute nearby after state changes.
        enemies_near        = get_enemies(pp, PUSH_ENGAGE_RANGE)
        weighted, has_boss  = weighted_count(enemies_near)
    end

    -- Phase 2: threshold met locally -> walk to the dense center of
    -- the nearby pack (lets AOE land on the densest spot).
    if weighted >= push_threshold() then
        local centroid = weighted_centroid(enemies_near)
        if centroid then
            local d = find.dist2d(pp, centroid)
            if d > 2 then
                move.to_pos(centroid, { arrive_radius = 2 })
                task.status = string.format('engaging dense pack (w=%.1f, %.0fm)',
                    weighted, d)
                return
            end
        end
        task.status = 'in pack center'
        return
    end

    -- Phase 3: pick a new pull target.
    local target = find_pull_target(pp)
    if target then
        _pull_target      = target
        _actively_pulling = true
        _nav              = { pos = target, time = now,
                              dist = find.dist2d(pp, target) }
        move.to_pos(target,
            { arrive_radius = PUSH_ARRIVAL_DIST,
              long_path     = _nav.dist > 25 })
        task.status = string.format('pulling new cluster (%.0fm)', _nav.dist)
        return
    end

    -- Nothing to pull and not enough mobs to engage in place.  Yield.
    task.status = 'idle'
end

return task
