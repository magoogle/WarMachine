-- ---------------------------------------------------------------------------
-- tasks/warplan/enter_undercity.lua
--
-- Drive the player from Skov_Temis into the Undercity dungeon when an
-- Undercity war plan is active.
--
-- Three-stage state machine, polled every pulse (idempotent calls):
--
--   1. Portal exists + interactable -> interact_object(portal). D4 walks us
--      in. Once zone changes to X1_Undercity_*, this task no longer fires.
--
--   2. Tribute UI open (loot_manager.is_in_vendor_screen() == true)
--      -> click "Open Portal" coords every ~1s until the portal spawns.
--
--   3. Neither portal nor tribute UI -> interact_object(Undercity Obelisk)
--      every ~2s. D4 walks the player to it and opens the tribute menu.
--      (Internal skin name is Aubrie_Test_Undercity_Crafter -- leftover dev
--       naming; players know it as the Undercity Obelisk in Temis.)
--
-- Aborts with a 30s total timeout if nothing progresses.
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local mode     = require 'core.mode'
local interact = require 'core.interact'

-- Internal skin name for the Undercity Obelisk in Temis.
-- (The "Aubrie_Test_..." prefix is leftover dev naming.)
local OBELISK_SKIN = 'Aubrie_Test_Undercity_Crafter'
local PORTAL_SKIN  = 'Portal_Dungeon_Undercity'

local INTERACT_RANGE      = 30.0
local OBELISK_RETRY_S     = 2.0
local OPEN_PORTAL_RETRY_S = 1.5     -- click Open Portal every N seconds
local ENTER_DELAY_S       = 0.50    -- send Enter this long after each Open Portal click
local TOTAL_TIMEOUT_S     = 30.0

local VK_RETURN = 0x0D

local task = { name = 'warplan_enter_undercity', status = nil }

local function menu_open()
    if not loot_manager or not loot_manager.is_in_vendor_screen then return false end
    local ok, ret = pcall(loot_manager.is_in_vendor_screen)
    return ok and ret == true
end

local function reset_pending(state)
    state.pending          = false
    state.first_attempt_at = nil
    state.last_interact_at = nil
    state.last_click_at    = nil
    state.send_enter_at    = nil
end

-- Helper: is at least one entry actor in stream?  We only claim the pulse
-- when there's something to act on locally. If none of the obelisk / portal
-- are in stream and the tribute UI isn't open, we yield to dispatch so it
-- can fire Next-Obj and map-teleport us right to the obelisk.
local function has_any_entry_actor()
    if menu_open() then return true end
    if interact.find_by_skin(PORTAL_SKIN, true)  then return true end
    if interact.find_by_skin(OBELISK_SKIN, true) then return true end
    return false
end

task.shouldExecute = function ()
    local state = tracker.undercity.enter

    -- Yield to other in-flight click sequences. (tracker.nmd was removed
    -- when WarMachine pivoted to the sub-plugin orchestrator; SigilRunner
    -- handles sigil consumption inside its own task loop now.)
    local yielding = tracker.warplan.test.pending
       or tracker.warplan.next_obj.pending
       or tracker.warplan.turn_in.pending
       or tracker.warplan.start_cycle.pending

    local should_fire = not yielding
        and (settings.undercity == nil or settings.undercity.auto_enter ~= false)

    if should_fire then
        -- Fires only when: in Skov_Temis AND War Plan mode AND active
        -- warplan activity is 'undercity'. Standalone Undercity mode was
        -- removed when WarMachine pivoted to the sub-plugin orchestrator
        -- (WonderCity owns standalone Undercity now).
        local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
        if zone ~= 'Skov_Temis' then should_fire = false end

        if should_fire then
            if settings.mode == mode.WARPLAN then
                local wp = tracker.warplan.snapshot
                if not (wp and wp.active and wp.activity == 'undercity') then
                    should_fire = false
                end
            else
                should_fire = false
            end
        end
    end

    -- If we're in the right zone for the right activity but nothing is in
    -- actor stream (player teleported far from the obelisk after accepting
    -- the war plan), yield. Dispatch will fire Next-Obj to map-teleport us
    -- right to the obelisk; on the next pulse the actor will be in stream
    -- and we'll claim again.
    if should_fire and not has_any_entry_actor() then
        if state.pending then reset_pending(state) end
        return false
    end

    if not should_fire then
        if state.pending then reset_pending(state) end
        return false
    end

    -- Self-trigger on first match
    if not state.pending then
        state.pending          = true
        state.first_attempt_at = get_time_since_inject()
        state.last_interact_at = -math.huge
        state.last_click_at    = -math.huge
        console.print('[WarMachine] enter_undercity: started')
    end
    return true
