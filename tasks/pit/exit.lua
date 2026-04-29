-- ---------------------------------------------------------------------------
-- tasks/pit/exit.lua
--
-- Detects pit-completion conditions and exits via either:
--   • Reset Dungeons     (settings.pit.exit_mode == 0)
--   • teleport_to_waypoint(CERRIGAR)  (settings.pit.exit_mode == 1)
--
-- Exit triggers (any one):
--   • Reset timeout exceeded (settings.pit.reset_timeout)
--   • Glyph upgrade gizmo appeared in stream (boss is dead)
--   • BatmobilePlugin.is_done() — no more frontiers / fully explored
--
-- Ported from ArkhamAsylum-1.0.6/tasks/exit_pit.lua. Removed party_mode +
-- d4assistant branches — those are out-of-scope for v0.1.
-- ---------------------------------------------------------------------------

local settings  = require 'core.settings'
local tracker   = require 'core.tracker'
local mode      = require 'core.mode'
local waypoints = require 'data.waypoints'

local GLYPH_GIZMO_SKIN = 'Gizmo_Paragon_Glyph_Upgrade'
local EXIT_DELAY_S     = 5.0   -- linger this long after trigger so loot can drop / be picked up

local task = { name = 'pit_exit', status = nil }

local function in_pit()
    local w = get_current_world()
    if not w then return false end
    local n = w:get_name()
    return n ~= nil and n:match('^PIT_') ~= nil
end

local function find_glyph_gizmo()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a:get_skin_name() == GLYPH_GIZMO_SKIN then return a end
    end
    return nil
end

local function elapsed_in_pit()
    if tracker.pit.start_time and tracker.pit.start_time > 0 then
        return get_time_since_inject() - tracker.pit.start_time
    end
    return 0
end

local function should_exit()
    if not in_pit() then return false end
    -- Reset timeout exceeded?
    local timeout = (settings.pit and settings.pit.reset_timeout) or 600
    if elapsed_in_pit() > timeout then return true, 'reset timeout' end
    -- Glyph gizmo means the boss has been killed and the run is done
    if find_glyph_gizmo() then
        tracker.pit.glyph_gizmo_seen = true
        return true, 'glyph gizmo spotted'
    end
    -- Batmobile reports fully explored
    if BatmobilePlugin and BatmobilePlugin.is_done and BatmobilePlugin.is_done() then
        return true, 'batmobile done'
    end
    return false
end

task.shouldExecute = function ()
    if settings.mode ~= mode.PIT then return false end
    local exit, _reason = should_exit()
    return exit
end

task.Execute = function ()
    local now = get_time_since_inject()
    BatmobilePlugin.pause('warmachine')

    -- Mark the trigger time so we can apply EXIT_DELAY_S
    if tracker.pit.exit_trigger_time == nil then
        local _, reason = should_exit()
        tracker.pit.exit_trigger_time = now
        console.print('[WarMachine] pit: exit triggered (' .. tostring(reason) .. ')')
    end

    local since = now - tracker.pit.exit_trigger_time
    if since < EXIT_DELAY_S then
        task.status = string.format('exit grace %.1fs', EXIT_DELAY_S - since)
        return
    end

    -- Time to actually exit
    local mode_n = (settings.pit and settings.pit.exit_mode) or 1
    if mode_n == 1 then
        console.print('[WarMachine] pit: teleport_to_waypoint(CERRIGAR)')
        teleport_to_waypoint(waypoints.CERRIGAR)
    else
        console.print('[WarMachine] pit: reset_all_dungeons()')
        reset_all_dungeons()
    end

    -- Reset run state for the next pit
    tracker.pit.start_time        = -1
    tracker.pit.exit_trigger_time = nil
    tracker.pit.glyph_gizmo_seen  = false
    task.status = 'exited'
end

return task
