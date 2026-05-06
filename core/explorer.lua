-- ---------------------------------------------------------------------------
-- core/explorer.lua
--
-- Thin shim that delegates exploration to nav's free-roam mode.
-- nav owns the visited-cell grid + frontier scorer + traversal-
-- gizmo handling internally; this file just calls move.explore() each
-- pulse so activity tasks can stay agnostic about which pathfinder
-- is driving.
--
-- Public API (unchanged surface so freeroam.lua + per-activity runners
-- need no updates):
--   explorer.tick()               -- drive one nav exploration tick
--   explorer.reset()              -- clear nav's exploration state
--   explorer.make_task(caller)    -- runner-compatible task object
-- ---------------------------------------------------------------------------

local move = require 'core.move'

local M = {}

local function nav()
    return rawget(_G, 'WarMachineNav')
end

M.tick = function ()
    move.explore()
    return nil, nil   -- legacy signature: (tx, ty); nav owns the target
end

M.reset = function ()
    local n = nav()
    if n and n.reset then pcall(n.reset, 'warmachine') end
end

M.make_task = function (caller)
    local task = {
        name   = 'explorer',
        status = 'idle',
    }
    task.shouldExecute = function ()
        return get_local_player() ~= nil and nav() ~= nil
    end
    task.Execute = function ()
        move.explore()
        task.status = 'exploring ' .. tostring(caller)
    end
    return task
end

return M
