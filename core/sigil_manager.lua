-- ---------------------------------------------------------------------------
-- core/sigil_manager.lua
--
-- Reads nightmare sigils from the dungeon key inventory + stash, parses
-- their dungeon name and tier, applies user filters, picks the best one.
--
-- Ported from SigilRunner/core/sigil_manager.lua. Used by tasks/nmd/use_sigil
-- to choose which sigil to consume when entering a standalone NMD.
-- ---------------------------------------------------------------------------

local sigil_manager = {}

local TIER_PATTERNS = {
    { pattern = 'Sigil_Common',     tier = 'Common',     tier_num = 1 },
    { pattern = 'Sigil_Magic',      tier = 'Magic',      tier_num = 2 },
    { pattern = 'Sigil_Rare',       tier = 'Rare',       tier_num = 3 },
    { pattern = 'Sigil_Legendary',  tier = 'Legendary',  tier_num = 4 },
}

local function parse_dungeon_name(display_name)
    if not display_name then return nil end
    local name = display_name:match('[Ss]igil:%s*(.+)$')
    if name then return name:match('^%s*(.-)%s*$') end
    return display_name
end

local function parse_tier(skin_name)
    if not skin_name then return 'Unknown', 0 end
    for _, t in ipairs(TIER_PATTERNS) do
        if skin_name:find(t.pattern) then return t.tier, t.tier_num end
    end
    return 'Unknown', 0
end

local function is_nightmare_sigil(skin_name)
    if not skin_name then return false end
    return skin_name:find('Nightmare_Sigil') ~= nil
        or skin_name:find('S07_DRLG_Sigil') ~= nil
        or skin_name:find('S09_Prop_Astaroth_NMD') ~= nil
end

local function scan_items(items)
    local out = {}
    if not items then return out end
    for _, item in pairs(items) do
        local ok_info, info = pcall(function() return item:get_item_info() end)
        if ok_info and info then
            local ok_skin, skin = pcall(function() return info:get_skin_name() end)
            if ok_skin and skin and is_nightmare_sigil(skin) then
                local ok_disp, disp = pcall(function() return info:get_display_name() end)
                local display_name = ok_disp and disp or skin
                local ok_nm, nm = pcall(function() return info:get_name() end)
                local item_name = ok_nm and nm or skin
                local tier, tier_num = parse_tier(skin)
                local dungeon_name =
                    parse_dungeon_name(display_name) or parse_dungeon_name(item_name) or 'Unknown'
                out[#out + 1] = {
                    item         = item,
                    skin_name    = skin,
                    display_name = display_name,
                    dungeon_name = dungeon_name,
                    tier         = tier,
                    tier_num     = tier_num,
                }
            end
        end
    end
    return out
end

sigil_manager.scan = function ()
    local lp = get_local_player()
    if not lp then return {} end
    local ok, items = pcall(function() return lp:get_dungeon_key_items() end)
    return ok and scan_items(items) or {}
end

sigil_manager.scan_stash = function ()
    local lp = get_local_player()
    if not lp then return {} end
    local ok, items = pcall(function() return lp:get_stash_items() end)
    return ok and scan_items(items) or {}
end

sigil_manager.filter = function (sigils, filter_settings)
    if not filter_settings then return sigils end
    local out = {}
    for _, s in ipairs(sigils) do
        local tier_ok = true
        if filter_settings.min_tier and s.tier_num < filter_settings.min_tier then tier_ok = false end
        if filter_settings.max_tier and s.tier_num > filter_settings.max_tier then tier_ok = false end
        local blocked = false
        if filter_settings.blocked_dungeons then
            for _, b in ipairs(filter_settings.blocked_dungeons) do
                if s.dungeon_name:lower():find(b:lower()) then blocked = true; break end
            end
        end
        if tier_ok and not blocked then out[#out + 1] = s end
    end
    return out
end

sigil_manager.pick_best = function (sigils)
    if not sigils or #sigils == 0 then return nil end
    local best = sigils[1]
    for _, s in ipairs(sigils) do
        if s.tier_num > best.tier_num then best = s end
    end
    return best
end

return sigil_manager
