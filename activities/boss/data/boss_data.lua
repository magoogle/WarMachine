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

-- Boss-id -> human label + zone prefix + SNO id (for teleport_to_boss_dungeon)
-- + key_tier (which summon resource the altar consumes).  Per S12+ in-game
-- looter scans:
--   key_tier = 'greater' -> Duriel, Andariel, Harbinger, Butcher
--   key_tier = 'lower'   -> Varshan, Lord Zir, Beast in Ice, Grigoire
--   key_tier = 'husk'    -> Belial (Corrupted Vessels, separate item)
--   key_tier = 'greater' -> Urivar (assumed WT5 -> greater; verify in-game)
-- SNO ids ported from Reaper/core/map_nav.lua's BOSS_SNO table.
M.bosses = {
    { id = 'andariel',  label = 'Andariel',            zone_prefix = 'Boss_WT4_Andariel',
                                                       sno = 1807180, key_tier = 'greater' },
    { id = 'duriel',    label = 'Duriel',              zone_prefix = 'Boss_WT4_Duriel',
                                                       sno = 1496160, key_tier = 'greater' },
    { id = 'varshan',   label = 'Varshan',             zone_prefix = '_Varshan',
                                                       sno = 1496113, key_tier = 'lower' },
    { id = 'grigoire',  label = 'Grigoire',            zone_prefix = 'Boss_WT3_PenitentKnight',
                                                       sno = 1496130, key_tier = 'lower' },
    { id = 'zir',       label = 'Lord Zir',            zone_prefix = 'Boss_WT4_S2VampireLord',
                                                       sno = 1496144, key_tier = 'lower' },
    { id = 'beast',     label = 'Beast in Ice',        zone_prefix = 'Boss_WT4_MegaDemon',
                                                       sno = 1496152, key_tier = 'lower' },
    { id = 'harbinger', label = 'Harbinger of Hatred', zone_prefix = 'Boss_WT5_Harbinger',
                                                       sno = 2191385, key_tier = 'greater' },
    { id = 'urivar',    label = 'Urivar',              zone_prefix = 'Boss_WT5_Urivar',
                                                       sno = 2191378, key_tier = 'greater' },
    { id = 'belial',    label = 'Belial',              zone_prefix = 'Boss_Kehj_Belial',
                                                       sno = 2166288, key_tier = 'husk' },
    { id = 'butcher',   label = 'Bloody Butcher',      zone_prefix = 'S12_Boss_Butcher',
                                                       sno = 2553700, key_tier = 'greater' },
}

-- id -> boss table lookup
M.bosses_by_id = {}
for _, b in ipairs(M.bosses) do M.bosses_by_id[b.id] = b end

-- Summon-resource item ids (from in-game looter scans).  These replaced
-- the per-boss mats in S12.  We don't currently consume them
-- programmatically -- the altar interaction does that automatically when
-- the player has them in inventory -- but we expose the ids so a future
-- inventory-counter can drive boss selection based on what's available.
M.summon_resources = {
    lower   = 2558178,    -- Lower Lair Key  (QST_Template_Flippy_Keys_08 r=5)
    greater = 2558255,    -- Greater Lair Key (QST_Template_Flippy_Keys_08 r=6)
    husk    = 2194099,    -- Corrupted Vessel / Husk (S08_Prop_Corrupted_Vessel_Flippy r=6)
                          -- Used by Belial only.
}

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
    ['Boss_WT5_Harbinger']      = { x =   2.900, y =  15.000, z =  0.000 },
}

-- Reward-chest skin patterns.  Substring match -- chests can vary by
-- WT / season but always start with one of these prefixes.
M.chest_patterns = {
    'EGB_Chest',                   -- standard endgame boss chest
    'Boss_WT_Belial_',             -- Belial-specific chest
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

-- Given a zone name, return the boss table whose zone_prefix matches.
-- Used by select_boss to decide whether the bot is already where it
-- wants to be (no need to teleport) or in a wrong boss zone (teleport
-- to the actual target).
M.boss_for_zone = function (zone_name)
    if not zone_name then return nil end
    for _, b in ipairs(M.bosses) do
        if zone_name:find(b.zone_prefix, 1, true) then return b end
    end
    return nil
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

-- Count summon-resource items of `tier` ('greater' | 'lower' | 'husk') in
-- the player's inventory.  Returns 0 when not enumerable (no inventory
-- access, no items, etc.).  Used by open_chest to decide whether we
-- have the resource to claim the chest.
M.count_keys = function (tier)
    local lp = get_local_player()
    if not lp or not lp.get_inventory_items then return 0 end
    local target_id = M.summon_resources[tier]
    if not target_id then return 0 end
    local items = lp:get_inventory_items() or {}
    local count = 0
    for _, item in ipairs(items) do
        -- The host exposes either get_sno_id or the older get_id depending
        -- on version.  Try both; default to skin-name pattern if neither.
        local sno = nil
        if item.get_sno_id then
            local ok, v = pcall(function () return item:get_sno_id() end)
            if ok then sno = v end
        end
        if not sno and item.get_id then
            local ok, v = pcall(function () return item:get_id() end)
            if ok then sno = v end
        end
        if sno == target_id then
            -- Honor stack count when available; default to 1.
            local stack = 1
            if item.get_stack_count then
                local ok, v = pcall(function () return item:get_stack_count() end)
                if ok and type(v) == 'number' then stack = v end
            end
            count = count + stack
        end
    end
    return count
end

-- True when the player has at least one key/resource matching the given
-- boss's tier.  `boss_id` is one of the M.bosses_by_id keys.
M.has_key_for = function (boss_id)
    local b = M.bosses_by_id[boss_id]
    if not b then return false end
    return M.count_keys(b.key_tier) > 0
end

return M
