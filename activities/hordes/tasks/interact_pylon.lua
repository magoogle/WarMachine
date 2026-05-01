-- activities/hordes/tasks/interact_pylon.lua
--
-- Between-wave choice: 3 pylons spawn, player picks one.  We walk to the
-- highest-priority pylon (per pylon_priority list) and click it.  Falls
-- back to the closest available if no priority match within timeout.

local move           = require 'core.move'
local settings       = require 'activities.hordes.settings'
local tracker        = require 'activities.hordes.tracker'
local pylon_priority = require 'activities.hordes.data.pylon_priority'

-- last_click_t debounces interact_object so the pulse loop (every 50ms) doesn't
-- spam a click against the same pylon while D4 is opening the choice menu --
-- HordeDev's legacy bot saw the same issue and uses a 3s gap between attempts.
local task = {
    name = 'interact_pylon', status = 'idle',
    last_click_t = nil,
    -- Wall-clock the choice panel first appeared (= we first saw at
    -- least one offered pylon).  Used by the timeout fallback that
    -- picks ANY offered pylon when all three are blacklisted (so we
    -- don't hang at the wave gate).
    panel_seen_t = nil,
}
local CLICK_DEBOUNCE_S = 3

-- Resolve the priority list + blacklist from the data file.  Supports
-- both the new structured shape `{ priority = {...}, blacklist = {...} }`
-- and the legacy flat list `{ 'A', 'B', ... }` so an outdated user copy
-- of the data file keeps working.
local PRIORITY = nil
local BLACKLIST_SET = {}
if type(pylon_priority) == 'table' and pylon_priority.priority then
    PRIORITY = pylon_priority.priority
    for _, name in ipairs(pylon_priority.blacklist or {}) do
        BLACKLIST_SET[name] = true
    end
else
    PRIORITY = pylon_priority   -- legacy flat list
end

-- Build a pylon name -> priority index map once.
local PYLON_RANK = {}
for i, name in ipairs(PRIORITY or {}) do PYLON_RANK[name] = i end

local function find_pylons()
    -- A "pylon" actor has a skin containing one of the pylon names AND is
    -- currently interactable.  HordeDev matches the same way.
    if not actors_manager or not actors_manager.get_ally_actors then return {} end
    local out = {}
    for _, a in pairs(actors_manager:get_ally_actors()) do
        if a.is_interactable and a:is_interactable() then
            local sn = a:get_skin_name() or ''
            for name, _ in pairs(PYLON_RANK) do
                if sn:find(name, 1, true) then
                    out[#out + 1] = {
                        actor       = a,
                        name        = name,
                        rank        = PYLON_RANK[name],
                        blacklisted = BLACKLIST_SET[name] == true,
                    }
                    break
                end
            end
        end
    end
    return out
end

-- Pick the highest-priority NON-blacklisted pylon.  Fallback path:
-- if every offered pylon is blacklisted AND the panel has been up
-- for longer than `pylon_pick_timeout` seconds, pick the highest-
-- priority blacklisted one anyway -- waiting forever causes the
-- wave gate to time us out.  The timeout is computed in Execute.
local function pick_best(pylons, allow_blacklist)
    if #pylons == 0 then return nil end
    table.sort(pylons, function (a, b) return a.rank < b.rank end)
    for _, p in ipairs(pylons) do
        if allow_blacklist or not p.blacklisted then return p end
    end
    return nil
end

task.shouldExecute = function ()
    if not settings.do_pylons then return false end
    return #find_pylons() > 0
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local now = get_time_since_inject and get_time_since_inject() or 0

    -- Debounce: if we clicked recently, just wait for the choice menu to
    -- render and resolve.  The pylon will stop being interactable once the
    -- choice is made, which clears shouldExecute and falls back to combat.
    if task.last_click_t and (now - task.last_click_t) < CLICK_DEBOUNCE_S then
        task.status = 'waiting for choice menu'
        return
    end

    local pylons = find_pylons()
    if #pylons == 0 then
        -- No panel up.  Reset panel_seen so the next panel gets a fresh
        -- timeout window.
        task.panel_seen_t = nil
        task.status = 'no pylons'
        return
    end
    -- Choice panel is up.  Track first-seen time for the all-blacklisted
    -- timeout fallback below.
    task.panel_seen_t = task.panel_seen_t or now
    local elapsed     = now - task.panel_seen_t
    local timeout     = settings.pylon_pick_timeout or 8
    local fallback_ok = elapsed >= timeout

    local best = pick_best(pylons, false)
    if not best and fallback_ok then
        -- All three offered are blacklisted and we've waited the timeout.
        -- Take the highest-priority blacklisted one rather than miss the
        -- pick entirely (D4 auto-selects after its own timer otherwise).
        best = pick_best(pylons, true)
        if best and settings.debug_mode then
            console.print('[Hordes] all offered pylons blacklisted; ' ..
                          'falling back to highest-priority: ' .. best.name)
        end
    end
    if not best then
        task.status = string.format('all offered blacklisted (%.1fs to fallback)',
            math.max(0, timeout - elapsed))
        return
    end

    local pp = lp:get_position()
    local actor = best.actor
    local ap = actor:get_position()
    local d = math.sqrt((ap:x()-pp:x())^2 + (ap:y()-pp:y())^2)
    if d <= 3 then
        if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
        interact_object(actor)
        task.last_click_t = now
        tracker.last_pylon_pick = best.name
        if settings.debug_mode then console.print('[Hordes] picked pylon: ' .. best.name) end
        task.status = 'picked ' .. best.name
        return
    end
    move.to_actor(actor)
    task.status = string.format('walking to pylon %s (%.0fm)', best.name, d)
end

return task
