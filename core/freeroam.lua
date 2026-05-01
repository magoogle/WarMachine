-- ---------------------------------------------------------------------------
-- core/freeroam.lua
--
-- Fallback "keep moving" task factory.  Every activity runner registers
-- ONE of these as the second-to-last task (just before idle).  When no
-- higher-priority task fires (no POI in priority queue, no enemy in
-- kill_range, no portal/door/chest visible, etc.) the freeroam task
-- takes the pulse and walks the bot toward unexplored space.
--
-- Backend swap (was: BatmobilePlugin.enable):
-- ----------------------------------------------------------------------
-- Until now this module called BatmobilePlugin.enable(caller) every
-- ENABLE_HEARTBEAT_S seconds and let Batmobile drive the wandering.
-- Batmobile is no longer maintained -- it spins in place and over-
-- backtracks on roomy zones, both of which the user reported.  We now
-- delegate to core/explorer.lua, which uses our own visit-history grid
-- to pick frontier targets and walks via core/move.lua's tiered
-- StaticPather -> Batmobile fallback (Batmobile is still used for
-- locomotion when StaticPather lacks a route, just not for goal-picking).
--
-- The factory signature is unchanged so per-activity runners don't have
-- to be updated; the `caller` string is forwarded into the task name
-- for diagnostic output ("exploring warmachine_nmd -> (12,-3)").
-- ---------------------------------------------------------------------------

local explorer = require 'core.explorer'

return function (caller)
    return explorer.make_task(caller)
end
