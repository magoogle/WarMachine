-- ---------------------------------------------------------------------------
-- core/walker.lua  --  STUB
--
-- Navigation delegated to WarPath.  The three-tier locomotion driver that
-- lived here (traversal-gizmo handling, trap escape, evade-based unstick)
-- is replaced by WarPath's host_pather + BatmobilePlugin integration:
--
--   * host_pather.path_to() falls back to BatmobilePlugin.find_long_path
--     when world:calculate_path() returns an empty path.
--   * sequencer.tick() calls BatmobilePlugin.try_traversal_route when
--     stuck after STUCK_RECOVERY_MAX_TRIES, handling climb/door gizmos.
--
-- This stub exists so the many pcall(require, 'core.walker') + walker.stop()
-- call sites in activity apis keep working without modification.  stop()
-- clears the host pathfinder's stored path (same effect as the old walker's
-- hard-stop).
-- ---------------------------------------------------------------------------

local M = {}

M.stop = function ()
    if pathfinder and pathfinder.clear_stored_path then
        pcall(pathfinder.clear_stored_path)
    end
end

M.set_target   = function () end
M.clear_target = function () end
M.tick         = function () end
M.is_done      = function () return true end
M.get_target   = function () return nil end
M.get_status   = function ()
    return { target = false, path_len = 0, stuck = 0, trapped = false,
             trav_active = nil, trav_bl_count = 0 }
end

return M
