-- activities/hordes/settings.lua

local gui = require 'gui'

local M = {
    kill_monsters       = true,
    -- Horde arena (Realm of Hatred) is one big open room; the bot needs
    -- to "see" objectives across the entire floor (spires, aether masses,
    -- BSK_Structure_BonusAether spawns, MarkerLocation_BSK_* triggers).
    -- 25 was way too small (only nearby mobs); 60 covered the radius
    -- but missed the diagonal corners.  100 covers the full corner-to-
    -- corner diagonal so we always pick up the wave's progression-gating
    -- objectives even when they spawn on the far side.
    kill_range          = 100,

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
    -- Per-chest-type config:
    --   do_chest_ga       -- BSK_UniqueOpChest_GreaterAffix.  Top priority,
    --                        attempted first.  Costs the most aether.
    --   chest_secondary   -- 'None' | 'Materials' | 'Gold'.  After GA
    --                        either succeeds or runs out of aether, the
    --                        bot opens THIS chest as the secondary pick.
    --                        Materials and Gold are MUTUALLY EXCLUSIVE
    --                        (you can only afford one) -- exposed as a
    --                        dropdown in the GUI rather than two
    --                        independent checkboxes.
    do_chest_ga         = true,
    chest_secondary     = 'None', -- combobox value: 'None' / 'Materials' / 'Gold'

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
    -- Combobox `hordes_chest_secondary` -- index 0=None, 1=Materials, 2=Gold.
    -- Map back to the human-readable string the open_chest task expects.
    local idx = bget('hordes_chest_secondary', 0)
    if idx == 1 then
        M.chest_secondary = 'Materials'
    elseif idx == 2 then
        M.chest_secondary = 'Gold'
    else
        M.chest_secondary = 'None'
    end
    M.auto_reset_after    = bget('hordes_auto_reset_after',    1500)
    M.debug_mode          = bget('debug_mode',                 false)
end

return M
