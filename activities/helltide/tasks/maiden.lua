-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/maiden.lua
--
-- Maiden of Anguish event.  Detection is "is the maiden brazier in our
-- actor stream + is helltide active".  When yes, latch tracker.in_maiden so
-- poi_priority.lua boosts pyres and the boss-room portal.  The actual
-- orchestration here is light: the event is mostly "kill mobs + place
-- hearts on pyres", both of which fall out of poi_priority -> interact_poi
-- naturally.  This task exists mainly to set the latch and to detect when
-- the maiden boss appears so we can stay engaged and not wander off to
-- chase a goblin.
-- ---------------------------------------------------------------------------

local tracker  = require 'activities.helltide.tracker'
local settings = require 'activities.helltide.settings'

local task = { name = 'maiden', status = 'idle' }

local BRAZIER_SKIN_PATTERNS = {
    'EGD_Helltide_Maiden_Brazier',
    'Helltide_Maiden_Pyre',
}
local MAIDEN_BOSS_PATTERN = 'Helltide_Maiden'

local function find_brazier()
    if not actors_manager or not actors_manager.get_ally_actors then return nil end
    for _, a in pairs(actors_manager:get_ally_actors()) do
        local sn = a:get_skin_name()
        if sn then
            for _, pat in ipairs(BRAZIER_SKIN_PATTERNS) do
                if sn:find(pat, 1, true) then return a end
            end
        end
    end
    return nil
end

local function maiden_boss_present()
    if not actors_manager then return false end
    local list = (actors_manager.get_enemies and actors_manager:get_enemies())
              or (actors_manager.get_all_actors and actors_manager:get_all_actors())
              or {}
    for _, a in pairs(list) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn and sn:find(MAIDEN_BOSS_PATTERN, 1, true) then return a end
    end
    return false
end

task.shouldExecute = function ()
    if not settings.do_maiden then
        if tracker.in_maiden then tracker.in_maiden = false end
        return false
    end
    -- Latch when brazier appears; clear when it disappears AND no boss.
    local brazier = find_brazier()
    if brazier then
        if not tracker.in_maiden then
            tracker.in_maiden = true
            local p = brazier:get_position()
            if p then tracker.maiden_brazier_pos = p end
            if settings.debug_mode then
                console.print('[Helltide] maiden brazier detected -- entering maiden mode')
            end
        end
    else
        if tracker.in_maiden and not maiden_boss_present() then
            tracker.in_maiden = false
            tracker.maiden_brazier_pos = nil
            if settings.debug_mode then
                console.print('[Helltide] maiden brazier gone + no boss -- exiting maiden mode')
            end
        end
    end

    -- This task itself only "claims" the pulse when the boss is up so other
    -- tasks (interact_poi) handle the routine pyre work.  When the boss is
    -- alive we want to stay engaged and not be stolen by a stray goblin POI.
    return tracker.in_maiden and maiden_boss_present() ~= false
end

task.Execute = function ()
    -- Kill_monster takes care of the boss.  This task just suppresses
    -- interact_poi from peeling off to a chest mid-fight.
    task.status = 'maiden boss engaged'
end

return task
