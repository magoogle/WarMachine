-- ---------------------------------------------------------------------------
-- tasks/warplan/test_select.lua
--
-- Drives the WAR PLANS vendor menu via the host's `warplan` API.
--
-- Picker algorithm: a recursive walk that uses the live API as the
-- single source of truth.  At each level we ask get_selectable_now()
-- for the current legal set, filter Nightmare nodes when the user has
-- opted out of NMD, commit each candidate via select_node(), recurse,
-- and unwind via deselect_last() if no descendant chain produces a
-- complete path.  Because get_selectable_now() reflects the panel's
-- own state machine after each select_node(), we never have to model
-- the neighbor encoding ourselves (sentinel 0xFFFFFFFF, slot
-- directionality) -- the API tells us what's reachable.
--
-- Why the API-walk instead of node-graph lookahead: an earlier
-- implementation introspected get_node().neighbors and tried to score
-- candidates by "does any descendant chain stay clean?"  That worked
-- for simple panels but the neighbor encoding has subtle quirks
-- (sentinel ids, cross-links) that made the lookahead brittle.  The
-- API-walk is robust to all of them by construction.
--
-- Failure mode this fixes: the previous "pick legal[1] minus nightmare"
-- approach committed to whichever non-NMD root happened to be first
-- in the list and got stuck when that root's only descendant chain
-- ran through Nightmare Dungeons.  Live dump showed exactly this:
-- required_picks=5, root id=1 (Pit) selected, then selectable_now=[6]
-- where node 6 is NMD -- nothing else legal, abort.  The recursive
-- walk rejects root 1 up-front because no clean continuation exists
-- from it, then commits to root 2 or 3 (both have NMD-free 5-paths).
--
-- Reroll: when the live tree is fully NMD-locked (every 5-pick path
-- crosses NMD), the picker can fire the panel's "New Plan" button +
-- its confirm dialog to regenerate the tree, then retry.  Click
-- coords are configured as %-of-screen in the GUI and the picker
-- skips the reroll path entirely if the user hasn't dialed them in
-- (defaults are 0/0 so we never click into a wrong UI).
--
-- Flow:
--   STEP_VERIFY     -- one-shot warplan.is_ready() guard
--   STEP_SEARCH     -- recursive API walk; on success leaves the panel
--                      fully selected and transitions to STEP_COMMIT
--   STEP_REROLL_FIRE   -- fire the "New Plan" click; wait the dialog
--                         delay; transition to STEP_REROLL_CONFIRM
--   STEP_REROLL_CONFIRM -- fire the confirm-dialog click; wait the
--                          settle delay; loop back to STEP_SEARCH
--   STEP_COMMIT     -- warplan.confirm() once the path is complete
--   STEP_VERIFY_NEW -- short wait, then quest-count delta sanity check
--
-- The pending flag (tracker.warplan.test.pending) and the baseline
-- quest count (tracker.warplan.test.baseline) are still set by the
-- upstream caller (start_cycle / dispatch), so the integration with
-- the rest of the warplan supervisor is unchanged.
-- ---------------------------------------------------------------------------

local settings     = require 'core.settings'
local tracker      = require 'core.tracker'
local warplan_dump = require 'core.warplan_dump'
local whispers     = require 'core.whispers'   -- for click_at_frac (generic helper)

local STEP_VERIFY         = 0
local STEP_SEARCH         = 1
local STEP_COMMIT         = 2
local STEP_VERIFY_NEW     = 3
local STEP_REROLL_FIRE    = 4
local STEP_REROLL_CONFIRM = 5

-- Pacing constants.  D4's vendor UI animates the New Plan dialog and
-- repaints the tree on confirm, so we wait between clicks.  Tuned to
-- the slowest observed live timing with a small margin.
local COMMIT_DELAY_S        = 0.20    -- between path-selection complete and confirm()
local VERIFY_WAIT_S         = 1.00    -- between confirm() and quest-count check
local REROLL_DIALOG_DELAY_S = 1.50    -- after first click, before confirming
local REROLL_SETTLE_DELAY_S = 4.00    -- after confirm, before re-searching

local function api_available()
    return type(_G.warplan) == 'table'
       and type(_G.warplan.is_ready) == 'function'
end

local function api_ready()
    if not api_available() then return false end
    local ok, ret = pcall(warplan.is_ready)
    return ok and ret == true
end

-- "Is this node a Nightmare Dungeon" check, by node_name.  We rely on
-- the host's naming convention where node_name returns "Warplans_<X>"
-- with X being the activity tag ("NightmareDungeons" / "Pit" / etc.).
-- The reward field is intentionally NOT consulted: rewards include
-- strings like "WarPlans_Cache_Talismans_Magic" that don't correspond
-- to the activity.
local function is_nightmare(id)
    local ok, name = pcall(warplan.node_name, id)
    if not ok or type(name) ~= 'string' then return false end
    return name:find('Nightmare', 1, true) ~= nil
end

