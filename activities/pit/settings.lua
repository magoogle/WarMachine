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

    -- Glyph upgrade (post-boss gizmo).  Settings ported from ArkhamAsylum
    -- so users get the same controls inside WarMachine.  See activities/pit/
    -- tasks/upgrade_glyph.lua for how each is consumed.
    glyph_upgrade           = true,    -- master toggle (= old `interact_glyph`)
    glyph_upgrade_mode      = 1,       -- 1 = highest-to-lowest, 2 = lowest-to-highest
    glyph_upgrade_threshold = 1,       -- min upgrade chance % to attempt
    glyph_upgrade_legendary = true,    -- attempt level-15 legendary upgrade (level 45 in old enum)
    glyph_min_level         = 1,       -- only upgrade glyphs with level >= this
    glyph_max_level         = 100,     -- only upgrade glyphs with level <= this

    -- Pit level (1-150).  WarPlan ignores this and uses whatever the
    -- vendor selected; standalone mode opens this level via the Pit-key
    -- Crafter at the start of each run.
    level            = 60,

    -- Push-mode: cluster-based mob pulling.  Off by default because
    -- it changes engagement style noticeably (the bot will chase
    -- distant packs instead of fighting whatever's nearest).  Worth
    -- enabling at high pit tiers where dense AOE clears beat
    -- one-at-a-time picks.  See activities/pit/tasks/push_monsters.lua
    -- for the algorithm.
    push_mode               = false,
    push_threshold          = 5,    -- weighted enemies near player
                                    -- needed to "engage in place" (=
                                    -- yield from push_monsters back
                                    -- to kill_monster).
    push_max_pull_dist      = 50,   -- yards; max cluster scan radius.
    push_min_cluster_weight = 1,    -- ignore single-mob clusters; raise
                                    -- to 3+ if you only want to chase
                                    -- elite/champion packs.
    push_boss_weight        = 4,    -- per-rank weight in centroid + score
    push_champion_weight    = 2,
    push_elite_weight       = 1.5,

    debug_mode       = false,
}

-- auto_mount removed: pit floors are short, mount churn (pre-engage
-- dismount + post-engage remount) hurts more than it helps.  Helltide
-- is the only activity where mounting between POIs is a net win.
-- core/mount_manager.lua call in pit/api.lua passes disabled=true
-- unconditionally now.

M.update = function ()
    if not gui.elements then return end
    local e = gui.elements
    local function bget(k, d) if e[k] then return e[k]:get() end; return d end
    M.kill_monsters           = bget('pit_kill_monsters',           true)
    M.kill_range              = bget('pit_kill_range',              25)
    M.boss_intro_delay        = bget('pit_boss_intro_delay',        3)
    M.auto_reset_after        = bget('pit_auto_reset_after',        600)
    M.exit_after_chest        = bget('pit_exit_after_chest',        true)
    M.do_chests               = bget('pit_do_chests',               true)
    M.do_shrines              = bget('pit_do_shrines',              true)
    -- Backward compat: keep `interact_glyph` as an alias for
    -- `glyph_upgrade` for any task code that still reads the old name.
    M.glyph_upgrade           = bget('pit_glyph_upgrade',           true)
    M.interact_glyph          = M.glyph_upgrade
    M.glyph_upgrade_mode      = bget('pit_glyph_upgrade_mode',      1)
    M.glyph_upgrade_threshold = bget('pit_glyph_upgrade_threshold', 1)
    M.glyph_upgrade_legendary = bget('pit_glyph_upgrade_legendary', true)
    M.glyph_min_level         = bget('pit_glyph_min_level',         1)
    M.glyph_max_level         = bget('pit_glyph_max_level',         100)
    M.level                   = bget('pit_level',                   60)
    M.push_mode               = bget('pit_push_mode',               false)
    M.push_threshold          = bget('pit_push_threshold',          5)
    M.push_max_pull_dist      = bget('pit_push_max_pull_dist',      50)
    M.push_min_cluster_weight = bget('pit_push_min_cluster_weight', 1)
    M.push_boss_weight        = bget('pit_push_boss_weight',        4)
    M.push_champion_weight    = bget('pit_push_champion_weight',    2)
    M.push_elite_weight       = bget('pit_push_elite_weight',       1.5)
    M.debug_mode              = bget('debug_mode',                  false)
end

return M
