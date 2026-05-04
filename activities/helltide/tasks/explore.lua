-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/explore.lua
--
-- Wanders the helltide zone when interact_poi has nothing in its queue.
-- As the bot moves, poi_priority's always-on live scan picks up any
-- chest/pyre/shrine that comes into actor-stream range, at which point
-- interact_poi (higher priority) takes over automatically.
--
-- BOUNDARY GUARD: only runs while the helltide buff is active.  If the
-- bot drifts outside the ring, this task stops movement and marks the
-- boundary cells visited so the frontier picker won't route back to the
-- same out-of-ring spot.  return_to_zone (higher priority) handles
-- walking back into the ring.
--
-- Frontier sources, in preference order:
--   1. WarPath explorer.next_frontier (nav cell data exists)
--   2. Batmobile get_backtrack         (live DFS scanner)
--   3. Nothing -- task reports 'fully explored', bot falls to idle
-- ---------------------------------------------------------------------------

local move    = require 'core.move'
local tracker = require 'activities.helltide.tracker'

local task = { name = 'explore', status = 'idle' }

local HELLTIDE_BUFF_HASH = 1066539
local ARRIVE_FRONTIER_R  = 4.0
local BOUNDARY_MARK_R    = 10      -- cells to mark visited when leaving ring

local _frontier_target = nil
local _frontier_zone   = nil

local function is_in_helltide()
    local lp = get_local_player()
    if not lp or not lp.get_buffs then return false end
    for _, b in ipairs(lp:get_buffs() or {}) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash())
        if hash == HELLTIDE_BUFF_HASH then return true end
    end
    return false
end

local function get_zone()
    local w = get_current_world and get_current_world()
    return w and w.get_current_zone_name and w:get_current_zone_name() or nil
end

local function warpath()
    return rawget(_G, 'WarPathPlugin') or rawget(_G, 'StaticPatherPlugin') or nil
end

local function pick_frontier(zone, pp)
    local p = warpath()
    if p and p.exploration_frontier then
        local t = p.exploration_frontier(zone, pp)
        if t then return t end
    end
    if BatmobilePlugin then
        local ok, bt = pcall(BatmobilePlugin.get_backtrack, 'helltide')
        if ok and type(bt) == 'table' and #bt > 0 then return bt[#bt] end
    end
    return nil
end

-- ---------------------------------------------------------------------------
task.shouldExecute = function ()
    -- Only explore when we're inside the ring.
    -- interact_poi and kill_monster are higher priority in runner.lua;
    -- we only fire when their shouldExecute returns false.
    return is_in_helltide()
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local zone = get_zone()
    if not zone then return end

    -- BOUNDARY GUARD: stop and mark cells so we don't loop back here.
    if not is_in_helltide() then
        local p = warpath()
        if p and p.exploration_mark_visited then
            p.exploration_mark_visited(zone, pp, BOUNDARY_MARK_R)
        end
        _frontier_target = nil
        _frontier_zone   = nil
        move.clear()
        task.status = 'outside ring -- stopping'
        return
    end

    -- Tick visited-cell accounting for the explorer.
    local p = warpath()
    if p and p.exploration_tick then
        p.exploration_tick(zone, pp)
    end

    -- Invalidate cached frontier on zone change.
    if _frontier_zone ~= zone then
        _frontier_target = nil
        _frontier_zone   = nil
    end

    -- Refresh frontier when we've arrived (or none picked yet).
    if _frontier_target then
        local dx = _frontier_target:x() - pp:x()
        local dy = _frontier_target:y() - pp:y()
        if (dx * dx + dy * dy) <= ARRIVE_FRONTIER_R * ARRIVE_FRONTIER_R then
            _frontier_target = nil
        end
    end

    if not _frontier_target then
        _frontier_target = pick_frontier(zone, pp)
        _frontier_zone   = zone
    end

    if not _frontier_target then
        task.status = 'fully explored (no frontier)'
        return
    end

    local dx = _frontier_target:x() - pp:x()
    local dy = _frontier_target:y() - pp:y()
    local d  = math.sqrt(dx * dx + dy * dy)
    move.to_pos(_frontier_target, { arrive_radius = ARRIVE_FRONTIER_R })
    task.status = string.format('exploring %.0fm to frontier', d)
end

return task