-- Recursive walk through the live API.  Tries each currently-selectable
-- node, commits via select_node + recurse, unwinds via deselect_last
-- on dead-end.  When it returns true the panel is fully selected at
-- the depth required_picks(); when it returns false the panel is at
-- the same selection depth it was when we entered.
--
-- Cheap: warplan trees seen in the wild fit in <30 nodes with <=3
-- branching, so worst-case ~3^required exploration is trivial.
local function search_path(required, allow_nightmare)
    local sel_ok, sel = pcall(warplan.selected_count)
    if not sel_ok or type(sel) ~= 'number' then return false end
    if sel >= required then
        local cmp_ok, complete = pcall(warplan.is_complete)
        return cmp_ok and complete == true
    end

    local lg_ok, legal = pcall(warplan.get_selectable_now)
    if not lg_ok or type(legal) ~= 'table' or #legal == 0 then return false end

    for _, id in ipairs(legal) do
        if allow_nightmare or not is_nightmare(id) then
            local s_ok, accepted = pcall(warplan.select_node, id)
            if s_ok and accepted then
                if search_path(required, allow_nightmare) then return true end
                pcall(warplan.deselect_last)   -- dead end -> backtrack
            end
        end
    end
    return false
end

-- Fully unwind any prior selection so search_path starts from a known
-- baseline.  Bounded iteration as a safety net -- selected_count must
-- decrease per deselect; if it doesn't, we abort the unwind so the
-- caller can surface the failure.
local function clear_selection()
    for _ = 1, 32 do
        local ok, sel = pcall(warplan.selected_count)
        if not ok or type(sel) ~= 'number' or sel <= 0 then return end
        local d_ok, d_ret = pcall(warplan.deselect_last)
        if not d_ok or d_ret == false then return end
    end
end

-- True iff both reroll click points are configured (non-zero in both
-- axes for both clicks).  When false, the picker skips the reroll
-- path entirely and aborts on a fully NMD-locked tree.
local function reroll_configured(sw)
    return sw.new_plan_x_frac         and sw.new_plan_x_frac         > 0
       and sw.new_plan_y_frac         and sw.new_plan_y_frac         > 0
       and sw.new_plan_confirm_x_frac and sw.new_plan_confirm_x_frac > 0
       and sw.new_plan_confirm_y_frac and sw.new_plan_confirm_y_frac > 0
end

local task = {
    name   = 'warplan_test_select',
    status = nil,
}

local function reset_state(state)
    state.pending                 = false
    state.step                    = 0
    state.timer                   = 0
    state.reroll_count            = 0
    state.reroll_confirm_fired_at = nil
end

task.shouldExecute = function ()
    return tracker.warplan.test.pending == true
end

