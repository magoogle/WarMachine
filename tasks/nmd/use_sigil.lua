-- ---------------------------------------------------------------------------
-- tasks/nmd/use_sigil.lua
--
-- Standalone Nightmare mode entry sequence (ported from
-- SigilRunner/tasks/start_dungeon.lua):
--
--   1. Scan inventory for a usable sigil (filtered by tier settings)
--   2. loot_manager.use_item(sigil)         — activate it
--   3. utility.confirm_sigil_notification() — accept the consume dialog
--   4. send_key_press('M')                   — open the world map
--   5. send_mouse_click(map_x, map_y)        — click the dungeon entrance icon
--   6. send_key_press('M')                   — close the map
--   7. Wait for NMD_Dungeon_Entrance_Portal to spawn
--
-- After the portal appears, tasks/nmd/enter_portal handles the walk-in.
-- If no usable sigils, sets tracker.nmd.use_sigil.need_sigils = true so a
-- future restock task (TBD) can fire.
-- ---------------------------------------------------------------------------

local settings       = require 'core.settings'
local tracker        = require 'core.tracker'
local mode           = require 'core.mode'
local sigil_manager  = require 'core.sigil_manager'

local CONFIRM_DELAY  = 0.8
local MAP_OPEN_DELAY = 0.8
local MAP_CLICK_DELAY = 0.6
local PORTAL_TIMEOUT = 90.0

local task = { name = 'nmd_use_sigil', status = nil }

local function set_step(s, label)
    local state = tracker.nmd.use_sigil
    state.step      = s
    state.step_time = get_time_since_inject()
    task.status     = label or s
end

local function step_elapsed()
    return get_time_since_inject() - tracker.nmd.use_sigil.step_time
end

local function reset_state()
    local state = tracker.nmd.use_sigil
    state.pending           = false
    state.step              = 'idle'
    state.step_time         = -1
    state.selected_sigil    = nil
    state.portal_wait_start = -1
    task.status             = nil
end

local function get_dungeon_portal()
    if not actors_manager then return nil end
    for _, actor in pairs(actors_manager:get_all_actors()) do
        if actor:is_interactable() then
            local name = actor:get_skin_name()
            if name == 'NMD_Dungeon_Entrance_Portal'
               or name == 'DGN_Standard_Portal_Entrance'
               or name:match('NMD.*[Pp]ortal') then
                return actor
            end
        end
    end
    return nil
end

local function in_dungeon()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    return zone and zone:match('^DGN_') ~= nil
end

local function in_a_town()
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    if not zone then return false end
    -- Treat any non-DGN, non-X1_Undercity zone with a Waypoint actor as town-like.
    -- More robust: explicit list of known towns.
    if zone:match('^DGN_') then return false end
    if zone:match('^X1_Undercity_') then return false end
    return true   -- assume any other zone is over/town and acceptable
end

task.shouldExecute = function ()
    if settings.mode ~= mode.NIGHTMARE then return false end
    if not settings.nmd.auto_use_sigil then return false end
    if in_dungeon() then return false end
    if get_dungeon_portal() ~= nil then return false end
    if tracker.nmd.use_sigil.need_sigils then return false end
    if not in_a_town() then return false end

    -- Self-trigger when conditions match
    if not tracker.nmd.use_sigil.pending then
        tracker.nmd.use_sigil.pending = true
        set_step('idle', 'starting')
    end
    return true
end

task.Execute = function ()
    local state = tracker.nmd.use_sigil
    BatmobilePlugin.pause('warmachine')

    -- Portal already spawned? Done.
    if get_dungeon_portal() ~= nil then
        console.print('[WarMachine] use_sigil: portal spawned, handing off to enter_portal')
        reset_state()
        return
    end

    if state.step == 'idle' then
        -- Scan and filter sigils
        local sigils = sigil_manager.scan()
        local filter = {
            min_tier = settings.nmd.min_tier > 0 and settings.nmd.min_tier or nil,
            max_tier = settings.nmd.max_tier > 0 and settings.nmd.max_tier or nil,
        }
        local usable = sigil_manager.filter(sigils, filter)
        if #usable == 0 then
            console.print('[WarMachine] use_sigil: no usable sigils — set need_sigils')
            state.need_sigils = true
            reset_state()
            return
        end
        state.selected_sigil = sigil_manager.pick_best(usable)
        console.print(string.format('[WarMachine] use_sigil: using %s (%s)',
            state.selected_sigil.dungeon_name, state.selected_sigil.tier))

        local ok, err = pcall(function()
            if loot_manager and loot_manager.use_item then
                loot_manager.use_item(state.selected_sigil.item)
            else
                use_item(state.selected_sigil.item)
            end
        end)
        if not ok then
            console.print('[WarMachine] use_sigil: use_item failed -> ' .. tostring(err))
            reset_state()
            return
        end
        set_step('consuming', 'consuming sigil')
        return
    end

    if state.step == 'consuming' then
        if step_elapsed() < CONFIRM_DELAY then return end
        local ok = pcall(function()
            if utility and utility.confirm_sigil_notification then
                utility.confirm_sigil_notification()
            end
        end)
        if ok then console.print('[WarMachine] use_sigil: confirm_sigil_notification fired') end
        set_step('confirming', 'confirming')
        return
    end

    if state.step == 'confirming' then
        if step_elapsed() < MAP_OPEN_DELAY then return end
        utility.send_key_press(string.byte('M'))
        console.print('[WarMachine] use_sigil: map opened')
        set_step('opening_map', 'opening map')
        return
    end

    if state.step == 'opening_map' then
        if step_elapsed() < MAP_CLICK_DELAY then return end
        local mc = settings.nmd.map_click
        if not mc or mc.x <= 0 or mc.y <= 0 then
            console.print('[WarMachine] use_sigil: Map NMD click point not configured — set Map NMD X/Y in settings')
            utility.send_key_press(string.byte('M'))   -- close map
            reset_state()
            return
        end
        utility.send_mouse_click(mc.x, mc.y)
        console.print(string.format('[WarMachine] use_sigil: map clicked at (%d,%d)', mc.x, mc.y))
        utility.send_key_press(string.byte('M'))       -- close map
        state.portal_wait_start = get_time_since_inject()
        set_step('waiting', 'waiting for portal')
        return
    end

    if state.step == 'waiting' then
        local elapsed = get_time_since_inject() - state.portal_wait_start
        if elapsed > PORTAL_TIMEOUT then
            console.print('[WarMachine] use_sigil: portal timeout — retrying')
            reset_state()
            return
        end
        task.status = string.format('waiting for portal (%.0fs)', PORTAL_TIMEOUT - elapsed)
        return
    end
end

return task
