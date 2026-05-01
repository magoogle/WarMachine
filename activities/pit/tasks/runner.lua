-- ---------------------------------------------------------------------------
-- activities/pit/tasks/runner.lua  --  task list dispatcher.
-- ---------------------------------------------------------------------------

local tracker        = require 'activities.pit.tracker'
local make_freeroam  = require 'core.freeroam'

local R = {}

-- Pit is intentionally minimal: kill everything, descend, kill the boss,
-- upgrade glyphs, leave.  Per user direction "PIT has no point of
-- interest. Its simply go kill everything and progress until the boss
-- spawns and is killed > then upgrade glyphs > leave".
--
-- Order (highest priority first):
--   exit              -- terminal: chest looted / auto-reset triggered
--   upgrade_glyph     -- post-boss glyph UI sequence (final floor only)
--   floor_portal      -- descend via PortalSwitch / floor portal
--   kill_monster      -- the main loop: clear the floor
--   enter_pit         -- standalone: open the pit portal in town
--   idle
--
-- Removed (no longer relevant for pit):
--   interact_poi      -- pit has no side objectives / chests worth chasing
--   interact_shrine   -- shrine buffs aren't worth the detour at pit pace
-- The orphaned task files are left in place for git history but no
-- longer loaded.  poi_priority.lua / visited tracker fields kept as
-- well -- floor_portal still uses tracker.visited as a portal dedup
-- map.
local TASK_FILES = {
    'exit',
    'upgrade_glyph',
    'floor_portal',
    'kill_monster',
    -- seek_progression: catalog-driven walk to the closest unvisited
    -- floor-portal / exit-switch when no enemies are in range and
    -- nothing's in actor stream to click.  Replaces the explorer's
    -- random 1.5y wandering for mapped zones.
    'seek_progression',
    'enter_pit',
    'idle',
}

local tasks = {}
for _, name in ipairs(TASK_FILES) do
    local ok, t = pcall(require, 'activities.pit.tasks.' .. name)
    if ok and t then
        tasks[#tasks + 1] = t
    else
        console.print('[Pit] task load failed: ' .. name .. ' err=' .. tostring(t))
    end
end

-- Batmobile freeroam fallback: keeps the bot moving in pit floors until
-- POIs come into stream + StaticPather data drives priority routing.
local idle_idx = #tasks
table.insert(tasks, idle_idx, make_freeroam('warmachine_pit'))

local last_pulse_t = 0
local PULSE_INTERVAL_S = 0.05

R.pulse = function ()
    local now = get_time_since_inject and get_time_since_inject() or 0
    if (now - last_pulse_t) < PULSE_INTERVAL_S then return end
    last_pulse_t = now
    for _, task in ipairs(tasks) do
        if task.shouldExecute and task.shouldExecute() then
            tracker.current_task = task
            if task.Execute then task:Execute() end
            return
        end
    end
    tracker.current_task = { name = 'idle', status = 'idle' }
end

R.get_current_task = function () return tracker.current_task end

return R
