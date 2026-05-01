-- ---------------------------------------------------------------------------
-- core/walker.lua
--
-- Internal locomotion driver -- replaces our former dependency on the
-- Batmobile plugin's navigator.  Same surface area, smaller scope:
-- given a target position, plan a path and walk the player along it
-- node-by-node.  Stuck detection + a basic evade unstick.  No frontier
-- exploration (the goal-picker is core/explorer.lua) and no movement-
-- spell tricks (the rotation can layer those on independently).
--
-- API:
--   walker.set_target(goal)        goal can be vec3 OR { x, y, z } table
--   walker.clear_target()
--   walker.tick()                  called from core/move.to_pos -- plans
--                                   path if needed, then advances the
--                                   walk by one step
--   walker.stop()                  hard-stop: clear target + halt the
--                                   in-flight pathfinder request
--   walker.is_done()               true when no target OR target reached
--   walker.get_target()            current goal vec3 or nil
--
-- Behavior crib-noted from Batmobile/core/navigator.lua but trimmed of
-- the parts WarMachine doesn't need (movement spells, traversal-gizmo
-- interaction, frontier exploration, custom-target vs explored-target
-- distinction).  ~150 lines vs Batmobile's ~500.
-- ---------------------------------------------------------------------------

local M = {}

-- ---- Tunables ----
local PATH_REPLAN_S      = 2.0    -- repath if active path is older than this
local NODE_ARRIVE_R      = 1.0    -- consider a path node "reached" within R yards
local STUCK_DELTA_M      = 0.5    -- minimum movement to count as "moving"
local STUCK_WINDOW_S     = 2.0    -- if we haven't moved STUCK_DELTA in this long
local UNSTUCK_EVADE_ID   = 337031 -- universal evade spell SNO
local TICK_THROTTLE_S    = 0.05   -- ignore ticks closer together than this

-- ---- State (single shared walker; D4 is one-character so this is fine) ----
local state = {
    target          = nil,     -- vec3 goal, or nil
    path            = {},      -- vec3 array, planned path
    path_t          = 0,       -- when path was planned

    last_pos        = nil,     -- last sampled player position
    last_pos_t      = 0,       -- when last_pos was sampled
    last_move_t     = 0,       -- last time we observed actual movement

    last_tick_t     = 0,       -- throttle guard
}

local function as_vec3(g)
    if not g then return nil end
    if g.get_position then g = g:get_position() end
    if type(g) == 'table' and type(g.x) == 'number' then
        return vec3:new(g.x, g.y, g.z or 0)
    end
    -- already a vec3
    return g
end

local function dist2d(a, b)
    if not a or not b then return math.huge end
    local ax, ay = a:x(), a:y()
    local bx, by = b:x(), b:y()
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx*dx + dy*dy)
end

-- ---- Public ----

-- Optional `actor` is the live game object whose position drove this
-- target.  Walker keeps a weak reference so its stuck-detect can mark
-- the actor unreachable via core.target.mark_unreachable -- the SAME
-- mechanism kill_monster's pick() reads from, so a stuck pursuit
-- automatically blacklists the target across activities for 20s.
M.set_target = function (goal, actor)
    local v = as_vec3(goal)
    if not v then return end
    if state.target and dist2d(state.target, v) < 0.5 then
        -- Same target; keep cached path + actor.
        if actor and not state.target_actor then state.target_actor = actor end
        return
    end
    state.target       = v
    state.target_actor = actor
    state.path         = {}
    state.path_t       = 0
end

M.clear_target = function ()
    state.target       = nil
    state.target_actor = nil
    state.path         = {}
end

M.stop = function ()
    M.clear_target()
    -- Best-effort: tell the host pathfinder to drop any in-flight path.
    -- Batmobile's pause() set a navigator flag; we don't need that since
    -- tick is a no-op when target is nil.
    if pathfinder and pathfinder.clear_stored_path then
        pcall(pathfinder.clear_stored_path)
    end
end

M.is_done = function ()
    if not state.target then return true end
    local lp = get_local_player()
    if not lp then return false end
    local pp = lp:get_position()
    if not pp then return false end
    return dist2d(pp, state.target) <= NODE_ARRIVE_R
end

M.get_target = function ()
    return state.target
end