end

task.Execute = function ()
    local now   = get_time_since_inject()
    local state = tracker.undercity.enter

    -- Total timeout
    if state.first_attempt_at and now - state.first_attempt_at > TOTAL_TIMEOUT_S then
        console.print(string.format('[WarMachine] enter_undercity: timed out after %.0fs -- aborting',
            TOTAL_TIMEOUT_S))
        reset_pending(state)
        task.status = nil
        return
    end

    -- 1. Portal already up? Walk + interact.
    local portal = interact.find_by_skin(PORTAL_SKIN, true)
    if portal then
        local r = interact.walk_and_interact(portal, INTERACT_RANGE)
        if r == 'too_far' then
            console.print('[WarMachine] enter_undercity: portal too far (unexpected)')
        end
        task.status = 'enter Undercity portal'
        return
    end

    -- 2. Tribute UI is open? Click Open Portal, then send Enter to accept
    --    the prompt that appears after.
    if menu_open() then
        local cps = settings.undercity and settings.undercity.click_points
        local op  = cps and cps.open_portal

        -- Pending Enter from a prior click? Fire it now.
        if state.send_enter_at and now >= state.send_enter_at then
            utility.send_key_press(VK_RETURN)
            console.print('[WarMachine] Send Enter to accept Open Portal prompt')
            state.send_enter_at = nil
        end

        if op and (op.x ~= 0 or op.y ~= 0) then
            if now - state.last_click_at >= OPEN_PORTAL_RETRY_S then
                console.print(string.format('[WarMachine] Click Open Portal at (%d,%d)', op.x, op.y))
                utility.send_mouse_click(op.x, op.y)
                state.last_click_at = now
                -- Schedule the Enter press for ENTER_DELAY_S later, giving
                -- the prompt time to render before we accept it.
                state.send_enter_at = now + ENTER_DELAY_S
            end
            task.status = 'Open Portal + Enter (waiting for portal)'
        else
            console.print('[WarMachine] enter_undercity: Open Portal coords not configured -- set them in the Undercity tab')
            task.status = 'Open Portal coords missing'
        end
        return
    end

    -- 3. No portal, no tribute UI -> interact with the Undercity Obelisk.
    local obelisk = interact.find_by_skin(OBELISK_SKIN, true)
    if not obelisk then
        console.print('[WarMachine] enter_undercity: Undercity Obelisk not in stream -- walk closer in Temis')
        task.status = 'Undercity Obelisk out of stream'
        return
    end

    if now - state.last_interact_at >= OBELISK_RETRY_S then
        local r = interact.walk_and_interact(obelisk, INTERACT_RANGE)
        if r == 'too_far' then
            local d = interact.distance(get_local_player(), obelisk)
            console.print(string.format('[WarMachine] enter_undercity: Undercity Obelisk %.1fy away -- aborting', d))
            reset_pending(state)
            task.status = nil
            return
        end
        state.last_interact_at = now
        task.status = 'click Undercity Obelisk (waiting for tribute UI)'
    else
        task.status = 'waiting for tribute UI'
    end
end

return task
