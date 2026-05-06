local utils    = require 'core.nav.utils'
local settings = require 'core.nav.settings'
local tracker  = require 'core.nav.tracker'
local explorer = require 'core.nav.explorer'

local pathfinder = {}

-- Pre-computed constant
local SQRT2_MINUS1 = math.sqrt(2) - 1

-- Min-heap priority queue used by A* open set.
-- Replaces the previous O(n) linear scan (get_lowest_f_score) with O(log n)
-- push/pop, dramatically reducing pathfind time on large or complex maps.
-- Uses lazy deletion: stale heap entries (node already closed) are skipped on pop.
local Heap = {}
Heap.__index = Heap
local function new_heap()
    return setmetatable({ data = {}, size = 0 }, Heap)
end
function Heap:push(f, node_str, node)
    self.size = self.size + 1
    self.data[self.size] = { f = f, s = node_str, n = node }
    -- sift up
    local i = self.size
    local d = self.data
    while i > 1 do
        local p = math.floor(i / 2)
        if d[p].f <= d[i].f then break end
        d[p], d[i] = d[i], d[p]
        i = p
    end
end
function Heap:pop()
    local top = self.data[1]
    local last = self.data[self.size]
    self.data[self.size] = nil
    self.size = self.size - 1
    if self.size > 0 then
        self.data[1] = last
        -- sift down
        local i = 1
        local d = self.data
        local sz = self.size
        while true do
            local s = i
            local l = i * 2
            local r = l + 1
            if l <= sz and d[l].f < d[s].f then s = l end
            if r <= sz and d[r].f < d[s].f then s = r end
            if s == i then break end
            d[i], d[s] = d[s], d[i]
            i = s
        end
    end
    return top.f, top.s, top.n
end
function Heap:empty() return self.size == 0 end
local heuristic = function (a, b)
    local dx = math.abs(a:x() - b:x())
    local dy = math.abs(a:y() - b:y())
    return math.max(dx, dy) + SQRT2_MINUS1 * math.min(dx, dy)
end
local reconstruct_path = function (closed_set, prev_nodes, cur_node)
    local path = {cur_node}
    local cur_str = utils.vec_to_string(cur_node)
    while prev_nodes[cur_str] ~= nil do
        cur_str = prev_nodes[cur_str]
        cur_node = closed_set[cur_str]
        table.insert(path, 1, cur_node)
    end
    return path
end

-- Soft wall-proximity cost: every cell with blocked cells in its 8-cell R1
-- ring or 16-cell R2 ring gets a g-score penalty.  A* drifts toward corridor
-- centers without becoming infeasible in doorways/portals.
--
-- R2 (the wider ring) is what pushes the path to the MIDDLE of wide
-- hallways.  Without it, every cell in a 5-wide hallway except the literal
-- edges has 0 R1 penalty and A* picks the shortest path (edge-hugging).
-- R2 penalty is smaller per cell so doorways (where R2 walls are
-- unavoidable) stay traversable.
local WALL_PENALTY_R1 = 0.7
local WALL_PENALTY_R2 = 0.15

-- Persistent across find_path calls.  The wall-ring penalty is a function
-- of the static walkable grid, so caching it avoids redoing the ring
-- evaluation on every search.  Keyed by "node_str|z_floor" so floor
-- changes don't pollute results.  Cleared explicitly via
-- pathfinder.clear_wall_penalty_cache() on session/zone transitions if
-- terrain may have changed.
local wall_penalty_cache = {}
local function wp_key(node_str, z)
    return node_str .. '|' .. tostring(math.floor(z + 0.5))
end
pathfinder.clear_wall_penalty_cache = function()
    wall_penalty_cache = {}
end

-- Fast walkability lookup that prefers explorer.scanned (warm cache from
-- past visits, including persisted overworld data) and falls back to the
-- per-call evaluated cache, then to a fresh engine walk-check on cold
-- cells.  Returns boolean.  This is what makes wall-ring evaluation cheap
-- enough to apply on long paths -- engine calls (utility.is_point_walkeable
-- via utils.get_valid_node) are the expensive bit; everything else is
-- table lookups.
local function fast_walkable(neigh_str, neigh_x, neigh_y, cur_z, goal_z, evaluated)
    local s = explorer.scanned[neigh_str]
    if s == false then return false end          -- known wall
    if s == true  then return true  end          -- known walkable (no engine call needed)
    local r = evaluated[neigh_str]
    if r ~= nil then return r[1] end
    -- Cold: engine call, then cache.
    local n = utils.get_valid_node(vec3:new(neigh_x, neigh_y, cur_z), goal_z)
    evaluated[neigh_str] = { n ~= nil, n }
    return n ~= nil
