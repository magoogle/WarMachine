-- ---------------------------------------------------------------------------
-- activities/<name>/api.lua  --  Activity module contract.
--
-- COPY THIS FILE to activities/<name>/api.lua when porting a new activity.
-- The activity_manager auto-loads any folder under activities/ whose
-- name matches a tag in its KNOWN_ACTIVITIES list.
--
-- Per-folder layout (suggested but not enforced):
--   activities/pit/
--     api.lua          (this file -- entry point)
--     settings.lua     (per-activity GUI-bound settings)
--     tracker.lua      (per-run state)
--     tasks/           (priority-ordered task list -- one file per task)
--       enter.lua
--       kill_monster.lua
--       upgrade_glyph.lua
--       post_boss.lua
--       exit.lua
-- ---------------------------------------------------------------------------

local M = {}

-- Required: short, stable identifier.  Must match the folder name and
-- whatever tag the activity_manager registry expects.
M.tag   = 'template'
-- Required: human-readable label shown in the GUI status overlay.
M.label = 'Template'

-- Required: is the module fully wired up?  Return false to make the
-- activity_manager skip dispatch even if the user picks this mode.
M.is_loaded = function ()
    return false
end

-- Required: should this activity run RIGHT NOW?  Typical checks:
--   * Are we in the right zone?
--   * Do we have the prerequisite item (sigil, tribute, key, etc.)?
--   * Is some condition met (helltide active, NMD started, ...)?
M.shouldExecute = function ()
    return false
end

-- Required: one tick of work.  Call your task_manager / state machine /
-- whatever's appropriate from here.
M.pulse = function ()
    -- no-op
end

-- Required: status table for the on-screen overlay + cross-plugin reads.
-- Format: { task = '...', status = '...', [extra fields] }
M.get_status = function ()
    return {
        task   = 'idle',
        status = 'not loaded',
    }
end

-- Optional: called once when the activity_manager picks this activity
-- (transition from another or from "no activity").  Reset trackers,
-- clear caches, etc.
M.activate = function ()
    -- no-op
end

-- Optional: called when the activity_manager moves away from this
-- activity (or when WarMachine itself disables).  Stop walking, drop
-- targets, etc.
M.deactivate = function ()
    -- no-op
end

return M
