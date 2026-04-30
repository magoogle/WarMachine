-- ---------------------------------------------------------------------------
-- activities/pit/settings.lua
--
-- Per-pit settings, snapshotted from the WarMachine GUI's "Pit settings"
-- tree.  Tasks read this flat table without going through gui.elements
-- every pulse.
-- ---------------------------------------------------------------------------

local gui = require 'gui'

local M = {
    -- Combat
    kill_monsters    = true,
    kill_range       = 25,
    boss_intro_delay = 3,    -- seconds to hold attack after a boss appears
                              -- so cinematics finish; matches ArkhamAsylum's
                              -- legacy boss_delay setting

    -- Run pacing
    auto_reset_after = 600,   -- seconds; safety net if a run gets stuck
    exit_after_chest = true,  -- warp out as soon as the attunement chest is looted

    -- POI toggles
    do_chests        = true,  -- attunement chest at end of run
    do_shrines       = true,
    interact_glyph   = true,  -- post-boss glyph upgrade gizmo

    -- Pit level (1-150).  WarPlan ignores this and uses whatever the
    -- vendor selected; standalone mode opens this level via the Pit-key
    -- Crafter at the start of each run.
    level            = 60,

    -- Mount toggle (via core/mount_manager.lua)
    auto_mount       = true,

    debug_mode       = false,
}

M.update = function ()
    if not gui.elements then return end
    local e = gui.elements
    local function bget(k, d) if e[k] then return e[k]:get() end; return d end
    M.kill_monsters    = bget('pit_kill_monsters',    true)
    M.kill_range       = bget('pit_kill_range',       25)
    M.boss_intro_delay = bget('pit_boss_intro_delay', 3)
    M.auto_reset_after = bget('pit_auto_reset_after', 600)
    M.exit_after_chest = bget('pit_exit_after_chest', true)
    M.do_chests        = bget('pit_do_chests',        true)
    M.do_shrines       = bget('pit_do_shrines',       true)
    M.interact_glyph   = bget('pit_interact_glyph',   true)
    M.level            = bget('pit_level',            60)
    M.auto_mount       = bget('pit_auto_mount',       true)
    M.debug_mode       = bget('debug_mode',           false)
end

return M
