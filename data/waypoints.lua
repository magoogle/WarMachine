-- ---------------------------------------------------------------------------
-- data/waypoints.lua
--
-- Consolidated waypoint SNO IDs for teleport_to_waypoint().
-- Populated from Reaper/data/enums.lua (35 known waypoints) plus the
-- helltide-region IDs from HelltideRevamped/data/enums.lua.
--
-- NOTE: Skov_Temis (S07 expansion town) is NOT in this list yet — it was
-- added after these tables were compiled. Use the map-click teleport
-- (Tab + Next-Obj button) for any destination not listed here.
--
-- Usage:
--   teleport_to_waypoint(waypoints.CERRIGAR)
--   teleport_to_waypoint(waypoints.helltide_regions.Step_South.id)
-- ---------------------------------------------------------------------------

local waypoints = {
    -- ---- Sanctuary towns (from Reaper/data/enums.lua) ----
    GATES_OF_THE_NECROPOLIS  = 0x182415,
    KURAST_DOCKS             = 0x181CE3,
    SAMUK                    = 0x192273,
    KURAST_BAZAR             = 0x1EAACC,
    THE_DEN                  = 0x156710,
    GEA_KUL                  = 0xB66AB,
    IRON_WOLVES_ENCAMPMENT   = 0xDEAFC,
    IMPERIAL_LIBRARY         = 0x10D63D,
    DENSHAR                  = 0x8AF45,
    TARSARAK                 = 0x8C7B7,
    ZARBINZET                = 0xA46E5,
    JIRANDAI                 = 0x462E2,
    ALZUUDA                  = 0x792DA,
    WEJINHANI                = 0x9346B,
    RUINS_OF_RAKHAT_KEEP     = 0xF77C2,
    THE_TREE_OF_WHISPERS     = 0x90557,
    BACKWATER                = 0xA491F,
    KED_BARDU                = 0x34CE7,
    HIDDEN_OVERLOOK          = 0x460D4,
    FATES_RETREAT            = 0xEEEB3,
    FAROBRU                  = 0x2D392,
    TUR_DULRA                = 0x8D596,
    MAROWEN                  = 0x27E01,
    BRAESTAIG                = 0x7FD82,
    CERRIGAR                 = 0x76D58,
    FIREBREAK_MANOR          = 0x803EE,
    CORBACH                  = 0x22EBE,
    TIRMAIR                  = 0xB92BE,
    UNDER_THE_FAT_GOOSE_INN  = 0xEED6B,
    MENESTAD                 = 0xACE9B,
    KYOVASHAD                = 0x6CC71,
    BEAR_TRIBE_REFUGE        = 0x8234E,
    MARGRAVE                 = 0x90A86,
    YELESNA                  = 0x833F8,
    NEVESK                   = 0x6D945,
    NOSTRAVA                 = 0x8547F,

    -- ---- Helltide region anchors (from HelltideRevamped/data/enums.lua) ----
    -- Each entry maps to the in-zone waypoint nearest to the helltide spawn,
    -- the waypoint-path file name, and the path to the maiden ritual circle.
    helltide_regions = {
        Frac_Tundra_S = { id = 0xACE9B, file = 'menestad',  maiden = 'menestad_to_maiden',  region = 'Frac_' },
        Scos_Coast    = { id = 0x27E01, file = 'marowen',   maiden = 'marowen_to_maiden',   region = 'Scos_' },
        Kehj_Oasis    = { id = 0xDEAFC, file = 'ironwolfs', maiden = 'ironwolfs_to_maiden', region = 'Kehj_' },
        Hawe_Verge    = { id = 0x9346B, file = 'wejinhani', maiden = 'wejinhani_to_maiden', region = 'Hawe_' },
        Step_South    = { id = 0x462E2, file = 'jirandai',  maiden = 'jirandai_to_maiden',  region = 'Step_' },
    },
}

-- Convenience lookup: zone-name-prefix → helltide region descriptor.
-- Use to detect "which helltide am I in" by zone-name prefix.
waypoints.helltide_region_by_prefix = {}
for _, row in pairs(waypoints.helltide_regions) do
    waypoints.helltide_region_by_prefix[row.region] = row
end

return waypoints
