-- activities/boss/settings.lua

local gui       = require 'gui'
local boss_data = require 'activities.boss.data.boss_data'

-- Helper: combo_box returns a 0-indexed integer; map to boss_id string
-- via the ordered boss_data.bosses list.
local function boss_id_at_index(idx, fallback)
    local b = boss_data.bosses[(idx or 0) + 1]
    return (b and b.id) or fallback
end

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
    chest_grace_secs = 15,    -- grace after chest open before declaring run_done.
                              -- Universal end-of-run loot grace (was 4s);
                              -- see core/exit_grace.lua for the rationale.

    -- Periodic dungeon-reset between runs.  Some boss zones accumulate
    -- stale actors / lingering effects after many back-to-back runs;
    -- calling reset_all_dungeons() every N completed runs clears that.
    -- Off by default; opt-in via the GUI checkbox below.
    dungeon_reset_enabled  = false,
    dungeon_reset_interval = 25,

    -- Boss selection (standalone mode only -- WarPlan picks the boss for us).
    -- selection_mode:
    --   1 = Specific  (always run primary_boss)
    --   2 = Random    (pick from enabled bosses each run)
    --   3 = Split     (alternate between primary_boss and secondary_boss)
    selection_mode   = 1,
    primary_boss     = 'andariel',
    secondary_boss   = 'duriel',
    -- Per-boss enable flags (used by Random mode).  All on by default.
    enable_andariel  = true,
    enable_duriel    = true,
    enable_varshan   = true,
    enable_grigoire  = true,
    enable_zir       = true,
    enable_beast     = true,
    enable_harbinger = false,    -- greater-key boss
    enable_urivar    = false,    -- greater-key boss
    enable_belial    = false,    -- greater-key boss
    enable_butcher   = false,

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
    M.chest_grace_secs = bget('boss_chest_grace_secs', 15)
    M.dungeon_reset_enabled  = bget('boss_dungeon_reset_enabled',  false)
    M.dungeon_reset_interval = bget('boss_dungeon_reset_interval', 25)
    -- combo_box returns 0-indexed slots.  selection_mode:
    --   0 = Specific, 1 = Random, 2 = Split.  Add 1 so M.selection_mode
    --   matches the 1-based settings semantic above.
    M.selection_mode   = (bget('boss_selection_mode', 0) or 0) + 1
    -- Boss list combos return integer indices; map to boss_id strings.
    M.primary_boss     = boss_id_at_index(bget('boss_primary',   0), 'andariel')
    M.secondary_boss   = boss_id_at_index(bget('boss_secondary', 1), 'duriel')
    M.enable_andariel  = bget('boss_enable_andariel',  true)
    M.enable_duriel    = bget('boss_enable_duriel',    true)
    M.enable_varshan   = bget('boss_enable_varshan',   true)
    M.enable_grigoire  = bget('boss_enable_grigoire',  true)
    M.enable_zir       = bget('boss_enable_zir',       true)
    M.enable_beast     = bget('boss_enable_beast',     true)
    M.enable_harbinger = bget('boss_enable_harbinger', false)
    M.enable_urivar    = bget('boss_enable_urivar',    false)
    M.enable_belial    = bget('boss_enable_belial',    false)
    M.enable_butcher   = bget('boss_enable_butcher',   false)
    M.debug_mode       = bget('debug_mode',            false)
end

-- Helper: returns true if a boss id is enabled in settings.
M.is_enabled = function (boss_id)
    return M['enable_' .. boss_id] == true
end

-- Helper: ordered list of enabled boss ids.
M.enabled_boss_ids = function ()
    local out = {}
    local order = { 'andariel', 'duriel', 'varshan', 'grigoire', 'zir', 'beast',
                    'harbinger', 'urivar', 'belial', 'butcher' }
    for _, id in ipairs(order) do
        if M.is_enabled(id) then out[#out + 1] = id end
    end
    return out
end

return M
