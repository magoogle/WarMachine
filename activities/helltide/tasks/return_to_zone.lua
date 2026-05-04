-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/return_to_zone.lua
--
-- Walk the player into the helltide ring.  All navigation is delegated to
-- WarPath: we query its static catalog for the nearest helltide-related
-- POI in the current zone and feed the position into move.to_pos.  WarPath
-- owns pathfinding (with BatmobilePlugin.find_long_path fallback inside)
-- and the catalog supplies the destination -- WarMachine just makes the
-- two calls and hands the result over.
-- ---------------------------------------------------------------------------

local move = require 'core.move'

local task = { name = 'return_to_zone', status = 'idle' }

-- Helltide POI kinds that mean "this point is in (or anchored to) the
-- helltide ring."  WarPath's catalog tags actors with these kinds; we
-- pick the closest match as the navigation target.
local HELLTIDE_POI_KINDS = {
    chest_helltide_random   = true,
    chest_helltide_targeted = true,
    chest_helltide_silent   = true,
    pyre                    = true,
    portal_helltide         = true,
    objective               = true,
}

local function is_in_helltide()
    local lp = get_local_player()
    if not lp or not lp.get_buffs then return false end
    for _, b in ipairs(lp:get_buffs() or {}) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash())
        if hash == 1066539 then return true end
    end
    return false
end

local function helltide_active_hour()
    local minute = tonumber(os.date('%M')) or 0
    return minute < 55
end

local function warpath()
    return rawget(_G, 'WarPathPlugin') or rawget(_G, 'StaticPatherPlugin') or nil
end

-- Ask WarPath for the closest helltide POI in the current zone.
local function closest_helltide_poi()
    local p = warpath()
    if not p or not p.get_actors then return nil end
    local ok, actors = pcall(p.get_actors)
    if not ok or not actors then return nil end
    local lp = get_local_player()
    if not lp then return nil end
    local pp = lp:get_position()
    if not pp then return nil end
    local px, py = pp:x(), pp:y()
    local best, best_d2 = nil, math.huge
    for _, a in ipairs(actors) do
        if HELLTIDE_POI_KINDS[a.kind or ''] then
            local dx = (a.x or 0) - px
            local dy = (a.y or 0) - py
            local d2 = dx*dx + dy*dy
            if d2 < best_d2 then best, best_d2 = a, d2 end
        end
    end
    return best
end

task.shouldExecute = function ()
    if is_in_helltide() then return false end
    if not helltide_active_hour() then return false end
    return closest_helltide_poi() ~= nil
end

task.Execute = function ()
    local poi = closest_helltide_poi()
    if not poi then
        task.status = 'no helltide POI in WarPath catalog'
        return
    end
    local lp = get_local_player()
    local pp = lp and lp:get_position() or nil
    local goal = { x = poi.x, y = poi.y, z = poi.z or (pp and pp:z()) or 0 }
    move.to_pos(goal, { arrive_radius = 5 })
    if pp then
        local dx = poi.x - pp:x()
        local dy = poi.y - pp:y()
        local d  = math.sqrt(dx*dx + dy*dy)
        task.status = string.format('walking to %s (%.0fm)', poi.kind or '?', d)
    else
        task.status = 'walking to helltide POI'
    end
end

return task
