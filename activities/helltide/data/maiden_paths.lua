-- ---------------------------------------------------------------------------
-- activities/helltide/data/maiden_paths.lua
--
-- Town-to-helltide-ring waypoint paths.  When WarPlan TPs us to a
-- helltide it lands us at the nearest TOWN waypoint; we then need to
-- walk out of the town and into the helltide ring.  These paths drive
-- that walk.
--
-- Source: the legacy HelltideRevamped plugin shipped pre-recorded
-- vec3 lists from each town's waypoint to the maiden ritual brazier.
-- We require them here at runtime if the folder is on disk; that
-- avoids duplicating the data into WarMachine while still letting us
-- use them when available.  If HelltideRevamped isn't installed,
-- the corresponding entries return nil and the bot falls back to the
-- catalog-seed / explorer behavior.
--
-- Returned shape: { ['Scos_Cerrigar'] = { vec3, vec3, ... }, ... }
-- ---------------------------------------------------------------------------

-- Town zone -> path module.  Path module names match the legacy
-- HelltideRevamped/waypoints/ filenames.
local TOWN_TO_PATH_MODULE = {
    -- Scos_*: Cerrigar -> Marowen helltide
    ['Scos_Cerrigar']  = 'helltide_revamped.waypoints.marowen_to_maiden',
    -- Frac_*: Kyovashad -> Menestad helltide
    ['Frac_Kyovashad'] = 'helltide_revamped.waypoints.menestad_to_maiden',
    -- Kehj_*: any Kehjistan town -> Iron Wolves Encampment helltide
    ['Kehj_Gea_Kul']      = 'helltide_revamped.waypoints.ironwolfs_to_maiden',
    ['Kehj_KurastBazaar'] = 'helltide_revamped.waypoints.ironwolfs_to_maiden',
    ['Kehj_KurastDocks']  = 'helltide_revamped.waypoints.ironwolfs_to_maiden',
    -- Hawe_*: Tree of Whispers -> Wejinhani helltide
    ['Hawe_TreeOfWhispers'] = 'helltide_revamped.waypoints.wejinhani_to_maiden',
    -- Step_*: Backwater / Margrave -> Jirandai helltide
    ['Step_Backwater'] = 'helltide_revamped.waypoints.jirandai_to_maiden',
    ['Step_Margrave']  = 'helltide_revamped.waypoints.jirandai_to_maiden',
}

local M = {}

-- Cache of loaded paths so we don't re-require on every shouldExecute.
-- nil means "not yet attempted"; false means "tried, not available";
-- a table means the loaded path.
local _cache = {}

-- Returns the waypoint path (array of vec3) for the given town zone, or
-- nil if either we don't have a mapping or the legacy plugin isn't
-- installed.  Cached after the first lookup per zone.
M.path_for_zone = function (zone_name)
    if not zone_name then return nil end
    local cached = _cache[zone_name]
    if cached == false then return nil end
    if cached then return cached end

    local mod_name = TOWN_TO_PATH_MODULE[zone_name]
    if not mod_name then
        _cache[zone_name] = false
        return nil
    end

    local ok, path = pcall(require, mod_name)
    if not ok or type(path) ~= 'table' or #path == 0 then
        _cache[zone_name] = false
        return nil
    end
    _cache[zone_name] = path
    return path
end

-- All zone -> mod names (for diagnostics / debug GUI).
M.TOWN_TO_PATH_MODULE = TOWN_TO_PATH_MODULE

return M
