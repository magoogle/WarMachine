-- activities/boss/settings.lua

local gui = require 'gui'

local M = {
    -- Combat
    kill_monsters    = true,
    kill_range       = 25,
    boss_room_tether = 15,    -- max distance from anchor before the bot pulls back

    -- POI toggles
    do_chests        = true,  -- post-kill reward chest

    -- Run pacing
    auto_reset_after = 600,   -- safety net (s); reset_all_dungeons + tp home if stuck
    altar_stuck_secs = 60,    -- how long to wait after altar click before recovery
    chest_grace_secs = 4,     -- grace after chest open before declaring run_done

    debug_mode       = false,
}

-- Mounting intentionally NOT exposed for boss runs (tight rooms + constant
-- combat).  Helltide is the only activity offering the mount toggle.

M.update = function ()
    if not gui.elements then return end
    local e = gui.elements
    local function bget(k, d) if e[k] then return e[k]:get() end; return d end
    M.kill_monsters    = bget('boss_kill_monsters',    true)
    M.kill_range       = bget('boss_kill_range',       25)
    M.boss_room_tether = bget('boss_room_tether',      15)
    M.do_chests        = bget('boss_do_chests',        true)
    M.auto_reset_after = bget('boss_auto_reset_after', 600)
    M.altar_stuck_secs = bget('boss_altar_stuck_secs', 60)
    M.chest_grace_secs = bget('boss_chest_grace_secs', 4)
    M.debug_mode       = bget('debug_mode',            false)
end

return M
