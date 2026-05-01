-- ---------------------------------------------------------------------------
-- activities/nmd/tasks/carry_objective.lua
--
-- "Carry the X to the pedestal" objective handler.
--
-- Many NMDs gate the boss room behind a carry-and-place mechanic:
--   * `Carryable_<thing>` actor spawns somewhere in the floor
--   * `Receptacle_<thing>` is the deposit point (an altar/pedestal)
--   * Pick up the carryable -> walk to the receptacle -> click it
--   * After N successful placements, the boss-room door opens
--
-- Live-validated S09 example (DGN_Naha_RuinedWild, "Return the
-- Ancients' Statue to the Pedestal"):
--   Carryable_AncientsStatue   <- pickup, 1.5y from player at trigger
--   Receptacle_AncientsStatue  <- pedestal, 15y away
--
-- The naming convention is consistent: extract the suffix from
-- `Carryable_<X>` and match to `Receptacle_<X>`.  We never need to
-- hardcode specific statues; ANY Carryable_*/Receptacle_* pair works.
--
-- Detection:
--   * "Carryable_" prefix on an interactable actor = pickup target
--   * "Receptacle_" prefix on an interactable actor = deposit target
-- Behavior:
--   * If a Carryable is in stream and we don't seem to be carrying:
--     walk to it, click, retry until non-interactable (= picked up).
--   * Otherwise if a Receptacle is in stream: walk to it, click,
--     retry until non-interactable or quest objective changes.
--
-- Heuristic for "we're carrying": after a successful Carryable
-- interaction (the carryable's actor goes non-interactable / drops
-- out of stream), prefer Receptacle over picking up a new Carryable.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local find     = require 'core.find'
local zone     = require 'core.zone'
local settings = require 'activities.nmd.settings'
local tracker  = require 'activities.nmd.tracker'

local task = {
    name           = 'carry_objective',
    status         = 'idle',
    -- Click retry state -- mirror loot_chest's pattern.
    target_key     = nil,
    last_click_t   = nil,
    click_count    = 0,
    first_click_t  = nil,
    -- Latches when we just consumed a Carryable, biasing the next
    -- find toward Receptacle for ~10s.
    carrying_until_t = 0,
}

local INTERACT_RADIUS  = 3.0
local SCAN_RADIUS_SQ   = 100 * 100   -- generous; carryables can be 50+ yards
local CLICK_COOLDOWN_S = 1.0
local CLICK_TIMEOUT_S  = 8.0
local CARRYING_BIAS_S  = 10.0        -- how long after a successful carry-pickup
                                      -- we prioritize Receptacle over Carryable

local CARRY_PATTERNS     = { 'carryable_' }
local RECEPTACLE_PATTERNS = { 'receptacle_' }

local function find_actor(patterns)
    return find.closest({
        patterns         = patterns,
        require_interactable = true,
        source           = 'all',  -- carryables + receptacles live in get_all_actors
        max_dist_sq      = SCAN_RADIUS_SQ,
        visited          = tracker.visited,
        visited_prefix   = 'carry',
    })
end

-- Decide which mode we're in for THIS pulse.  Returns (actor, mode)
-- where mode is 'pickup' or 'place', or (nil, nil) if nothing relevant.
local function pick_target()
    local now = get_time_since_inject() or 0
    local prefer_receptacle = now < task.carrying_until_t

    if prefer_receptacle then
        local r = find_actor(RECEPTACLE_PATTERNS)
        if r then return r, 'place' end
        -- Carrying-bias expired or no receptacle in range; fall
        -- through to look for a fresh carryable.
    end

    local c = find_actor(CARRY_PATTERNS)
    if c then return c, 'pickup' end

    -- No carryable -- try receptacle anyway in case our carrying-bias
    -- timer had already expired but we DO have one we forgot about.
    local r = find_actor(RECEPTACLE_PATTERNS)
    if r then return r, 'place' end

    return nil, nil
end

local function reset_click_state()
    task.target_key    = nil
    task.last_click_t  = nil
    task.click_count   = 0
    task.first_click_t = nil
end

task.shouldExecute = function ()
    if not zone.in_dungeon() then return false end
    -- Yield to immediate combat: if a mob is in melee range, kill_monster
    -- handles it; we'd just walk past and get hit.  At ranged distances
    -- the bot can carry-and-walk while orbwalker auto-attacks along the way.
    if find.any_enemy_in_range(8) then return false end
    return pick_target() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local actor, mode = pick_target()
    if not actor then
        reset_click_state()
        task.status = 'no carry/place target'
        return
    end

    local p = actor:get_position()
    if not p then return end
    local dx, dy = p:x() - pp:x(), p:y() - pp:y()
    local d = math.sqrt(dx*dx + dy*dy)
    local sn = actor:get_skin_name() or '?'
    local now = get_time_since_inject() or 0
    local key = find.key_for(mode, actor, p)

    -- Reset retry state on target change.
    if task.target_key ~= key then
        task.target_key = key
        task.last_click_t  = nil
        task.click_count   = 0
        task.first_click_t = nil
    end

    if d > INTERACT_RADIUS then
        move.to_actor(actor)
        task.status = string.format('walking to %s %s (%.0fm)', mode, sn, d)
        return
    end

    -- Success detection: actor flipped non-interactable.
    if not (actor.is_interactable and actor:is_interactable()) then
        tracker.visited = tracker.visited or {}
        tracker.visited[key] = true
        if mode == 'pickup' then
            -- We just picked up a carryable -- bias next pick toward
            -- a Receptacle for the next CARRYING_BIAS_S seconds.
            task.carrying_until_t = now + CARRYING_BIAS_S
            task.status = 'picked up ' .. sn
        else
            -- Placed at the receptacle -- clear the carrying bias.
            task.carrying_until_t = 0
            task.status = 'placed at ' .. sn
        end
        if settings.debug_mode then
            console.print(string.format(
                '[NMD] %s done: %s (%d clicks)', mode, sn, task.click_count or 0))
        end
        reset_click_state()
        return
    end

    -- Timeout.
    if task.first_click_t and (now - task.first_click_t) >= CLICK_TIMEOUT_S then
        tracker.visited = tracker.visited or {}
        tracker.visited[key] = true
        task.status = string.format('timeout %s %s', mode, sn)
        reset_click_state()
        return
    end

    -- Retry click on cooldown.
    if not task.last_click_t or (now - task.last_click_t) >= CLICK_COOLDOWN_S then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(actor)
        task.last_click_t  = now
        task.click_count   = (task.click_count or 0) + 1
        task.first_click_t = task.first_click_t or now
    end
    task.status = string.format('%s %s (#%d)', mode, sn, task.click_count or 0)
end

return task
