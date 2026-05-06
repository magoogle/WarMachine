-- ---------------------------------------------------------------------------
-- activities/helltide/settings.lua  --  binds to WarMachine GUI elements.
--
-- The actual checkboxes/sliders are declared in WarMachine/gui.lua under
-- the 'Helltide settings' tree.  This module just snapshots their values
-- into a flat table the helltide tasks can read without going through the
-- elements API every time.
-- ---------------------------------------------------------------------------

local gui = require 'gui'

local M = {
    -- POI toggles (which interactables to consume during a run)
    do_chests        = true,
    do_silent_chests = true,
    do_ores          = true,
    do_herbs         = true,
    do_shrines       = true,
    do_pyres         = true,
    do_goblins       = true,
    do_events        = true,
    do_chaos_rifts   = true,

    -- Combat tuning
    kill_monsters    = true,
    kill_range       = 25,

    -- (farm_cinder_threshold dropped: with WarPath catalog, the priority
    -- queue automatically picks the closest affordable chest each pulse;
    -- no explicit "circle this chest while topping up" mode needed.)

    -- Maiden event
    do_maiden        = true,

    -- Mount toggle (driven by core/mount_manager.lua at the WarMachine level)
    auto_mount       = true,

    -- Run-loop watchdog: if helltide buff drops mid-run (e.g. reset), wait
    -- this many seconds before giving up on the current zone.
    leave_zone_grace = 30,

    -- Loot grace after a chest opens.  While this timer runs, nav stays
    -- paused so the player stands still and Looteer (or any auto-pickup
    -- plugin) can vacuum the drops.  Without this the priority queue
    -- handed back the next POI the moment the chest went non-interactable
    -- and the bot walked off mid-loot.
    chest_grace_secs = 4,

    -- Debug
    debug_mode       = false,
}

M.update = function ()
    if not gui.elements then return end
    -- Optional helltide tree -- if WarMachine GUI hasn't added its helltide
    -- section yet (early-load race), tolerate missing elements gracefully.
    local e = gui.elements
    local function bget(k, d) if e[k] then return e[k]:get() end; return d end
    M.do_chests          = bget('helltide_do_chests',        true)
    M.do_silent_chests   = bget('helltide_do_silent_chests', true)
    M.do_ores            = bget('helltide_do_ores',          true)
    M.do_herbs           = bget('helltide_do_herbs',         true)
    M.do_shrines         = bget('helltide_do_shrines',       true)
    M.do_pyres           = bget('helltide_do_pyres',         true)
    M.do_goblins         = bget('helltide_do_goblins',       true)
    M.do_events          = bget('helltide_do_events',        true)
    M.do_chaos_rifts     = bget('helltide_do_chaos_rifts',   true)
    M.kill_monsters      = bget('helltide_kill_monsters',    true)
    M.do_maiden          = bget('helltide_do_maiden',        true)
    M.auto_mount         = bget('helltide_auto_mount',       true)
    M.kill_range         = bget('helltide_kill_range',       25)
    M.leave_zone_grace   = bget('helltide_leave_zone_grace', 30)
    M.chest_grace_secs   = bget('helltide_chest_grace_secs',  4)
    -- Debug mode is shared with WarMachine's master debug toggle
    M.debug_mode         = bget('debug_mode',                false)
end

return M
