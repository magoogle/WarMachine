-- ---------------------------------------------------------------------------
-- core/freeroam.lua
--
-- Shared "fall back to Batmobile freeroam" task factory.  Every activity
-- runner registers ONE of these as the second-to-last task (just before
-- idle).  When no higher-priority task fires (no POI in priority queue,
-- no enemy in kill_range, no portal/door/chest visible, etc.) the
-- freeroam task takes the pulse and tells Batmobile to wander.
--
-- This is the catch-all that keeps the bot moving until either:
--   * StaticPather catalogues enough POIs to drive priority-based
--     navigation, OR
--   * the player walks/Batmobile-wanders into actor stream range of
--     a POI that the higher-priority task picks up first.
--
-- Why this exists: in the v0.2 architecture each activity uses
-- poi_priority.lua + interact_poi to drive movement.  When the merged
-- WarMap data has no POIs catalogued for a zone, interact_poi has
-- nothing to point at, so the runner falls through to idle.  Without
-- a fallback the bot just stands there waiting for data that needs
-- the bot to explore to be collected -- a chicken-and-egg deadlock.
-- Batmobile's freeroam mode walks the unwalked, and the recorder
-- captures POIs as they come into actor stream, which gets uploaded,
-- which feeds the next merge cycle.  The deadlock breaks itself.
--
-- Usage from an activity runner.lua:
--
--   local make_freeroam = require 'core.freeroam'
--   local TASK_FILES = {
--       'exit', 'interact_pylon', ..., 'kill_monster',
--       -- (no 'freeroam' string here -- it's a generated task)
--       'idle',
--   }
--   ...
--   table.insert(tasks, #tasks, make_freeroam('warmachine_helltide'))
--
-- The `caller` string is what Batmobile's external API logs as the
-- caller; conventional name is 'warmachine_<tag>'.
-- ---------------------------------------------------------------------------

return function (caller)
    local task = {
        name           = 'freeroam_fallback',
        status         = 'idle',
        last_enable_t  = 0,
    }
    local ENABLE_HEARTBEAT_S = 5  -- re-poke Batmobile.enable() every N seconds

    task.shouldExecute = function ()
        -- Always fire as last-resort fallback.  Higher-priority tasks
        -- registered above this one in the runner take precedence.
        if not BatmobilePlugin or not BatmobilePlugin.enable then
            return false   -- Batmobile not loaded; can't fall back here
        end
        return true
    end

    task.Execute = function ()
        local now = get_time_since_inject and get_time_since_inject() or 0
        -- Heartbeat: Batmobile's external.enable() flips a freeroam toggle
        -- and unpauses the navigator.  Calling it every pulse is wasteful
        -- and noisy in Batmobile's debug log; once every ENABLE_HEARTBEAT_S
        -- is enough to keep it engaged even if some other task disabled
        -- it briefly.
        if (now - task.last_enable_t) > ENABLE_HEARTBEAT_S then
            local ok, err = pcall(BatmobilePlugin.enable, caller)
            if not ok and console and console.print then
                console.print('[freeroam] Batmobile.enable failed: ' .. tostring(err))
            end
            task.last_enable_t = now
        end
        -- Re-enable orbwalker auto-attack while wandering.  Other tasks
        -- (interact_poi, open_chest, portal-click) call
        -- set_clear_toggle(false) right before they click an actor so the
        -- click doesn't get hijacked into an attack.  After they finish,
        -- nothing flips it back on -- so a "freeroam takes the pulse"
        -- transition leaves the bot walking past mobs without attacking
        -- (user-reported: 'helltides walking around now, but its not
        -- killing anything').  Set it true here every pulse so combat
        -- resumes the moment we're not actively clicking something.
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(true)
        end
        task.status = 'batmobile freeroam (' .. caller .. ')'
    end

    return task
end