end

local get_valid_neighbor = function (cur_node, goal, x, y, evaluated, ignore_walls, directions)
    local node, node_str, result, valid
    node_str = tostring(x) .. ',' .. tostring(y)
    result = evaluated[node_str]
    if result == nil then
        node = vec3:new(x, y, cur_node:z())
        node = utils.get_valid_node(node, goal:z())
        valid = node ~= nil
    else
        valid, node = result[1], result[2]
    end

    evaluated[node_str] = {valid, node}
    if not valid then
        return nil, evaluated, 0
    end

    if ignore_walls then
        return node, evaluated, 0
    end

    -- Per-cell ring-penalty cache lookup.  Skips the 8+16 ring walkability
    -- checks entirely on cache hit.  Trade-off: drops the goal-adjacency
    -- special case (where the goal cell is treated as walkable in the ring),
    -- so cells next to a non-walkable goal get up to +0.7 over-penalty.  A*
    -- still routes through them when needed (over-cost doesn't change
    -- feasibility).
    local cache_k = wp_key(node_str, node:z())
    local cached = wall_penalty_cache[cache_k]
    if cached ~= nil then
        return node, evaluated, cached
    end

    local step    = settings.step
    local cur_z   = cur_node:z()
    local goal_z  = goal:z()
    local nx, ny  = node:x(), node:y()
    local penalty = 0

    -- R1: 8 immediate neighbours (the existing 8 directions).  Each
    -- non-walkable adds WALL_PENALTY_R1.  This is what makes corner cells
    -- expensive and keeps the path from cutting through wall corners.
    for _, direction in ipairs(directions) do
        local newx = nx + direction[1]
        local newy = ny + direction[2]
        local key  = tostring(newx) .. ',' .. tostring(newy)
        if not fast_walkable(key, newx, newy, cur_z, goal_z, evaluated) then
            penalty = penalty + WALL_PENALTY_R1
        end
    end

    -- R2: 16 cells in the second ring (skipping the corners further out).
    -- WALL_PENALTY_R2 is intentionally smaller per-cell -- in a 5-wide
    -- hallway the cells one step in from the edge see ~3 R2 walls and pick
    -- up ~0.45 cost, while the centerline sees zero, so A* drifts to the
    -- middle.  Doorways have unavoidable R2 walls but the per-cell cost is
    -- low enough that the path still threads through them.
    local r2_offsets = {
        { -2*step,    0    }, {  2*step,    0    },
        {    0,    -2*step }, {    0,     2*step },
        { -2*step,    step }, { -2*step,   -step },
        {  2*step,    step }, {  2*step,   -step },
        {   -step, -2*step }, {   -step,  2*step },
        {    step, -2*step }, {    step,  2*step },
        { -2*step, -2*step }, { -2*step,  2*step },
        {  2*step, -2*step }, {  2*step,  2*step },
    }
    for i = 1, #r2_offsets do
        local dxr = r2_offsets[i][1]
        local dyr = r2_offsets[i][2]
        local newx = nx + dxr
        local newy = ny + dyr
        local key  = tostring(newx) .. ',' .. tostring(newy)
        if not fast_walkable(key, newx, newy, cur_z, goal_z, evaluated) then
            penalty = penalty + WALL_PENALTY_R2
        end
    end

    wall_penalty_cache[cache_k] = penalty
    return node, evaluated, penalty
