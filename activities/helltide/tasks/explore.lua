-- ---------------------------------------------------------------------------
-- activities/helltide/tasks/explore.lua
--
-- Wanders the helltide zone when interact_poi has nothing in its queue.
-- As the bot moves, poi_priority's always-on live scan picks up any
-- chest/pyre/shrine that comes into actor-stream range, at which point
-- interact_poi (higher priority) takes over automatically.
--
-- BOUNDARY GUARD: only runs while the helltide buff is active.  When the
-- buff drops we yield so return_to_zone (higher priority) can route us
-- back into the ring via the WarPath catalog.
--
-- Movement is delegated to nav via move.explore -- nav owns
-- the frontier-scoring + traversal-gizmo logic for every zone type.
-- ---------------------------------------------------------------------------

local move = require 'core.move'

local task = { name = 'explore', status = 'idle' }

local HELLTIDE_BUFF_HASH = 1066539

local function is_in_helltide()
    local lp = get_local_player()
    if not lp or not lp.get_buffs then return false end
    for _, b in ipairs(lp:get_buffs() or {}) do
        local hash = b.name_hash or (b.get_name_hash and b:get_name_hash())
        if hash == HELLTIDE_BUFF_HASH then return true end
    end
    return false
end

task.shouldExecute = function ()
    -- Only explore when we're inside the ring.  interact_poi and
    -- kill_monster are higher priority in runner.lua; we only fire when
    -- their shouldExecute returns false.
    return is_in_helltide()
end

task.Execute = function ()
    move.explore({ priority = 'helltide' })
    task.status = 'exploring'
end

return task
