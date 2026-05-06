-- ---------------------------------------------------------------------------
-- tasks/warplan/test_select.lua
--
-- Drives the WAR PLANS vendor menu via the host's `warplan` API.
-- Replaces the old pixel-click sequence: there are no more slot / Start /
-- Confirm click points.  warplan.confirm() sends the confirm packet
-- directly, so the dialog buttons aren't touched.
--
-- Flow:
--   STEP_VERIFY  -- one-shot warplan.is_ready() guard
--   STEP_PICK    -- one warplan.select_node(id) per tick, skipping
--                   Nightmare Dungeon nodes when settings.warplan
--                   .allow_nightmare is OFF (the default).  Bails out
--                   cleanly if filtering removes every legal option.
--   STEP_CONFIRM -- warplan.confirm() once the path is_complete()
--   STEP_DELTA   -- short wait, then quest-count delta sanity check
--
-- The pending flag (tracker.warplan.test.pending) and the baseline
-- quest count (tracker.warplan.test.baseline) are still set by the
-- upstream caller (start_cycle / dispatch) so the integration with the
-- rest of the warplan supervisor doesn't change.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'

local STEP_VERIFY  = 0
local STEP_PICK    = 1
local STEP_CONFIRM = 2
local STEP_DELTA   = 3

-- Aggressive: the API doesn't have UI animations to wait on, but a tiny
-- spacing keeps a single per-frame select_node call even on long paths
-- so we don't burn 5+ select_nodes in one tick.
local PICK_DELAY_S    = 0.05
local CONFIRM_DELAY_S = 0.20
local VERIFY_WAIT_S   = 1.00

local function api_available()
    return type(_G.warplan) == 'table'
       and type(_G.warplan.is_ready) == 'function'
end

local function api_ready()
    if not api_available() then return false end
    local ok, ret = pcall(warplan.is_ready)
    return ok and ret == true
end

-- Return the first id from warplan.get_selectable_now() that does NOT
-- match the Nightmare filter when allow_nightmare is off.  Returns nil
-- if every candidate is filtered out (caller treats that as "abort").
local function pick_next_id(allow_nightmare)
    local ok, legal = pcall(warplan.get_selectable_now)
    if not ok or type(legal) ~= 'table' or #legal == 0 then return nil end
    if allow_nightmare then return legal[1] end
    for _, id in ipairs(legal) do
        local n_ok, name   = pcall(warplan.node_name,        id)
        local r_ok, reward = pcall(warplan.node_reward_name, id)
        name   = n_ok and name   or ''
        reward = r_ok and reward or ''
        -- Match both the activity name and the reward name -- the host
        -- has been observed to put the activity tag on either field
        -- depending on the node type.
        if not name:find('Nightmare', 1, true)
           and not reward:find('Nightmare', 1, true)
        then
            return id
        end
    end
    return nil
end

local task = {
    name   = 'warplan_test_select',
    status = nil,
}

local function reset_state(state)
    state.pending = false
    state.step    = 0
    state.timer   = 0
end

task.shouldExecute = function ()
    return tracker.warplan.test.pending == true
end

task.Execute = function ()
    local state = tracker.warplan.test
    local now   = get_time_since_inject()

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
        state.step  = STEP_PICK
        state.timer = now
        task.status = 'picking nodes'
        return
    end

    -- ---- STEP_PICK: one select_node per tick, with NMD filter --------------
    if state.step == STEP_PICK then
        if now - state.timer < PICK_DELAY_S then return end

        local c_ok, complete = pcall(warplan.is_complete)
        if c_ok and complete then
            state.step  = STEP_CONFIRM
            state.timer = now
            task.status = 'confirm'
            return
        end

        local allow_nm = settings.warplan and settings.warplan.allow_nightmare or false
        local id = pick_next_id(allow_nm)
        if not id then
            local why = allow_nm and 'no legal picks remaining'
                                  or 'all legal picks were Nightmare (filter on)'
            console.print('[WarMachine] Auto-select aborted -- ' .. why)
            state.result = 'no_allowed'
            reset_state(state)
            task.status = nil
            return
        end

        local s_ok, accepted = pcall(warplan.select_node, id)
        if not s_ok or not accepted then
            console.print(string.format(
                '[WarMachine] warplan.select_node(%d) refused -- aborting.', id))
            state.result = 'select_refused'
            reset_state(state)
            task.status = nil
            return
        end

        local n_ok, n_name = pcall(warplan.node_name, id)
        console.print(string.format('[WarMachine] picked id %d (%s)',
            id, (n_ok and n_name ~= '' and n_name) or '?'))
        state.timer = now
        return
    end

    -- ---- STEP_CONFIRM: send the confirm packet -----------------------------
    if state.step == STEP_CONFIRM then
        if now - state.timer < CONFIRM_DELAY_S then return end
        local ok = pcall(warplan.confirm)
        if not ok then
            console.print('[WarMachine] warplan.confirm() raised -- aborting.')
            state.result = 'confirm_error'
            reset_state(state)
            task.status = nil
            return
        end
        console.print('[WarMachine] warplan.confirm() sent.')
        state.step  = STEP_DELTA
        state.timer = now
        task.status = 'verifying'
        return
    end

    -- ---- STEP_DELTA: confirm grew the quest log ----------------------------
    if state.step == STEP_DELTA then
        if now - state.timer < VERIFY_WAIT_S then return end
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
