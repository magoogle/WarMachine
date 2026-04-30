-- activities/hordes/settings.lua

local gui = require 'gui'

local M = {
    kill_monsters       = true,
    -- Horde arena is large; the default 25 was leaving boss + late-wave
    -- spawns out of range, so the bot would idle in the center while
    -- enemies milled around the edges.  60 covers the full arena radius.
    kill_range          = 60,

    -- Pylon (boon) selection.  When the choice screen pops up between waves
    -- we have ~10 seconds to pick one of three.  Default: pick the
    -- highest-priority one available, falling back to the first if none
    -- match.  See pylon_priority.lua for the ordered preference list.
    do_pylons           = true,
    pylon_pick_timeout  = 8,    -- s; bail to default if no preferred pylon detected

    do_aether_structures = true, -- BSK_Structure_BonusAether spawn loot

    -- End-of-run flow
    do_boss_portals     = true,   -- click Bartuc/Council pylon after waves clear
    prefer_bartuc       = false,  -- pick Bartuc when both portals are visible
    do_chests           = true,   -- master toggle (off = skip chest phase entirely)
    -- Per-chest-type toggles, processed in priority order GA -> Equipment
    -- -> Materials -> Gold.  Aether is finite per run; the bot tries the
    -- highest-priority enabled chest first, falls through to the next
    -- when a click is rejected (insufficient aether).
    do_chest_ga         = true,   -- BSK_UniqueOpChest_GreaterAffix
    do_chest_equipment  = true,   -- BSK_UniqueOpChest_Equipment
    do_chest_materials  = false,  -- BSK_UniqueOpChest_Materials
    do_chest_gold       = false,  -- BSK_UniqueOpChest_Gold

    auto_reset_after    = 1500,
    -- auto_mount removed: horde arena is small + constant combat.
    -- Helltide is the only activity exposing the mount option.

    debug_mode          = false,
}

M.update = function ()
    if not gui.elements then return end
    local e = gui.elements
    local function bget(k, d) if e[k] then return e[k]:get() end; return d end
    M.kill_monsters       = bget('hordes_kill_monsters',       true)
    M.kill_range          = bget('hordes_kill_range',          60)
    M.do_pylons           = bget('hordes_do_pylons',           true)
    M.pylon_pick_timeout  = bget('hordes_pylon_pick_timeout',  8)
    M.do_aether_structures = bget('hordes_do_aether_structures', true)
    M.do_boss_portals      = bget('hordes_do_boss_portals',      true)
    M.prefer_bartuc        = bget('hordes_prefer_bartuc',        false)
    M.do_chests            = bget('hordes_do_chests',            true)
    M.do_chest_ga          = bget('hordes_do_chest_ga',          true)
    M.do_chest_equipment   = bget('hordes_do_chest_equipment',   true)
    M.do_chest_materials   = bget('hordes_do_chest_materials',   false)
    M.do_chest_gold        = bget('hordes_do_chest_gold',        false)
    M.auto_reset_after    = bget('hordes_auto_reset_after',    1500)
    M.debug_mode          = bget('debug_mode',                 false)
end

return M
