-- activities/nmd/tasks/runner.lua

local tracker        = require 'activities.nmd.tracker'
local make_freeroam  = require 'core.freeroam'

local R = {}

local TASK_FILES = {
    'select_dungeon',      -- standalone-only: consume a Nightmare Sigil
                           -- in town to open the next dungeon.  No-op in
                           -- WarPlan mode (WarPlan owns transit).
    'exit',                -- TP back to town once boss + chest done.
                           -- No-op in WarPlan (WarPlan owns transit).
                           -- Never calls reset_all_dungeons.
    'ambush',              -- LE_Ambush sub-event: speak to survivors,
                           -- then hold anchor during the survive phase
                           -- (kill_monster preempts for mob waves).
                           -- Always-on; ignoring the event would strand
                           -- the bot in the trigger zone.
    'cursed_shrine',       -- Click cursed-shrine sub-event when present
                           -- (and settings.do_cursed_shrines is on).
                           -- Pulse is then taken back over by kill_monster
                           -- for the spawned mob wave.
    'carry_objective',     -- "Carry the X to the pedestal" mechanic that
                           -- gates many NMD boss rooms.  Detects
                           -- Carryable_*/Receptacle_* in actor stream and
                           -- runs the pickup -> walk -> place loop.
                           -- Yields to immediate combat (kill_monster
                           -- runs when a mob is within 8y).
    'loot_chest',          -- live-stream Horadric / generic / cursed-event
                           -- chest grab.  Runs BEFORE interact_poi because
                           -- Horadric chests aren't yet in the StaticPather
                           -- catalog (see loot_chest.lua header).
    'interact_poi',        -- objectives, chests, shrines (catalog-driven)
    'kill_monster',        -- fallback combat
    'boss_room_hold',      -- once boss is seen, anchor inside the arena
                           -- so freeroam_fallback can't pull us through
                           -- the doorway and reset the encounter.
    'idle',
}

local tasks = {}
for _, name in ipairs(TASK_FILES) do
    local ok, t = pcall(require, 'activities.nmd.tasks.' .. name)
    if ok and t then tasks[#tasks + 1] = t
    else console.print('[NMD] task load failed: ' .. name .. ' err=' .. tostring(t)) end
end

-- Embedded explorer fallback (was Batmobile freeroam) so nightmare
-- dungeons keep moving when no POI is catalogued -- the most common
-- case for first-time-seen NMD variants.  The explorer picks goals
-- from a per-zone visit grid; the walker drives the locomotion.
local idle_idx = #tasks
table.insert(tasks, idle_idx, make_freeroam('warmachine_nmd'))

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
