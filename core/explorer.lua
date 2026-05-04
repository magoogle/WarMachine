-- ---------------------------------------------------------------------------
-- core/explorer.lua
--
-- Thin shim that delegates exploration to Batmobile's free-roam mode.
-- Batmobile owns the visited-cell grid + frontier scorer + traversal-
-- gizmo handling internally; this file just calls move.explore() each
-- pulse so activity tasks can stay agnostic about which pathfinder
-- is driving.
--
-- Public API (unchanged surface so freeroam.lua + per-activity runners
-- need no updates):
--   explorer.tick()               -- drive one Batmobile exploration tick
--   explorer.reset()              -- clear Batmobile's exploration state
--   explorer.make_task(caller)    -- runner-compatible task object
-- ---------------------------------------------------------------------------

local move = require 'core.move'

local M = {}

local function batmobile()
    return rawget(_G, 'BatmobilePlugin')
end

M.tick = function ()
    move.explore()
    return nil, nil   -- legacy signature: (tx, ty); Batmobile owns the target
end

M.reset = function ()
    local bm = batmobile()
    if bm and bm.reset then pcall(bm.reset, 'warmachine') end
end

M.make_task = function (caller)
    local task = {
        name   = 'explorer',
        status = 'idle',
    }
    task.shouldExecute = function ()
        return get_local_player() ~= nil and batmobile() ~= nil
    end
    task.Execute = function ()
        move.explore()
        task.status = 'exploring ' .. tostring(caller)
    end
    return task
end

return M
