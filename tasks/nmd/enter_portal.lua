-- ---------------------------------------------------------------------------
-- tasks/nmd/enter_portal.lua
--
-- After use_sigil + map-click, an NMD portal spawns near the player.
-- This task walks to it and interacts. Once zone changes to DGN_*, the
-- supervisor takes over for in-dungeon navigation/objectives.
--
-- Triggers in BOTH:
--   • Standalone Nightmare mode (mode == NIGHTMARE)
--   • War Plan Nightmare leg if a portal is around (uncommon — war plan
--     usually teleports directly into the dungeon)
-- ---------------------------------------------------------------------------

local settings = require 'core.settings'
local mode     = require 'core.mode'
local interact = require 'core.interact'

local PORTAL_SKINS = {
    'NMD_Dungeon_Entrance_Portal',
    'DGN_Standard_Portal_Entrance',
}

local task = { name = 'nmd_enter_portal', status = nil }

local function find_portal()
    if not actors_manager then return nil end
    for _, a in pairs(actors_manager:get_all_actors()) do
        if a:is_interactable() then
            local name = a:get_skin_name()
            for _, s in ipairs(PORTAL_SKINS) do
                if name == s or name:match('NMD.*[Pp]ortal') then
                    return a
                end
            end
        end
    end
    return nil
end

task.shouldExecute = function ()
    -- Fire only when in Nightmare mode (standalone) and we're NOT yet in a DGN
    if settings.mode ~= mode.NIGHTMARE then return false end
    local zone = get_current_world() and get_current_world():get_current_zone_name() or nil
    if zone and zone:match('^DGN_') then return false end
    return find_portal() ~= nil
end

task.Execute = function ()
    local portal = find_portal()
    if not portal then
        task.status = nil
        return
    end
    local r = interact.walk_and_interact(portal, 30.0)
    if r == 'interacted' then
        task.status = 'enter NMD portal'
    elseif r == 'too_far' then
        task.status = 'NMD portal too far'
    else
        task.status = nil
    end
end

return task