end
local get_neighbors = function (node, goal, evaluated, ignore_walls, directions)
    local neighbors = {}
    local penalties = {}
    for _, direction in ipairs(directions) do
        local dx = direction[1]
        local dy = direction[2]
        local newx = node:x() + dx
        local newy = node:y() + dy
        if (newx == goal:x() and newy == goal:y()) then
            neighbors = {goal}
            penalties = {0}
            break
        end
        local valid, p
        valid, evaluated, p = get_valid_neighbor(node, goal, newx, newy, evaluated, ignore_walls, directions)

        if valid ~= nil then
            neighbors[#neighbors+1] = valid
            penalties[#penalties+1] = p or 0
        end
    end
    return neighbors, evaluated, penalties
end

-- Line-of-sight walkability check between two nodes, sampled at `step` intervals.
-- Used by string_pull to decide if two non-adjacent waypoints can be directly connected.
local function has_los(a, b, step)
    local dx = b:x() - a:x()
    local dy = b:y() - a:y()
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist <= step then return true end
    local steps = math.ceil(dist / step)
    local sx = dx / steps
    local sy = dy / steps
    local az, bz = a:z(), b:z()
    for i = 1, steps - 1 do
        local p = vec3:new(a:x() + sx * i, a:y() + sy * i, az)
        if utils.get_valid_node(p, bz) == nil then
            return false
        end
    end
    return true
end

-- String-pull / funnel-style waypoint reduction.  Drops intermediate path nodes
-- whose preceding and following waypoints have a clear line of sight, so the
-- navigator steers along long straight segments instead of every 0.5u grid cell.
-- Lookahead is capped (LOS_MAX_LOOKAHEAD) to bound LOS work on long paths.
local LOS_MAX_LOOKAHEAD = 30
local function string_pull(path, step)
    if #path <= 2 then return path end
    local out = {path[1]}
    local i = 1
    while i < #path do
        local last_good = i + 1
        local j_end = math.min(#path, i + LOS_MAX_LOOKAHEAD)
        local j = i + 2
        while j <= j_end do
            if has_los(path[i], path[j], step) then
                last_good = j
                j = j + 1
            else
                break
            end
        end
        out[#out + 1] = path[last_good]
        i = last_good
    end
    return out
end
pathfinder.string_pull = string_pull

-- Bench wrapper: lets find_path see how much A* time is post-process smoothing,
-- and reports input/output node counts at peak (meta only stamps on new max).
local function pull_bench(path, step)
    tracker.bench_start("string_pull")
    local out = string_pull(path, step)
    tracker.bench_stop("string_pull", string.format("in=%d out=%d", #path, #out))
    return out
end

-- Bucketed A* iteration histogram: reveals whether spikes come from a few rare
-- 5000-iter searches or many smaller ones.
local function pf_bucket(counter)
    if counter < 100 then return "iters_lt100"
    elseif counter < 500 then return "iters_lt500"
    elseif counter < 2000 then return "iters_lt2000"
    else return "iters_ge2000" end
end

-- Engine micro-pathfinder.  The host's world:calculate_path runs A* on
-- the actual game nav mesh, which knows where the walls are -- our
-- in-script BFS infers wall positions from sparse explorer.scanned
-- data, and on unfamiliar terrain that can route us into geometry.
-- Range cap is the host's (~150 units; reliable to ~120).  Used as a
-- fast-path: try the engine first for short hops, fall through to the
-- BFS A* below on out-of-range / no-path / API-missing.
--
-- The engine returns waypoints at 0.5u grid resolution -- 50+ points
-- on a typical 25u hop.  Feeding that raw to the navigator produces
-- visible stutter (it ticks through micro-waypoints every pulse,
-- causing the "step-pause-step" pattern).  We sparsify with a
-- distance-only filter (min 2u spacing) before returning -- preserves
-- the engine's route geometry exactly (no LOS-based rerouting that
-- could shortcut over a cliff), just drops intermediate points the
-- navigator doesn't need to follow individually.
local ENGINE_PATH_MAX_DIST    = 100  -- below the host's 100-120 reliability band
local ENGINE_PATH_MIN_SPACING = 2.0  -- min yards between kept waypoints

local function sparsify_engine_path(path)
    if #path <= 2 then return path end
    local out  = { path[1] }
    local last = path[1]
    local thr2 = ENGINE_PATH_MIN_SPACING * ENGINE_PATH_MIN_SPACING
    for i = 2, #path - 1 do
        local p  = path[i]
        local dx = p:x() - last:x()
        local dy = p:y() - last:y()
        if (dx * dx + dy * dy) >= thr2 then
            out[#out + 1] = p
            last = p
        end
    end
    out[#out + 1] = path[#path]   -- always keep the final waypoint
    return out
end

local function try_engine_path(start, goal, dist)
    if dist > ENGINE_PATH_MAX_DIST then return nil end
    local w = get_current_world()
    if not w or not w.calculate_path then return nil end
    local ok, result = pcall(function () return w:calculate_path(start, goal) end)
    if not ok or type(result) ~= 'table' or #result == 0 then return nil end
    return sparsify_engine_path(result)
end

pathfinder.find_path = function (start, goal, is_custom_target, shared_evaluated, time_cap_override)
    tracker.bench_start("find_path")
    utils.log(2, 'start find path')
    local start_node = utils.normalize_node(start)
    local goal_node  = utils.normalize_node(goal)
    local start_str  = utils.vec_to_string(start_node)

    -- ---- Engine micro-path fast-path -------------------------------------
    -- For short hops, try the host's nav-mesh A* before falling back to
    -- the in-script BFS.  Engine paths are always complete (never
    -- partial) and respect actual wall geometry, so the (sparsified)
    -- vec3[] can drop straight into navigator.path.
    do
        local d = utils.distance(start_node, goal_node)
        local engine_path = try_engine_path(start, goal, d)
        if engine_path then
            tracker.bench_count("pf_engine_hit")
            tracker.bench_stop("find_path",
                string.format("engine plen=%d dist=%.0f spacing=%.1f custom=%s",
                    #engine_path, d, ENGINE_PATH_MIN_SPACING, tostring(is_custom_target)))
            return engine_path, false
        end
    end

    -- Min-heap open set (lazy deletion — stale entries skipped when popped)
    local heap      = new_heap()
    local in_open   = {}   -- node_str -> best g_score pushed so far (for duplicate suppression)
    local closed_set = {}
    local g_score   = { [start_str] = 0 }
    local prev_nodes = {}
    local counter   = 0
    local evaluated = shared_evaluated or {}
    local path_start_time = os.clock()

    -- Track the best (closest-to-goal) node seen during search so we can
    -- return a partial path on failure instead of an empty table.
    local best_node     = start_node
    local best_node_h   = heuristic(start_node, goal_node)
    local best_node_str = start_str

    -- Scale limits by distance: far targets need more A* iterations.
    -- Single 150ms cap for both custom and explorer targets — was 350ms for
    -- custom but speed-mode through-points and other task targets all flag
    -- as is_custom_target=true, hitting the longer cap and stalling the main
    -- thread. Partial paths keep progress working when the cap is hit; if
    -- kill_monster ever needs the longer budget for a specific call site we
    -- can plumb a per-call override.
    local goal_dist   = heuristic(start_node, goal_node)
    local iter_limit  = math.max(3000, math.min(10000, math.floor(goal_dist * 300)))
    -- Tiered time caps: failed (limit_partial) searches dominate spike cost
    -- when the target is unreachable.  Hard-limit the worst case based on
    -- distance — a 70u target that's actually unreachable used to hit the
    -- 150ms ceiling 5+ times per stall (750ms/5s wall time of pure waste).
    -- - <20u  : 100ms (close paths almost always succeed in <50ms)
    -- - 20-50u: 100ms (still affordable; most legit paths fit)
    -- - >50u  : 70ms  (failure is likely; cap the damage per attempt)
    local default_time_cap
    if goal_dist > 50 then
        default_time_cap = 0.070
    else
        default_time_cap = 0.100
    end
    local time_cap = time_cap_override or default_time_cap
    -- For tight per-call overrides (e.g. get_closeby_node feasibility checks),
    -- skip the 0.080 lower bound so 8 attempts can stay under ~250ms total.
    local time_lb  = time_cap_override and 0 or 0.080
    local time_limit = math.max(time_lb, math.min(time_cap, goal_dist * 0.024))

    -- Wall-ring penalty applies on every distance now.  fast_walkable
    -- consults explorer.scanned (warm cache + persisted overworld data)
    -- before falling back to the engine call, so the per-iter cost is
    -- bounded even on long paths -- we're just doing table lookups for
    -- known cells.  Persistence makes this practical: by the second
    -- session in any overworld zone, nearly every cell hits the warm
    -- cache.  The previous 25u shortcut left long paths edge-hugging
    -- because no penalty was applied.
    local skip_wall_ring = false

    -- Pre-compute directions once per find_path call
    local dist = settings.step
    local directions = {
        {-dist, 0},
        {0,  dist},
        { dist, 0},
        {0, -dist},
        {-dist,  dist},
        {-dist, -dist},
        { dist,  dist},
        { dist, -dist},
    }

    local start_h = heuristic(start_node, goal_node)
    heap:push(start_h, start_str, start_node)
    in_open[start_str] = 0

    -- Common return point: passes meta to bench_stop so it's recorded ONLY when
    -- this call sets a new max (was: bench_set_meta unconditionally, which
    -- overwrote the peak meta with the last call's meta — the report's peak{}
    -- annotation was therefore unrelated to the max-time call).
    local function pf_return(path, is_partial, status)
        local meta = string.format(
            "iters=%d dist=%.0f custom=%s status=%s plen=%d",
            counter, goal_dist, tostring(is_custom_target), status, #path)
        tracker.bench_count("pf_" .. pf_bucket(counter))
        tracker.bench_count("pf_status_" .. status)
        tracker.bench_stop("find_path", meta)
        return path, is_partial
    end

    while not heap:empty() do
        if counter > iter_limit or (os.clock() - path_start_time) > time_limit then
            utils.log(1, 'no path (over limit) ' .. utils.vec_to_string(start) .. '>' .. utils.vec_to_string(goal))
            -- Return partial path to the closest node we reached
            if best_node_str ~= start_str then
                local partial = pull_bench(reconstruct_path(closed_set, prev_nodes, best_node), dist)
                utils.log(1, 'returning partial path #' .. #partial .. ' best_h=' .. string.format('%.1f', best_node_h))
                return pf_return(partial, true, "limit_partial")
            end
            return pf_return({}, true, "limit_empty")
        end

        local _, cur_str, cur_node = heap:pop()

        -- Lazy deletion: skip if already closed (stale heap entry)
        if closed_set[cur_str] then goto continue end

        counter = counter + 1

        if utils.distance(cur_node, goal_node) == 0 then
            utils.log(2, 'path found')
            local pulled = pull_bench(reconstruct_path(closed_set, prev_nodes, cur_node), dist)
            return pf_return(pulled, false, "found")
        end

        closed_set[cur_str] = cur_node

        -- Track closest-to-goal node for partial path
        local cur_h = heuristic(cur_node, goal_node)
        if cur_h < best_node_h then
            best_node     = cur_node
            best_node_h   = cur_h
            best_node_str = cur_str
        end

        -- Wall buffer is applied via cost penalty (see get_valid_neighbor) rather
        -- than hard rejection.  Skip when:
        -- - goal is >25u away (skip_wall_ring; far paths can't afford ring evals
        --   on cold cells without hitting the time cap)
        -- - within ~1u of start (lets a player wedged near a wall escape)
        local ignore_walls = skip_wall_ring or utils.distance(start_node, cur_node) < 1
        local neighbours, penalties
        neighbours, evaluated, penalties = get_neighbors(cur_node, goal_node, evaluated, ignore_walls, directions)

        for idx, neighbor in ipairs(neighbours) do
            local neigh_str = utils.vec_to_string(neighbor)
            if not closed_set[neigh_str] then
                local t_g = g_score[cur_str] + utils.distance(cur_node, neighbor) + (penalties[idx] or 0)
                if g_score[neigh_str] == nil or t_g < g_score[neigh_str] then
                    prev_nodes[neigh_str] = cur_str
                    g_score[neigh_str]    = t_g
                    local f = t_g + heuristic(neighbor, goal_node)
                    heap:push(f, neigh_str, neighbor)
                    in_open[neigh_str] = t_g
                end
            end
        end

        ::continue::
    end

    utils.log(1, 'no path (no openset) ' .. utils.vec_to_string(start) .. '>' .. utils.vec_to_string(goal))
    -- Return partial path to the closest node we reached
    if best_node_str ~= start_str then
        local partial = pull_bench(reconstruct_path(closed_set, prev_nodes, best_node), dist)
        utils.log(1, 'returning partial path #' .. #partial .. ' best_h=' .. string.format('%.1f', best_node_h))
        return pf_return(partial, true, "noopen_partial")
    end
    return pf_return({}, true, "noopen_empty")
end

-- Debug variant: no distance-scaled limits — runs until path found, open-set exhausted,
-- or safety caps hit. Returns (path_or_nil, iterations, elapsed_seconds, status_string).
-- status: "found" | "no_path" | "iter_limit" | "time_limit"
--
-- Optional opts: { iter_cap = N, time_cap = seconds } to tighten the safety
-- ceiling for runtime callers (long_path.navigate_to in production, etc.).
-- Without opts the original 100k / 15s ceiling applies (debug button use).
pathfinder.find_path_debug = function(start, goal, opts)
    local start_node = utils.normalize_node(start)
    local goal_node  = utils.normalize_node(goal)
    local start_str  = utils.vec_to_string(start_node)
    local heap       = new_heap()
    local closed_set = {}
    local g_score    = {[start_str] = 0}
    local prev_nodes = {}
    local counter    = 0
    local evaluated  = {}
    local t0         = os.clock()

    -- Track closest-to-goal node for partial path on failure
    local best_node     = start_node
    local best_node_h   = heuristic(start_node, goal_node)
    local best_node_str = start_str

    -- Safety ceiling — prevents total game freeze; still far above normal 5000/0.3s limits.
    -- Caller can tighten via opts to bound runtime (debug button leaves them at the max).
    local HARD_ITER_LIMIT = (opts and opts.iter_cap) or 100000
    local HARD_TIME_LIMIT = (opts and opts.time_cap) or 15.0

    local dist = settings.step
    local directions = {
        {-dist, 0}, {0, dist}, {dist, 0}, {0, -dist},
        {-dist, dist}, {-dist, -dist}, {dist, dist}, {dist, -dist},
    }

    local start_h = heuristic(start_node, goal_node)
    heap:push(start_h, start_str, start_node)

    while not heap:empty() do
        if counter >= HARD_ITER_LIMIT then
            if best_node_str ~= start_str then
                return string_pull(reconstruct_path(closed_set, prev_nodes, best_node), dist), counter, os.clock() - t0, "iter_limit_partial"
            end
            return nil, counter, os.clock() - t0, "iter_limit"
        end
        if (os.clock() - t0) >= HARD_TIME_LIMIT then
            if best_node_str ~= start_str then
                return string_pull(reconstruct_path(closed_set, prev_nodes, best_node), dist), counter, os.clock() - t0, "time_limit_partial"
            end
            return nil, counter, os.clock() - t0, "time_limit"
        end

        local _, cur_str, cur_node = heap:pop()

        -- Lazy deletion: skip if already closed (stale heap entry)
        if closed_set[cur_str] then goto continue end

        counter = counter + 1
        if utils.distance(cur_node, goal_node) == 0 then
            return string_pull(reconstruct_path(closed_set, prev_nodes, cur_node), dist), counter, os.clock() - t0, "found"
        end
        closed_set[cur_str] = cur_node

        -- Track closest-to-goal node for partial path
        local cur_h = heuristic(cur_node, goal_node)
        if cur_h < best_node_h then
            best_node     = cur_node
            best_node_h   = cur_h
            best_node_str = cur_str
        end

        local neighbours
        neighbours, evaluated = get_neighbors(cur_node, goal_node, evaluated, true, directions)
        for _, neighbor in ipairs(neighbours) do
            local neigh_str = utils.vec_to_string(neighbor)
            if not closed_set[neigh_str] then
                local t_g = g_score[cur_str] + utils.distance(cur_node, neighbor)
                if g_score[neigh_str] == nil or t_g < g_score[neigh_str] then
                    prev_nodes[neigh_str] = cur_str
                    g_score[neigh_str]    = t_g
                    local f = t_g + heuristic(neighbor, goal_node)
                    heap:push(f, neigh_str, neighbor)
                end
            end
        end

        ::continue::
    end

    if best_node_str ~= start_str then
        return string_pull(reconstruct_path(closed_set, prev_nodes, best_node), dist), counter, os.clock() - t0, "no_path_partial"
    end
    return nil, counter, os.clock() - t0, "no_path"
end

return pathfinder