task.Execute = function ()
    local state = tracker.warplan.test
    local now   = get_time_since_inject()
    local sw    = settings.warplan or {}

    -- ---- STEP_VERIFY: panel + API ready? -----------------------------------
    if state.step == STEP_VERIFY then
        if not api_available() then
            console.print('[WarMachine] Auto-select aborted -- host warplan API missing.')
            state.result = 'no_api'
            reset_state(state)
            task.status = nil
            return
        end
        if not api_ready() then
            console.print('[WarMachine] Auto-select aborted -- warplan panel not ready.')
            state.result = 'menu_closed'
            reset_state(state)
            task.status = nil
            return
        end
        state.step         = STEP_SEARCH
        state.timer        = now
        state.reroll_count = state.reroll_count or 0
        task.status = 'searching path'
        return
    end

    -- ---- STEP_SEARCH: recursive API walk -----------------------------------
    if state.step == STEP_SEARCH then
        local r_ok, required = pcall(warplan.required_picks)
        if not r_ok or type(required) ~= 'number' then
            console.print('[WarMachine] required_picks() error -- aborting.')
            state.result = 'no_required'
            reset_state(state)
            task.status = nil
            return
        end

        if required == 0 then
            -- Nothing to pick (rare, but the API allows it) -- skip
            -- straight to commit.
            state.step  = STEP_COMMIT
            state.timer = now
            task.status = 'confirm'
            return
        end

        local allow_nm = sw.allow_nightmare == true
        clear_selection()

        local ok, found = pcall(search_path, required, allow_nm)
        if not ok then
            console.print('[WarMachine] search error: ' .. tostring(found))
            state.result = 'search_error'
            reset_state(state)
            task.status = nil
            return
        end

        if found then
            local p_ok, path = pcall(warplan.selected_path)
            if p_ok and type(path) == 'table' then
                local parts = {}
                for _, id in ipairs(path) do
                    local n_ok, nm = pcall(warplan.node_name, id)
                    parts[#parts + 1] = string.format('%d(%s)',
                        id, (n_ok and type(nm) == 'string' and nm ~= '') and nm or '?')
                end
                console.print('[WarMachine] picked path: ' .. table.concat(parts, ' -> '))
            end
            state.step  = STEP_COMMIT
            state.timer = now
            task.status = 'confirm'
            return
        end

        -- No clean path in the current tree.  If reroll is enabled
        -- AND we haven't burned the cap yet, regenerate the tree and
        -- retry.  Otherwise abort with a dump.
        local max_rerolls = sw.max_rerolls or 0
        if not allow_nm
           and max_rerolls > 0
           and (state.reroll_count or 0) < max_rerolls
           and reroll_configured(sw)
        then
            state.reroll_count = (state.reroll_count or 0) + 1
            console.print(string.format(
                '[WarMachine] tree NMD-locked -- requesting New Plan (attempt %d/%d)',
                state.reroll_count, max_rerolls))
            -- Make sure we leave the panel in the unselected state the
            -- New Plan UI expects.
            clear_selection()
            state.step  = STEP_REROLL_FIRE
            state.timer = now
            task.status = 'rerolling'
            return
        end

        local why
        if allow_nm then
            why = 'no complete path of length ' .. tostring(required)
        elseif max_rerolls == 0 or not reroll_configured(sw) then
            why = 'every path crosses Nightmare and reroll is not configured'
        else
            why = string.format('every path crosses Nightmare after %d reroll(s)',
                state.reroll_count or 0)
        end
        console.print('[WarMachine] Auto-select aborted -- ' .. why)
        pcall(warplan_dump.dump)
        clear_selection()
        state.result = 'no_allowed'
        reset_state(state)
        task.status = nil
        return
    end

    -- ---- STEP_REROLL_FIRE: click the "New Plan" button ---------------------
    if state.step == STEP_REROLL_FIRE then
        local fired = whispers.click_at_frac(sw.new_plan_x_frac, sw.new_plan_y_frac)
        if not fired then
            console.print('[WarMachine] reroll: click utility unavailable -- aborting reroll.')
            state.result = 'no_click_util'
            reset_state(state)
            task.status = nil
            return
        end
        console.print('[WarMachine] reroll: New Plan click fired')
        state.step  = STEP_REROLL_CONFIRM
        state.timer = now
        task.status = 'reroll dialog'
        return
    end

    -- ---- STEP_REROLL_CONFIRM: confirm the dialog, then settle --------------
    if state.step == STEP_REROLL_CONFIRM then
        if (now - state.timer) < REROLL_DIALOG_DELAY_S then return end

        -- The state may transition twice through this block: first to
        -- fire the confirm click, second to wait the settle delay.
        -- We use the timer reset after the click as a marker for which
        -- phase we're in.
        if state.reroll_confirm_fired_at == nil
           or state.reroll_confirm_fired_at <= state.timer
        then
            local fired = whispers.click_at_frac(
                sw.new_plan_confirm_x_frac, sw.new_plan_confirm_y_frac)
            if not fired then
                console.print('[WarMachine] reroll: confirm click failed -- aborting.')
                state.result = 'no_click_util'
                reset_state(state)
                task.status = nil
                return
            end
            console.print('[WarMachine] reroll: confirm click fired -- settling')
            state.reroll_confirm_fired_at = now
            return
        end

        if (now - state.reroll_confirm_fired_at) < REROLL_SETTLE_DELAY_S then return end

        -- Settled.  Re-verify the panel is still open with fresh data,
        -- then loop back to search.
        if not api_ready() then
            console.print('[WarMachine] reroll: panel closed during settle -- aborting.')
            state.result = 'menu_closed_after_reroll'
            reset_state(state)
            task.status = nil
            return
        end
        state.reroll_confirm_fired_at = nil
        state.step  = STEP_SEARCH
        state.timer = now
        task.status = 'searching after reroll'
        return
    end

    -- ---- STEP_COMMIT: send the confirm packet ------------------------------
    if state.step == STEP_COMMIT then
        if (now - state.timer) < COMMIT_DELAY_S then return end
        local ok = pcall(warplan.confirm)
        if not ok then
            console.print('[WarMachine] warplan.confirm() raised -- aborting.')
            state.result = 'confirm_error'
            reset_state(state)
            task.status = nil
            return
        end
        console.print('[WarMachine] warplan.confirm() sent.')
        state.step  = STEP_VERIFY_NEW
        state.timer = now
        task.status = 'verifying'
        return
    end

    -- ---- STEP_VERIFY_NEW: confirm grew the quest log -----------------------
    if state.step == STEP_VERIFY_NEW then
        if (now - state.timer) < VERIFY_WAIT_S then return end
        local cur      = #get_quests()
        local baseline = state.baseline or 0
        if cur > baseline then
            console.print(string.format(
                '[WarMachine] Auto-select SUCCESS -- quest count %d -> %d',
                baseline, cur))
            state.result = 'success'
        else
            console.print(string.format(
                '[WarMachine] Auto-select FAILED -- no quest delta (baseline=%d, current=%d).',
                baseline, cur))
            state.result = 'failed'
        end
        reset_state(state)
        task.status = nil
        return
    end
end

return task
