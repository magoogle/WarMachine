-- ---------------------------------------------------------------------------
-- activities/pit/tasks/enter_pit.lua
--
-- Standalone-mode entry: walk to the Pit-key Crafter in Skov_Temis, click
-- it, click the configured pit level, walk into the spawned portal.
-- Mirrors WarMachine/tasks/pit/enter.lua but runs from the activity's own
-- task list in standalone mode (warplan mode uses the existing
-- WarMachine task and this one yields).
--
-- Yielded entirely when:
--   * settings.warplan.snapshot is active (warplan supervisor drives entry)
--   * we're not in a hub town
-- ---------------------------------------------------------------------------

local move       = require 'core.move'
local settings   = require 'activities.pit.settings'
local tracker    = require 'activities.pit.tracker'
-- Tier (1..150) -> SNO map.  utility.open_pit_portal(...) takes the
-- portal asset's SNO ID, NOT the tier number -- they're not the same
-- value.  See data/pit_levels.lua for the full mapping (e.g. tier 51
-- -> 0x1C3554, tier 100 -> 0x1C35C1).
local pit_levels = require 'data.pit_levels'

local CRAFTER_SKIN = 'TWN_Kehj_IronWolves_PitKey_Crafter'
local PORTAL_SKIN  = 'EGD_MSWK_World_Portal_01'

local task = { name = 'enter_pit', status = 'idle', debounce_t = -1 }

local function in_pit_hub()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return false end
    return w:get_current_zone_name() == 'Skov_Temis'
end

local function in_pit()
    local w = get_current_world()
    if not w or not w.get_name then return false end
    local n = w:get_name()
    return n and n:sub(1, 4) == 'PIT_'
end

local function find_actor(skin, require_interactable)
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_ally_actors()) do
        if a:get_skin_name() == skin then
            if not require_interactable or (a.is_interactable and a:is_interactable()) then
                return a
            end
        end
    end
    return nil
end

local function menu_open()
    return loot_manager and loot_manager.is_in_vendor_screen
       and (pcall(loot_manager.is_in_vendor_screen) and loot_manager:is_in_vendor_screen())
end

task.shouldExecute = function ()
    -- Standalone only: skip if in pit (in-run flow takes over) or not in hub
    if in_pit() then return false end
    return in_pit_hub()
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    -- 1. Portal already open?  Walk in.
    local portal = find_actor(PORTAL_SKIN, true)
    if portal then
        local p = portal:get_position()
        local d = math.sqrt((p:x()-pp:x())^2 + (p:y()-pp:y())^2)
        if d <= 2 then
            tracker.reset_run()
            interact_object(portal)
            task.status = 'entering pit'
        else
            move.to_actor(portal)
            task.status = string.format('walking to portal (%.0fm)', d)
        end
        return
    end

    -- 2. Crafter menu open?  Trigger pit level open.
    if menu_open() then
        local now = get_time_since_inject() or 0
        if task.debounce_t > 0 and (task.debounce_t + 1.5) > now then
            task.status = 'waiting for portal spawn'
            return
        end
        if utility and utility.open_pit_portal then
            -- Translate the GUI's tier (1..150) into the SNO the host
            -- API actually consumes.  Passing the raw tier silently no-
            -- ops the call -- the bot interacts with the obelisk, the
            -- menu opens, but no portal spawns.  Mirrors the WarPlan-
            -- side path in tasks/pit/enter.lua.
            local addr = pit_levels[settings.level]
            if not addr then
                task.status = 'invalid pit level ' .. tostring(settings.level)
                return
            end
            local ok = pcall(utility.open_pit_portal, addr)
            task.debounce_t = now
            task.status = ok
                and string.format('opening pit %d (sno=0x%X)', settings.level, addr)
                or  'open_pit_portal failed'
        else
            task.status = 'utility.open_pit_portal not available'
        end
        return
    end

    -- 3. Walk to Pit-key Crafter and click it.
    local crafter = find_actor(CRAFTER_SKIN, false)
    if not crafter then
        task.status = 'no Pit-key Crafter in stream'
        return
    end
    local cp = crafter:get_position()
    local cd = math.sqrt((cp:x()-pp:x())^2 + (cp:y()-pp:y())^2)
    if cd > 3 then
        move.to_actor(crafter)
        task.status = string.format('walking to crafter (%.0fm)', cd)
    else
        interact_object(crafter)
        task.status = 'opening crafter menu'
    end
end

return task