-- ---- Tick: called from move.to_pos's tier-3 fallback (and could be
-- called from anywhere else that wants to drive the walker) ----
M.tick = function ()
    local now = get_time_since_inject and get_time_since_inject() or 0
    if (now - state.last_tick_t) < TICK_THROTTLE_S then return end
    state.last_tick_t = now

    if not state.target then return end
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    -- Auto-clear the target the moment we've arrived.  Without this the
    -- walker keeps re-issuing pathfinder.request_move(state.target) every
    -- tick which (a) wastes path-finder time and (b) draws a giant
    -- "destination" line in the host's debug overlay even though we're
    -- already there.  Was the user-visible "orbwalker point is WAYYY
    -- too far away" symptom -- a stale target from a previous tick was
    -- still being requested as the walk destination.
    if dist2d(pp, state.target) <= NODE_ARRIVE_R then
        state.target = nil
        state.path   = {}
        if pathfinder and pathfinder.clear_stored_path then
            pcall(pathfinder.clear_stored_path)
        end
        return
    end

    -- (Re)plan the path if missing or stale.  pathfinder.calculate_and_get_path_points
    -- is the host equivalent of Batmobile's path_finder.find_path -- A*
    -- across the host's walkable grid.  Empty result = no route (we'll
    -- silently retry; caller can drop the target if this persists).
    if #state.path == 0 or (now - state.path_t) > PATH_REPLAN_S then
        if pathfinder and pathfinder.calculate_and_get_path_points then
            local ok, path = pcall(pathfinder.calculate_and_get_path_points, pp, state.target)
            if ok and type(path) == 'table' and #path > 0 then
                state.path   = path
                state.path_t = now
            end
        end
    end

    -- Trim path nodes we've already passed so node[1] is always the
    -- next waypoint we still need to reach.
    while #state.path > 0 and dist2d(pp, state.path[1]) <= NODE_ARRIVE_R do
        table.remove(state.path, 1)
    end

    -- Stuck detection: did the player actually move recently?  We track
    -- the last position we'd seen significant movement at; if the
    -- elapsed-since-last-movement exceeds STUCK_WINDOW_S, we're stuck.
    if state.last_pos == nil or dist2d(pp, state.last_pos) >= STUCK_DELTA_M then
        state.last_pos    = pp
        state.last_move_t = now
        state.stuck_strikes = 0   -- progress made; reset escalation counter
    end
    local stuck = (now - state.last_move_t) > STUCK_WINDOW_S

    if stuck then
        state.stuck_strikes = (state.stuck_strikes or 0) + 1
        -- Try a single evade toward the next node; resets the timer
        -- so we don't spam the spell.  This is the cheapest practical
        -- unstick that doesn't depend on per-class movement spells.
        local goto_node = state.path[1] or state.target
        if cast_spell and cast_spell.position
           and utility and utility.can_cast_spell
           and utility.can_cast_spell(UNSTUCK_EVADE_ID)
           and goto_node
        then
            pcall(cast_spell.position, UNSTUCK_EVADE_ID, goto_node, 0)
        end
        -- After 2 strikes (= ~4-6s of zero progress), give up on this
        -- target and blacklist it so the caller (kill_monster /
        -- seek_progression) picks something else next pulse.  The
        -- target_actor reference (set via M.set_target's optional
        -- arg) lets us blacklist via core.target.mark_unreachable
        -- which kill_monster's pick() reads -- so the same target
        -- won't be re-picked for UNREACHABLE_TTL_S.
        if state.stuck_strikes >= 2 then
            local ok, target_mod = pcall(require, 'core.target')
            if ok and target_mod and state.target_actor then
                pcall(target_mod.mark_unreachable, state.target_actor)
            end
            -- Drop the target -- caller will repick on its next pulse.
            state.target       = nil
            state.target_actor = nil
            state.path         = {}
            state.stuck_strikes = 0
            if pathfinder and pathfinder.clear_stored_path then
                pcall(pathfinder.clear_stored_path)
            end
            return
        end
        -- Force a path replan on next tick so we don't loop on a stale
        -- path that walks back into the obstacle.
        state.path_t      = 0
        state.last_move_t = now
        return
    end

    -- Walk toward the next node.  pathfinder.request_move is the host
    -- "walk-toward-this-point" command -- non-blocking, called every
    -- tick until we arrive.
    local next_node = state.path[1]
    if next_node and pathfinder and pathfinder.request_move then
        pcall(pathfinder.request_move, next_node)
    elseif state.target and pathfinder and pathfinder.request_move then
        -- Path planning failed but we still have a target -- best-
        -- effort direct walk.  Most of the time this fails on
        -- non-line-of-sight terrain; the path replanner above will
        -- pick up a real route on the next tick.
        pcall(pathfinder.request_move, state.target)
    end
end

return M
