-- ---------------------------------------------------------------------------
-- core/freeroam.lua
--
-- Fallback "keep moving" task factory.  Every activity runner registers
-- ONE of these as the second-to-last task (just before idle).  When no
-- higher-priority task fires (no POI in priority queue, no enemy in
-- kill_range, no portal/door/chest visible, etc.) the freeroam task
-- takes the pulse and walks the bot toward unexplored space.
--
-- Delegates entirely to core/explorer.lua, which calls WarPath's
-- exploration_tick + exploration_frontier.  WarPath handles the
-- visited-cell grid, frontier scoring, and BatmobilePlugin.get_backtrack
-- fallback for zones without curated nav data.
--
-- The factory signature is unchanged so per-activity runners need no
-- updates; the `caller` string appears in the task's status display.
-- ---------------------------------------------------------------------------

local explorer = require 'core.explorer'

return function (caller)
    return explorer.make_task(caller)
end
