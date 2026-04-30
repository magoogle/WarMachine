-- ---------------------------------------------------------------------------
-- core/alfred_bridge.lua
--
-- Glue between WarMachine and AlfredTheButler.  When the bot's bags fill
-- up or armor needs repair AND the current activity is in a "safe to
-- interrupt" state, we hand control to Alfred via
-- AlfredTheButlerPlugin.trigger_tasks_with_teleport(...).  Alfred handles
-- the teleport-to-town, sells/salvages/repairs/restocks, and fires our
-- callback when finished.  Each activity's shouldExecute() naturally
-- self-deselects while we're in town, so the activity just resumes when
-- the player is back in zone.
--
-- No-op if AlfredTheButlerPlugin isn't installed -- WarMachine still runs.
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- Module state.  Ours, not Alfred's.
-- ---------------------------------------------------------------------------
local state = {
    -- True between trigger_tasks_with_teleport and the completion callback.
    -- While true, activities yield each pulse so we don't fight Alfred for
    -- input.
    alfred_running     = false,

    -- We poll Alfred status at most this often.  get_status is cheap but
    -- the hot path is every pulse (~50ms), so throttle.
    last_check_t       = 0,

    -- After Alfred finishes, refuse to re-trigger for this many seconds.
    -- Without this we'd re-fire the moment Alfred gets back in the zone
    -- if its sells didn't reduce inventory_count below the threshold
    -- (e.g. high-tier rares it kept).
    cooldown_until_t   = 0,

    -- Reason for the most recent / current trigger, for status display.
    last_reason        = '',
}

local CHECK_INTERVAL_S         = 3
local POST_ALFRED_COOLDOWN_S   = 60

-- ---------------------------------------------------------------------------
-- Per-activity "is the bot doing something we shouldn't interrupt" check.
-- The activity exposes its current task name via tracker.current_task; we
-- name-match against a small set of "fine to interrupt" tasks.  Any task
-- not in this list (kill_monster, maiden, walk_boss_room, etc.) blocks
-- the town run until the bot transitions to a safer state.
-- ---------------------------------------------------------------------------
local SAFE_TASK_NAMES = {
    idle           = true,
    interact_poi   = true,
    return_to_zone = true,
    floor_portal   = true,
    enter_pit      = true,
    enter_undercity = true,
    -- Hordes: between waves only.  'idle' fires when arena is clear.
    -- 'kill_monster' is NOT in the list -- mid-wave inventory triggers
    -- get deferred until the wave ends.
}

-- Get the "current task name" for the active in-house activity, if any.
-- Returns nil if no activity is running (i.e. WarPlan orchestration only).
local function current_task_name()
    -- Lazy require to avoid circular imports during module load.
    local ok, am = pcall(require, 'core.activity_manager')
    if not ok or not am or not am.get_active_tag then return nil end
    local tag = am.get_active_tag()
    if not tag then return nil end
    -- Each activity exposes get_status(); the current task name is in there.
    local mod_ok, mod = pcall(require, 'activities.' .. tag .. '.api')
    if not mod_ok or not mod or not mod.get_status then return nil end
    local s = mod.get_status() or {}
    return s.task
end

-- ---------------------------------------------------------------------------
-- Alfred plugin available?  Plugin global is set by AlfredTheButler/main.lua
-- on load.  We check the get_status function specifically since older
-- versions might have the global without the API surface.
-- ---------------------------------------------------------------------------
local function alfred_available()
    return AlfredTheButlerPlugin
        and AlfredTheButlerPlugin.get_status
        and AlfredTheButlerPlugin.trigger_tasks_with_teleport
end

-- ---------------------------------------------------------------------------
-- Public: poll-and-maybe-intercept.  Call from main_pulse before activity
-- dispatch.  Returns true if WarMachine should yield this pulse (Alfred
-- is running OR we just triggered it), false otherwise.
-- ---------------------------------------------------------------------------
M.update = function ()
    if not alfred_available() then return false end

    local now = (get_time_since_inject and get_time_since_inject()) or os.time()

    -- If Alfred is in the middle of a town run, just wait.  Belt-and-
    -- suspenders: poll its status and clear our flag if its all_task_done
    -- went true (e.g. callback failed to fire for some reason).
    if state.alfred_running then
        local s = AlfredTheButlerPlugin.get_status()
        if s and s.all_task_done then
            state.alfred_running   = false
            state.cooldown_until_t = now + POST_ALFRED_COOLDOWN_S
        end
        return true
    end

    -- Cooldown gate: don't re-check or re-trigger immediately after a run.
    if now < state.cooldown_until_t then return false end

    -- Throttle: status queries are cheap but not free.  Once every few
    -- seconds is plenty for an inventory-fill check.
    if (now - state.last_check_t) < CHECK_INTERVAL_S then return false end
    state.last_check_t = now

    local s = AlfredTheButlerPlugin.get_status()
    if not s or not s.enabled then return false end

    local need_town = s.inventory_full or s.need_repair
    if not need_town then return false end

    -- Activity must be in a safe-to-interrupt state.  If the activity is
    -- mid-combat (kill_monster, maiden, etc.), defer until it transitions
    -- to a safer task.
    local task = current_task_name()
    if task and not SAFE_TASK_NAMES[task] then
        return false
    end

    -- Pull the trigger.  Alfred handles teleport + sells/salvages/repairs
    -- + restocks; our callback resets state when it's done.
    state.last_reason    = s.inventory_full and 'inventory_full' or 'need_repair'
    state.alfred_running = true
    if console and console.print then
        console.print('[WarMachine/Alfred] handing off (' .. state.last_reason .. ')')
    end
    pcall(function ()
        AlfredTheButlerPlugin.trigger_tasks_with_teleport('warmachine', function ()
            state.alfred_running   = false
            state.cooldown_until_t = (get_time_since_inject and get_time_since_inject() or os.time())
                                   + POST_ALFRED_COOLDOWN_S
            if console and console.print then
                console.print('[WarMachine/Alfred] town run finished, resuming')
            end
        end)
    end)
    return true
end

-- ---------------------------------------------------------------------------
-- Public: read-only status accessor for /status overlays + GUI.
-- ---------------------------------------------------------------------------
M.get_status = function ()
    if not alfred_available() then
        return { available = false }
    end
    return {
        available      = true,
        running        = state.alfred_running,
        last_reason    = state.last_reason,
        cooldown_until = state.cooldown_until_t,
    }
end

return M
