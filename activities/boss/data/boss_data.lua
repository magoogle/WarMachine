-- ---------------------------------------------------------------------------
-- activities/boss/data/boss_data.lua
--
-- Boss-encounter data ported from Reaper/data/enums.lua.  The skin names
-- are the canonical Blizzard internals and apply identically to standalone
-- "Boss" mode and to WarPlan boss-kill objectives.
-- ---------------------------------------------------------------------------

local M = {}

-- Altar actor skins.  Interacting with one of these summons the boss.
-- Matched as exact skin equality (not substring) -- the enum was already
-- exhaustive in Reaper, just keep it in sync here.
M.altar_skins = {
    'Boss_WT4_Varshan',
    'Boss_WT3_Varshan',
    'Boss_WT4_Duriel',
    'Boss_WT4_PenitantKnight',     -- WT4 altar (typo'd Blizzard skin -- keep both)
    'Boss_WT4_PenitentKnight',     -- WT4 altar (correct spelling)
    'Boss_WT3_PenitentKnight',     -- WT3 altar
    'Boss_WT4_Andariel',
    'Boss_WT4_MegaDemon',
    'Boss_WT4_S2VampireLord',
    'Boss_WT5_Urivar',
    'Boss_WT_Belial',
    'Boss_WT5_Harbinger',
    'Boss_EGB_Butcher',
}

-- Quick-lookup set.
M.altar_skin_set = {}
for _, n in ipairs(M.altar_skins) do M.altar_skin_set[n] = true end

-- Boss zone prefixes.  zone_matches() returns true when the current world's
-- zone name starts with / contains one of these.  Used by WarPlan zone
-- classification + the in_boss_zone() guard in api.lua.
M.zone_prefixes = {
    'Boss_WT4_Duriel',
    'Boss_WT4_Andariel',
    'Boss_WT4_PenitentKnight',     -- Grigoire WT4
    'Boss_WT3_PenitentKnight',     -- Grigoire WT3
    'Boss_WT4_S2VampireLord',      -- Lord Zir
    'Boss_WT4_MegaDemon',           -- Beast in Ice
    'Boss_WT5_Harbinger',
    'Boss_WT5_Urivar',
    'Boss_Kehj_Belial',
    'S12_Boss_Butcher',
    -- Catch-all for Varshan zones (multiple WT3/WT4 variants, plus
    -- _Eldritch / _Wretched / _Beast / _Echoing variants).
    '_Varshan',
}

-- Boss-room anchor positions for kill_monster's "stay in arena" tether.
-- Same data as Reaper enums.positions.boss_room.  Used when no enemy is
-- in range so we drift back toward the boss's spawn point instead of
-- chasing a stray pull out of the arena.
M.boss_room_anchor = {
    ['Boss_WT4_S2VampireLord']  = { x = -10.556, y = -10.419, z = -3.120 },
    ['Boss_WT4_Duriel']         = { x =  -3.616, y =  -2.309, z = -3.689 },
    ['Boss_WT3_PenitentKnight'] = { x =   2.005, y =   1.587, z =  2.000 },
    ['Boss_WT4_PenitentKnight'] = { x =   2.005, y =   1.587, z =  2.000 },
    ['Boss_WT4_Andariel']       = { x =   8.282, y =  -8.734, z = -6.223 },
    ['Boss_WT4_MegaDemon']      = { x =   4.924, y =   5.308, z =  0.127 },
    ['_Varshan']                = { x =  -3.280, y =  -3.194, z = -3.304 },
    ['Boss_WT5_Harbinger']      = { x =   0.930, y =  16.180, z =  0.000 },
}

-- Reward-chest skin patterns.  Substring match -- chests can vary by
-- WT / season but always start with one of these prefixes.
M.chest_patterns = {
    'EGB_Chest',                   -- standard endgame boss chest
    'Boss_WT_Belial_',             -- Belial-specific chest
    'S12_Prop_Theme_Chest_',       -- Season 12 theme chest (DOOM)
    'Chest_Boss',                  -- generic boss chest fallback
}

-- Cerrigar waypoint -- used as the safe-fallback teleport when a run gets
-- stuck (mirrors Reaper's CERRIGAR_WP).
M.CERRIGAR_WAYPOINT_ID = 0x76D58
M.CERRIGAR_ZONE        = 'Scos_Cerrigar'

-- Misc skins
M.suppressor_skin = 'monsterAffix_suppressor_barrier'
M.town_portal_skin = 'TownPortal'

-- ---------------------------------------------------------------------------
-- Helpers used by tasks
-- ---------------------------------------------------------------------------

-- True when `zone_name` matches any boss_zone prefix or contains a Varshan-
-- variant fragment.  Activity api.shouldExecute uses this to decide whether
-- the bot should be running boss-kill logic.
M.zone_matches = function (zone_name)
    if not zone_name or zone_name == '' then return false end
    for _, p in ipairs(M.zone_prefixes) do
        if zone_name:find(p, 1, true) then return true end
    end
    return false
end

-- Best anchor position for the current zone.  Falls back to (0,0,0) when
-- we don't have a hard-coded room (e.g. Belial / Butcher / new bosses).
-- Returns a vec3-shaped table; caller wraps in vec3 if needed.
M.get_anchor = function (zone_name)
    if not zone_name then return nil end
    -- Direct hit
    if M.boss_room_anchor[zone_name] then return M.boss_room_anchor[zone_name] end
    -- Substring fallback (the _Varshan family + similar)
    for prefix, pos in pairs(M.boss_room_anchor) do
        if zone_name:find(prefix, 1, true) then return pos end
    end
    return nil
end

-- True when the actor's skin is the summon altar for the boss in this zone.
M.is_altar = function (actor)
    if not actor or not actor.get_skin_name then return false end
    local sn = actor:get_skin_name()
    return sn and M.altar_skin_set[sn] == true
end

-- True when the actor is one of the post-kill reward chests.
M.is_reward_chest = function (actor)
    if not actor or not actor.get_skin_name then return false end
    local sn = actor:get_skin_name() or ''
    for _, p in ipairs(M.chest_patterns) do
        if sn:find(p, 1, true) then return true end
    end
    return false
end

return M
