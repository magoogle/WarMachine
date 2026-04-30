-- ---------------------------------------------------------------------------
-- activities/undercity/settings.lua
-- ---------------------------------------------------------------------------

local gui = require 'gui'

local M = {
    kill_monsters     = true,
    kill_range        = 25,
    boss_intro_delay  = 3,

    do_chests         = true,
    do_enticements    = true,    -- spirit beacons + hearths
    max_hearths       = 4,        -- hard cap on SpiritHearth_Switch interactions
    enticement_timeout = 4,       -- s; stop waiting at a beacon after this

    -- Run pacing
    auto_reset_after  = 600,
    exit_after_chest  = true,

    -- Mount
    auto_mount        = true,

    debug_mode        = false,
}

M.update = function ()
    if not gui.elements then return end
    local e = gui.elements
    local function bget(k, d) if e[k] then return e[k]:get() end; return d end
    M.kill_monsters     = bget('uc_kill_monsters',     true)
    M.kill_range        = bget('uc_kill_range',        25)
    M.boss_intro_delay  = bget('uc_boss_intro_delay',  3)
    M.do_chests         = bget('uc_do_chests',         true)
    M.do_enticements    = bget('uc_do_enticements',    true)
    M.max_hearths       = bget('uc_max_hearths',       4)
    M.enticement_timeout = bget('uc_enticement_timeout', 4)
    M.auto_reset_after  = bget('uc_auto_reset_after',  600)
    M.exit_after_chest  = bget('uc_exit_after_chest',  true)
    M.auto_mount        = bget('uc_auto_mount',        true)
    M.debug_mode        = bget('debug_mode',           false)
end

return M
