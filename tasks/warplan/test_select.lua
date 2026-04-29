-- ---------------------------------------------------------------------------
-- tasks/warplan/test_select.lua
--
-- War Plan vendor menu auto-select sequence.
--
-- Strategy (per user direction, until a popup-detection API is available):
--   1. Verify the vendor menu is open (one-shot guard).
--   2. Click every configured slot point in rapid succession. Extra clicks
--      on already-selected slots OR on world-coords behind the menu are
--      harmless -- the menu absorbs them and the game ignores no-op clicks.
--   3. Click START.
--   4. Click Confirm.
--   5. Verify quest count delta. If it grew, war plan was accepted.
--
-- Walk-away guard: capture player position at sequence start. If a stray
-- Confirm click hit world coords and the player walked more than ~3y, abort
-- cleanly so we don't pile-walk further off the menu.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'

local STEP_VERIFY_MENU   = 0   -- one-shot guard
local STEP_CLICK_SLOT    = 1   -- iterate all configured slots once each
local STEP_CLICK_START   = 2   -- single click
local STEP_CLICK_CONFIRM = 3   -- single click
local STEP_VERIFY        = 4   -- quest-count delta check

-- Aggressive timings -- UI is responsive per user observation.
local SLOT_DELAY_S    = 0.10   -- between slot clicks
local POST_SLOTS_S    = 0.20   -- after last slot, before START
local CONFIRM_DELAY_S = 0.40   -- after START, before Confirm (popup render)
local VERIFY_WAIT_S   = 1.00   -- after Confirm, before quest check

local MAX_WALK_Y = 3.0   -- abort if player walked further than this since start

local function menu_is_open()
    if not loot_manager or not loot_manager.is_in_vendor_screen then return false end
    local ok, ret = pcall(loot_manager.is_in_vendor_screen)
    return ok and ret == true
end

local task = {
    name   = 'warplan_test_select',
    status = nil,
}

local function reset_test_state(state)
    state.pending      = false
    state.step         = 0
    state.current_slot = 1
    state.timer        = 0
    state.start_pos_x  = nil
    state.start_pos_y  = nil
end

local function distance_walked_since_start(state)
    if not state.start_pos_x or not state.start_pos_y then return 0 end
    local lp = get_local_player()
    if not lp then return 0 end
    local p = lp:get_position()
    if not p then return 0 end
    local dx = p:x() - state.start_pos_x
    local dy = p:y() - state.start_pos_y
    return math.sqrt(dx*dx + dy*dy)
end

-- Fires when the dispatch task (or start_cycle) sets tracker.warplan.test.pending.
task.shouldExecute = function ()
    return tracker.warplan.test.pending == true
end

task.Execute = function ()
    local state = tracker.warplan.test
    local cps   = settings.warplan and settings.warplan.click_points
    if not cps then
        console.print('[WarMachine] Click points missing -- aborting test')
        state.result = 'failed'
        reset_test_state(state)
        return
    end

    local now = get_time_since_inject()

    -- Step 0: one-shot menu-open guard + capture player position.
    if state.step == STEP_VERIFY_MENU then
        if not menu_is_open() then
            console.print('[WarMachine] Click test ABORTED -- vendor menu not open')
            state.result = 'menu_closed'
            reset_test_state(state)
            task.status = nil
            return
        end
        local lp = get_local_player()
        if lp then
            local p = lp:get_position()
            if p then
                state.start_pos_x = p:x()
                state.start_pos_y = p:y()
            end
        end
        state.current_slot = 1
        state.step         = STEP_CLICK_SLOT
        state.timer        = now
        task.status        = 'sequencing slots'
        return
    end

    -- Step 1: click each configured slot once. Skip slots at (0,0).
    if state.step == STEP_CLICK_SLOT then
        if now - state.timer < SLOT_DELAY_S then return end
        local slot = cps.slots[state.current_slot]
        if not slot then
            -- All slots done -- advance to START
            console.print('[WarMachine] All slots clicked, advancing to START')
            state.step  = STEP_CLICK_START
            state.timer = now
            task.status = 'click START'
            return
        end
        if slot.x ~= 0 or slot.y ~= 0 then
            console.print(string.format('[WarMachine] Click slot %d at (%d,%d)', state.current_slot, slot.x, slot.y))
            utility.send_mouse_click(slot.x, slot.y)
        end
        state.current_slot = state.current_slot + 1
        state.timer        = now
        task.status        = 'click slot ' .. state.current_slot
        return
    end

    -- Step 2: click START.
    if state.step == STEP_CLICK_START then
        if now - state.timer < POST_SLOTS_S then return end
        local s = cps.start
        if s and (s.x ~= 0 or s.y ~= 0) then
            console.print(string.format('[WarMachine] Click START at (%d,%d)', s.x, s.y))
            utility.send_mouse_click(s.x, s.y)
        else
            console.print('[WarMachine] START coords not configured -- skipping')
        end
        state.step  = STEP_CLICK_CONFIRM
        state.timer = now
        task.status = 'click Confirm'
        return
    end

    -- Step 3: click Confirm.
    if state.step == STEP_CLICK_CONFIRM then
        if now - state.timer < CONFIRM_DELAY_S then return end
        local c = cps.confirm
        if c and (c.x ~= 0 or c.y ~= 0) then
            console.print(string.format('[WarMachine] Click Confirm at (%d,%d)', c.x, c.y))
            utility.send_mouse_click(c.x, c.y)
        else
            console.print('[WarMachine] Confirm coords not configured -- relying on quest delta')
        end
        state.step  = STEP_VERIFY
        state.timer = now
        task.status = 'verifying'
        return
    end

    -- Step 4: verify quest count delta (and walk-away guard).
    if state.step == STEP_VERIFY then
        if now - state.timer < VERIFY_WAIT_S then return end

        local walked = distance_walked_since_start(state)
        if walked > MAX_WALK_Y then
            console.print(string.format('[WarMachine] Click test ABORTED -- player walked %.1fy (Confirm hit world)', walked))
            state.result = 'walked_away'
            reset_test_state(state)
            task.status = nil
            return
        end

        local cur = #get_quests()
        if cur > state.baseline then
            console.print(string.format('[WarMachine] Click test SUCCESS -- quest count %d -> %d', state.baseline, cur))
            state.result = 'success'
        else
            console.print(string.format('[WarMachine] Click test FAILED -- no quest delta (baseline=%d, current=%d)', state.baseline, cur))
            state.result = 'failed'
        end
        reset_test_state(state)
        task.status = nil
        return
    end
end

return task
