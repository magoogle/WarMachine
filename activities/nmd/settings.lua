-- activities/nmd/settings.lua

local gui = require 'gui'

local M = {
    kill_monsters     = true,
    kill_range        = 25,
    boss_intro_delay  = 3,

    do_chests         = true,
    do_shrines        = true,
    do_objectives     = true,    -- pedestals/levers/doors that gate progression

    auto_reset_after  = 900,     -- s; NMDs can run longer than pits
    exit_after_boss   = true,

    auto_mount        = true,

    debug_mode        = false,
}

M.update = function ()
    if not gui.elements then return end
    local e = gui.elements
    local function bget(k, d) if e[k] then return e[k]:get() end; return d end
    M.kill_monsters    = bget('nmd_kill_monsters',    true)
    M.kill_range       = bget('nmd_kill_range',       25)
    M.boss_intro_delay = bget('nmd_boss_intro_delay', 3)
    M.do_chests        = bget('nmd_do_chests',        true)
    M.do_shrines       = bget('nmd_do_shrines',       true)
    M.do_objectives    = bget('nmd_do_objectives',    true)
    M.auto_reset_after = bget('nmd_auto_reset_after', 900)
    M.exit_after_boss  = bget('nmd_exit_after_boss',  true)
    M.auto_mount       = bget('nmd_auto_mount',       true)
    M.debug_mode       = bget('debug_mode',           false)
end

return M
