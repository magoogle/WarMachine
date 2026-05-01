-- ---------------------------------------------------------------------------
-- activities/boss/tasks/select_boss.lua
--
-- Standalone-mode boss rotation.  Picks a target boss based on the user's
-- selection_mode + enable flags + (Specific) primary_boss / (Split)
-- secondary_boss settings, then teleports there via the host's native
-- teleport_to_boss_dungeon(sno_id) call.
--
-- Fires when:
--   * we're in standalone Boss mode (mode == BOSS, not WARPLAN), AND
--   * we're not currently in the target boss's zone, AND
--   * the previous teleport (if any) was at least TELEPORT_COOLDOWN_S ago
--
-- WarPlan mode skips this entirely -- WarPlan's task_manager owns transit
-- via Next-Obj, and trying to teleport_to_boss_dungeon in parallel would
-- fight WarPlan's map clicks.
-- ---------------------------------------------------------------------------

local settings  = require 'activities.boss.settings'
local tracker   = require 'activities.boss.tracker'
local boss_data = require 'activities.boss.data.boss_data'

local core_mode = require 'core.mode'

local task = { name = 'select_boss', status = 'idle' }
local TELEPORT_COOLDOWN_S = 12   -- prevents spam if zone-load lags

-- Picks the next boss id given the user's selection_mode + enable flags.
-- Returns boss_id or nil if no enabled bosses.
local function pick_next_boss_id()
    local mode = settings.selection_mode or 1
    local enabled = settings.enabled_boss_ids()
    if #enabled == 0 then return nil end

    if mode == 1 then
        -- Specific: always run primary_boss (regardless of enable flags --
        -- the user's explicit pick).  Validate it's a real boss id; fall
        -- back to first enabled if not.
        if boss_data.bosses_by_id[settings.primary_boss] then
            return settings.primary_boss
        end
        return enabled[1]
    end

    if mode == 2 then
        -- Random: uniform draw from enabled set
        return enabled[math.random(1, #enabled)]
    end

    if mode == 3 then
        -- Split 50-50: alternate primary/secondary based on last_run_boss_id.
        -- If neither is enabled (or one is missing), fall back to enabled[1].
        local p, s = settings.primary_boss, settings.secondary_boss
        local p_ok = boss_data.bosses_by_id[p] ~= nil
        local s_ok = boss_data.bosses_by_id[s] ~= nil
        if not p_ok and not s_ok then return enabled[1] end
        if not p_ok then return s end
        if not s_ok then return p end
        if tracker.last_run_boss_id == p then return s end
        return p
    end

    return enabled[1]
end

task.shouldExecute = function ()
    -- Only fires in standalone Boss mode.  WarPlan handles transit.
    if core_mode.is_warplan() then return false end

    -- Don't try to teleport if no host API
    if not teleport_to_boss_dungeon then return false end

    local now = get_time_since_inject() or 0
    if tracker.last_teleport_t and (now - tracker.last_teleport_t) < TELEPORT_COOLDOWN_S then
        return false   -- still waiting for the previous teleport to land
    end

    -- Already in the target boss's zone?  No work to do; let the in-zone
    -- state machine fire instead.
    local w = get_current_world()
    local zone = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    local current_boss = boss_data.boss_for_zone(zone)
    local target = tracker.target_boss_id

    if target and current_boss and current_boss.id == target then
        return false
    end

    -- We need to (re-)pick a target.  If we DO have a target but we're in
    -- the wrong zone, that means we're between runs.  If no target yet,
    -- pick one now.
    return true
end

task.Execute = function ()
    local now = get_time_since_inject() or 0

    -- Decide which boss to target this cycle
    local target = tracker.target_boss_id
    if not target or tracker.run_done then
        target = pick_next_boss_id()
        if not target then
            task.status = 'no enabled bosses'
            return
        end
        tracker.target_boss_id = target
        tracker.last_run_boss_id = tracker.run_done and target or tracker.last_run_boss_id
        tracker.run_done = false
        if settings.debug_mode then
            console.print('[Boss] target boss -> ' .. target)
        end
    end

    local boss = boss_data.bosses_by_id[target]
    if not boss or not boss.sno then
        task.status = 'unknown boss ' .. tostring(target)
        return
    end

    -- Fire teleport.  Engage cooldown so we don't double-fire while the
    -- zone loads.
    if settings.debug_mode then
        console.print(string.format('[Boss] teleport_to_boss_dungeon(%d) -> %s',
            boss.sno, boss.label))
    end
    teleport_to_boss_dungeon(boss.sno)
    tracker.last_teleport_t = now
    -- Reset the per-run state machine so the next zone-arrival starts clean
    tracker.altar_seen       = false
    tracker.altar_activated  = false
    tracker.altar_activate_t = nil
    tracker.chest_opened     = false
    tracker.chest_opened_t   = nil
    task.status = 'teleporting to ' .. boss.label
end

return task
