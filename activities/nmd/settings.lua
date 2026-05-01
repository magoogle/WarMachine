-- activities/nmd/settings.lua

local gui = require 'gui'

local M = {
    kill_monsters     = true,
    kill_range        = 25,
    boss_intro_delay  = 3,

    do_chests         = true,
    do_shrines        = true,
    do_objectives     = true,    -- pedestals/levers/doors that gate progression
    do_cursed_shrines = true,    -- click cursed shrines mid-run to spawn the
                                 -- mob wave + reward chest.  When false, the
                                 -- bot walks past them without clicking; if
                                 -- a shrine was already activated by accident
                                 -- (e.g. proximity trigger in some seasons)
                                 -- the existing kill_monster + loot_chest
                                 -- pipeline still finishes it.
    do_events         = true,    -- engage with local events: LE_Ambush
                                 -- (speak-to-survivor, then survive waves),
                                 -- DE_* / DSQ_* (walk into trigger zone,
                                 -- mobs spawn, kill them all).  When false,
                                 -- the ambush/event-handler task is dormant
                                 -- and the bot walks past event triggers
                                 -- without engaging.  kill_monster still
                                 -- fires for any mobs that aggro.

    auto_reset_after  = 900,     -- s; NMDs can run longer than pits
    exit_after_boss   = true,

    -- auto_mount removed: dungeon corridors + combat density make
    -- mount churn a net loss.  Helltide is the only activity exposing
    -- the mount option.

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
    M.do_cursed_shrines = bget('nmd_do_cursed_shrines', true)
    M.do_events         = bget('nmd_do_events',         true)
    M.auto_reset_after = bget('nmd_auto_reset_after', 900)
    M.exit_after_boss  = bget('nmd_exit_after_boss',  true)
    M.debug_mode       = bget('debug_mode',           false)
end

return M
