-- ---------------------------------------------------------------------------
-- activities/boss/tasks/dungeon_reset.lua
--
-- After every N completed runs (configurable), calls reset_all_dungeons()
-- so accumulated zone state (stale actors, lingering effects) doesn't pile
-- up across long farming sessions.
--
-- Trigger window: between runs only.  shouldExecute is gated on
--   * the feature being enabled
--   * runs-since-last-reset >= interval
--   * the player NOT being inside a boss zone (so we don't yank the player
--     mid-fight or mid-loot)
--
-- We don't share Reaper's session-wide total_kills counter; instead we
-- edge-detect tracker.run_done (false -> true) and increment a local
-- counter.  When the counter hits the interval, fire the reset, zero the
-- counter, and idle out so the next pulse hands control back to
-- select_boss / WarPlan dispatch.
-- ---------------------------------------------------------------------------

local settings  = require 'activities.boss.settings'
local tracker   = require 'activities.boss.tracker'
local boss_data = require 'activities.boss.data.boss_data'

local STATE = {
    IDLE      = 'IDLE',
    RESETTING = 'RESETTING',
    WAITING   = 'WAITING',
}

local state         = STATE.IDLE
local state_start_t = 0
local runs_since_reset = 0
local _prev_run_done   = false

local function now() return get_time_since_inject and get_time_since_inject() or 0 end

local function in_boss_zone()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    return boss_data.zone_matches(w:get_current_zone_name())
end

-- Edge-detect tracker.run_done (false -> true).  Runs-completed counter is
-- incremented here so it's accurate regardless of how many ticks the run
-- spends in the run_done=true state.
local function poll_run_done()
    local cur = tracker.run_done == true
    if cur and not _prev_run_done then
        runs_since_reset = runs_since_reset + 1
    end
    _prev_run_done = cur
end

local task = {
    name   = 'dungeon_reset',
    status = 'idle',
}

task.shouldExecute = function ()
    poll_run_done()

    if not settings.dungeon_reset_enabled then return false end
    if (settings.dungeon_reset_interval or 0) <= 0 then return false end

    -- Mid-sequence: keep running until we cycle back to IDLE.
    if state ~= STATE.IDLE then return true end

    -- Not safe to fire while inside the boss zone -- the run is still in
    -- progress.  We trigger after the run hands control back to between-
    -- runs state (player teleported home / to next zone).
    if in_boss_zone() then return false end

    return runs_since_reset >= (settings.dungeon_reset_interval or 0)
end

task.Execute = function ()
    local t = now()

    if state == STATE.IDLE then
        console.print(string.format(
            '[Boss] dungeon_reset: %d run(s) since last reset -- calling reset_all_dungeons.',
            runs_since_reset))
        if reset_all_dungeons then
            local ok, err = pcall(reset_all_dungeons)
            if not ok then
                console.print('[Boss] reset_all_dungeons error: ' .. tostring(err))
            end
        end
        runs_since_reset = 0
        state            = STATE.RESETTING
        state_start_t    = t
        task.status      = 'resetting'
        return
    end

    if state == STATE.RESETTING then
        -- Brief pause so the host has time to land the reset before we
        -- yield back to select_boss / WarPlan dispatch.
        if (t - state_start_t) >= 2.0 then
            state         = STATE.WAITING
            state_start_t = t
            task.status   = 'settling'
        end
        return
    end

    if state == STATE.WAITING then
        if (t - state_start_t) >= 1.0 then
            state       = STATE.IDLE
            task.status = 'idle'
        end
        return
    end
end

return task
