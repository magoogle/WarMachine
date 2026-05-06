-- ---------------------------------------------------------------------------
-- core/persistence.lua  --  Explorer state classifier (memory-only).
--
-- Disk persistence was removed: the periodic full-file rewrite of MB-
-- sized zone snapshots (Hawe_Verge.lua hit 4.7 MB) on the game thread
-- caused visible stutter every flush interval.  Rather than band-aid
-- with throttling or async I/O, we now keep all explorer state in
-- memory only and reset it on zone change.  Re-entering a zone re-
-- explores from scratch, but the trade is a stutter-free run loop.
--
-- What still lives here:
--   * classify_zone / is_persistable_zone -- the SKIP_PREFIXES list is
--     still used by callers to decide whether to track a zone at all
--     (cities/hubs are tiny and not worth in-memory bookkeeping).
--   * load / save / flush_if_due / reset_mirror / get_mirror_stats   --
--     preserved as no-ops so existing call sites compile unchanged.
--     load returns nil; save / flush_if_due return false; reset_mirror
--     is a no-op; get_mirror_stats returns nil.  No disk I/O happens.
-- ---------------------------------------------------------------------------

local M = {}

-- Zone-name prefixes that regenerate per run.  Kept in classifier output
-- because callers use the 'procedural' / 'overworld' distinction even
-- without disk I/O (different in-memory tracking strategies).
local PROCEDURAL_PREFIXES = {
    'PIT_',
    'DGN_',
    'X1_Undercity_',
    'S05_BSK_',
    'Boss_',
    'S12_Boss_',
}

-- Zones that should never be tracked.  Cities/hubs are tiny, the bot
-- only passes through them on transit, and tracking them would burn
-- cycles for no gain.
local SKIP_PREFIXES = {
    '[sno none]',     -- loading screen pseudo-zone
    -- Cities / hubs.  Add more here if D4 ever exposes a new hub zone.
    'Skov_Temis',     -- War Plan hub
    'Naha_Kurast',    -- Undercity hub (Kurast)
    'Cer_',           -- Cerrigar (Pit hub)
    'Frac_Kyovashad', -- Kyovashad
    'Scos_Margrave',  -- Margrave
    'Step_Ked_Bardu', -- Ked Bardu
    'Hawe_Zarbinzet', -- Zarbinzet
    'Kehj_Caldeum',   -- Caldeum (city only; overworld Kehjistan is a
                      --          different zone and still tracks)
}

-- ---------------------------------------------------------------------------
-- Classify a zone name as 'overworld', 'procedural', or 'skip'.
-- ---------------------------------------------------------------------------
M.classify_zone = function (zone)
    if not zone or zone == '' then return 'skip' end
    for _, prefix in ipairs(SKIP_PREFIXES) do
        if zone:sub(1, #prefix) == prefix then return 'skip' end
    end
    for _, prefix in ipairs(PROCEDURAL_PREFIXES) do
        if zone:sub(1, #prefix) == prefix then return 'procedural' end
    end
    return 'overworld'
end

M.is_persistable_zone = function (zone)
    return M.classify_zone(zone) ~= 'skip'
end

-- ---------------------------------------------------------------------------
-- No-op stubs so existing call sites in main.lua / explorer.lua keep
-- compiling.  The navigator's in-memory state (explorer.visited /
-- explorer.scanned) is the only source of truth now -- nothing gets
-- written to or read from disk.
-- ---------------------------------------------------------------------------
M.load          = function () return nil end
M.save          = function () return false end
M.flush_if_due  = function () return false end
M.reset_mirror  = function () end
M.get_mirror_stats = function () return nil end

return M
