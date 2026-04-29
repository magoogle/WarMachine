-- ---------------------------------------------------------------------------
-- War Plan Next-Objective map-click -- sequence with poll-style verify.
--
-- Sequence:  Tab (open map) -> wait -> click configured Next-Obj coords ->
--            poll for zone-change OR position-jump up to MAX_VERIFY_S
--
-- Why poll: the war plan's auto-teleport doesn't always fire immediately
-- after the click. Observed delay: up to 6+ seconds. A short fixed wait
-- can declare "no-op" before the actual teleport happens.
--
-- Success signals (either one):
--   * zone name changed                    -- cross-zone tp (Skov_Temis -> DGN_*)
--   * player position jumped > 100 yards   -- in-zone tp (e.g. boss room cell)
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'

local VK_TAB = 0x09

local STEP_OPEN_MAP = 0
local STEP_CLICK    = 1
local STEP_VERIFY   = 2

local OPEN_MAP_WAIT_S = 0.60   -- give the map UI time to draw
local MAX_VERIFY_S    = 8.00   -- poll for tp this long before declaring no-op
local POS_JUMP_Y      = 100.0  -- in-zone tp threshold

local task = {
    name   = 'warplan_test_next_obj',
    status = nil,
}

local function reset(state)
    state.pending           = false
    state.step              = 0
    state.timer             = 0
    state.verify_started_at = nil
    state.baseline_zone     = nil
    state.baseline_pos_x    = nil
    state.baseline_pos_y    = nil
end

local function current_zone()
    local w = get_current_world()
    return w and w:get_current_zone_name() or nil
end

-- Fires when the dispatch task (or pit/post_boss) sets tracker.warplan.next_obj.pending.
task.shouldExecute = function ()
    return tracker.warplan.next_obj.pending == true
end

task.Execute = function ()
    local state = tracker.warplan.next_obj
    local cps   = settings.warplan and settings.warplan.click_points
    if not cps or not cps.next_objective then
        console.print('[WarMachine] Next-Obj coords missing -- aborting test')
        state.result = 'failed'
        reset(state)
        return
    end

    local now = get_time_since_inject()

    if state.step == STEP_OPEN_MAP then
        task.status = 'opening map (Tab)'
        utility.send_key_press(VK_TAB)
        state.timer = now
        state.step  = STEP_CLICK
        return
    end

    if state.step == STEP_CLICK then
        if now - state.timer < OPEN_MAP_WAIT_S then return end
        local p = cps.next_objective
        task.status = 'click next-obj'
        console.print(string.format('[WarMachine] Click Next-Obj at (%d,%d)', p.x, p.y))
        utility.send_mouse_click(p.x, p.y)
        state.timer = now
        state.step  = STEP_VERIFY
        return
    end

    if state.step == STEP_VERIFY then
        -- Mark when verify first started so we can compute total verify time
        if not state.verify_started_at then
            state.verify_started_at = now
        end

        -- Check zone change
        local cur_zone = current_zone()
        if cur_zone ~= state.baseline_zone then
            console.print(string.format('[WarMachine] Next-Obj SUCCESS -- zone %s -> %s',
                tostring(state.baseline_zone), tostring(cur_zone)))
            state.result = 'success'
            reset(state)
            task.status = nil
            return
        end

        -- Check in-zone position jump (e.g. teleport to a different cell
        -- within the same zone -- happens with NMD boss rooms)
        local lp  = get_local_player()
        local pos = lp and lp:get_position() or nil
        if pos and state.baseline_pos_x and state.baseline_pos_y then
            local dx = pos:x() - state.baseline_pos_x
            local dy = pos:y() - state.baseline_pos_y
            local jump = math.sqrt(dx*dx + dy*dy)
            if jump >= POS_JUMP_Y then
                console.print(string.format('[WarMachine] Next-Obj SUCCESS -- in-zone tp (jump %.0fy)', jump))
                state.result = 'success'
                reset(state)
                task.status = nil
                return
            end
        end

        -- Still waiting for tp...
        if now - state.verify_started_at < MAX_VERIFY_S then
            task.status = string.format('verifying (%.1fs)', now - state.verify_started_at)
            return
        end

        -- Timed out -- no zone or position change
        console.print(string.format('[WarMachine] Next-Obj no-op -- zone unchanged (%s) after %.0fs',
            tostring(cur_zone), MAX_VERIFY_S))
        state.result = 'no_zone_change'
        reset(state)
        task.status = nil
        return
    end
end

return task
