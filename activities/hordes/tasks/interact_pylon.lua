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
local task = { name = 'interact_pylon', status = 'idle', last_click_t = nil }
local CLICK_DEBOUNCE_S = 3

-- Build a pylon name -> priority index map once.
local PYLON_RANK = {}
for i, name in ipairs(pylon_priority) do PYLON_RANK[name] = i end

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
                    out[#out + 1] = { actor = a, name = name, rank = PYLON_RANK[name] }
                    break
                end
            end
        end
    end
    return out
end

local function pick_best(pylons)
    if #pylons == 0 then return nil end
    -- Lower rank = higher priority
    table.sort(pylons, function (a, b) return a.rank < b.rank end)
    return pylons[1]
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
    local best = pick_best(pylons)
    if not best then task.status = 'no pylons'; return end

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
