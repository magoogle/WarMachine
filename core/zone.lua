-- ---------------------------------------------------------------------------
-- core/zone.lua
--
-- Zone-classification helpers shared across activity tasks.  Pulled out
-- of the per-task copies of `in_dungeon()`, `current_zone()`, etc. so
-- there's one source of truth and no per-file drift when zone-name
-- conventions change between seasons.
--
-- Usage:
--   local zone = require 'core.zone'
--   if zone.in_dungeon() then ... end
--   local z = zone.current() or '<none>'
-- ---------------------------------------------------------------------------

local M = {}

-- Major-town zone names.  Used by core/whispers.lua + town-piggyback
-- tasks.  Over-inclusive on purpose: gating tasks always also check for
-- the relevant actor in stream.
local TOWN_ZONES = {
    ['Scos_Cerrigar']        = true,
    ['Frac_Kyovashad']       = true,
    ['Step_Backwater']       = true,
    ['Step_Margrave']        = true,
    ['Hawe_TreeOfWhispers']  = true,
    ['Skov_Temis']           = true,
    ['Kehj_Gea_Kul']         = true,
    ['Kehj_KurastBazaar']    = true,
    ['Kehj_KurastDocks']     = true,
}

-- Returns the current zone name, or nil if not available.
M.current = function ()
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return nil end
    return w:get_current_zone_name()
end

-- Returns the current world id, or nil.  Used by floor-portal detection
-- to spot world transitions.
M.current_world_id = function ()
    local w = get_current_world()
    return w and w.get_world_id and w:get_world_id() or nil
end

-- True when the current zone name starts with `DGN_` -- the canonical
-- D4 prefix for nightmare-dungeon / story-dungeon zones.
M.in_dungeon = function ()
    local z = M.current()
    return z and z:sub(1, 4) == 'DGN_' or false
end

-- True when the current zone is one of the recognized major towns.
M.in_town = function ()
    local z = M.current()
    return z and TOWN_ZONES[z] == true or false
end

-- True when the current zone matches the Pit's `PIT_` prefix.
M.in_pit = function ()
    local z = M.current()
    return z and z:sub(1, 4) == 'PIT_' or false
end

-- Pit floor descent uses world-id transitions (within the same `PIT_*`
-- zone) instead of zone-name changes.  Helper kept here so floor_portal
-- doesn't reimplement the world-id read.
M.zone_starts_with = function (prefix)
    local z = M.current()
    return z and z:sub(1, #prefix) == prefix or false
end

-- Read-only export for callers that want to extend the town list at
-- runtime.  Mutating this table mutates M's behavior across the board.
M.town_zones = TOWN_ZONES

return M
