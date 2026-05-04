-- ---------------------------------------------------------------------------
-- core/explorer.lua
--
-- Thin delegate: all exploration state lives in WarPath.
-- WarPath's explorer (core/explorer.lua) owns the visited-cell grid
-- and frontier scoring (wall_dist bias + distance-to-player).
--
-- This file's only job:
--   1. Call WarPathPlugin.exploration_tick each pulse to mark visited cells.
--   2. Call WarPathPlugin.exploration_frontier to get the next target.
--   3. Drive core/move.to_pos toward that target.
--   4. Detect when we're stuck on a frontier cell that can't be reached
--      and fake-visit it (call exploration_tick at the target coords) so
--      WarPath picks a different cell next time.
--
-- Public API (same surface as the old ring-scorer so core/freeroam.lua and
-- per-activity runners need no changes):
--   explorer.tick()         -> (tx, ty) | (nil, nil)
--   explorer.reset()        -> clears WarPath's visited state for this zone
--   explorer.make_task(caller) -> runner-compatible task object
-- ---------------------------------------------------------------------------

local zone = require 'core.zone'
local move = require 'core.move'

local M = {}

local ARRIVE_RADIUS_M = 0.8
local STUCK_WINDOW_S  = 3.0   -- re-pick after this many seconds without progress
local STUCK_DELTA_M   = 0.3   -- minimum movement to count as "not stuck"

local function plugin()
    return rawget(_G, 'WarPathPlugin')
        or rawget(_G, 'StaticPatherPlugin')
        or nil
end

-- Per-session state; reset on zone change.
local state = {
    last_zone = nil,
    target_x  = nil, target_y = nil,
    target_t  = 0,
    anchor_x  = nil, anchor_y = nil,
}

local function reset_state(cur_zone)
    state.last_zone = cur_zone
    state.target_x, state.target_y = nil, nil
    state.target_t  = 0
    state.anchor_x, state.anchor_y = nil, nil
end

-- ---------------------------------------------------------------------------
-- Public: tick the explorer.  Call once per pulse from a freeroam task.
-- Returns (tx, ty) of the active frontier target, or (nil, nil) when
-- WarPath has no target to offer (fully explored, or no data yet).
-- ---------------------------------------------------------------------------
M.tick = function ()
    local cur_zone = zone.current()
    if not cur_zone then return nil, nil end
    if state.last_zone ~= cur_zone then reset_state(cur_zone) end

    local lp = get_local_player()
    local pp = lp and lp:get_position() or nil
    if not pp then return nil, nil end

    local p = plugin()
    if not p then return nil, nil end

    -- Mark cells visited around the player each tick.
    if p.exploration_tick then pcall(p.exploration_tick, cur_zone, pp) end
    if not p.exploration_frontier then return nil, nil end

    local now  = get_time_since_inject() or 0
    local px, py = pp:x(), pp:y()

    -- Stuck detection: if we've been targeting the same frontier cell for
    -- STUCK_WINDOW_S without moving STUCK_DELTA_M, fake-visit the target
    -- position in WarPath's grid.  This marks it visited so WarPath's
    -- scorer picks a different cell on the next call.
    if state.target_x and state.anchor_x then
        local dx = px - state.anchor_x
        local dy = py - state.anchor_y
        if math.sqrt(dx*dx + dy*dy) >= STUCK_DELTA_M then
            -- Still making progress; refresh anchor.
            state.anchor_x, state.anchor_y = px, py
            state.target_t = now
        elseif (now - state.target_t) >= STUCK_WINDOW_S then
            -- Stuck on this target.  Fake-visit it so WarPath moves on.
            if p.exploration_tick then
                local fake = vec3:new(state.target_x, state.target_y, pp:z())
                pcall(p.exploration_tick, cur_zone, fake)
            end
            state.target_x, state.target_y = nil, nil
            state.anchor_x, state.anchor_y = px, py
            state.target_t = now
        end
    end

    local target = p.exploration_frontier(cur_zone, pp)
    if not target then return nil, nil end

    local tx, ty = target:x(), target:y()
    -- New target: reset the stuck anchor.
    if tx ~= state.target_x or ty ~= state.target_y then
        state.target_x, state.target_y = tx, ty
        state.target_t = now
        state.anchor_x, state.anchor_y = px, py
    end

    move.to_pos({ x = tx, y = ty, z = target:z() }, { arrive_radius = ARRIVE_RADIUS_M })
    return tx, ty
end

-- ---------------------------------------------------------------------------
-- Public: clear exploration state for the current zone.  Called when an
-- activity deactivates so the next run starts with a fresh visited set.
-- ---------------------------------------------------------------------------
M.reset = function ()
    local p  = plugin()
    local cz = zone.current()
    if p and p.exploration_clear and cz then
        pcall(p.exploration_clear, cz)
    end
    reset_state(cz)
end

-- ---------------------------------------------------------------------------
-- Public: factory that produces a runner-task object compatible with the
-- make_freeroam contract.  `caller` is a diagnostic label only.
-- ---------------------------------------------------------------------------
M.make_task = function (caller)
    local task = {
        name   = 'explorer',
        status = 'idle',
    }
    task.shouldExecute = function ()
        return get_local_player() ~= nil
    end
    task.Execute = function ()
        local tx, ty = M.tick()
        if tx and ty then
            task.status = string.format('exploring %s -> (%.0f,%.0f)', caller, tx, ty)
        else
            task.status = 'exploring ' .. caller
        end
    end
    return task
end

return M
