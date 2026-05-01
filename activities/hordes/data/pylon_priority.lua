-- ===========================================================================
-- activities/hordes/data/pylon_priority.lua
--
-- USER-EDITABLE BOON / PYLON PRIORITY LIST
-- ---------------------------------------------------------------------------
-- This file controls which Infernal Hordes pylon (boon) the bot picks at
-- the between-wave choice screen.  Three pylons are offered each time;
-- the bot walks the `priority` list TOP-TO-BOTTOM and clicks the first
-- one it sees on offer.
--
-- HOW TO ADJUST
--   * Reorder `priority`.  The first boon (index 1) is the strongest
--     preference.  Move a boon higher to prefer it.
--   * Drop a boon into `blacklist` to NEVER pick it -- the bot will
--     skip a blacklisted boon even if it's the only "high-priority"
--     match offered, and fall through to the next-best option.  When
--     ALL three offered boons are blacklisted, the bot picks the first
--     one anyway after `pylon_pick_timeout` (so we don't hang).
--   * Names are matched as substrings against the pylon's skin
--     (case-sensitive).  E.g. 'ChaoticOffering' matches the live skin
--     `BSK_Pylon_ChaoticOffering_01`.  The names below are the canonical
--     spelling; use the same form if adding new entries.
--
-- The bot reloads this file on Lua reload -- no plugin restart needed
-- after edits.
-- ===========================================================================

return {
    -- ----- Priority list (top = strongest preference) -----------------------
    priority = {
        -- Always-take picks: ChaoticOffering and AetherGoblins are picked
        -- first whenever offered, regardless of what else is on the panel.
        -- Both have outsized loot/aether returns vs the standard wave
        -- modifiers.
        'ChaoticOffering',
        'AetherGoblins',

        -- Highest-aether-density pylons
        'GestatingMasses',     -- masses spawn aether lords
        'EmpoweredCouncil',    -- council grants +15 aether
        'BlightedSpires',      -- spires spawn aether events
        'CovetedSpires',       -- 2x aether per spire
        'TreasuredSpires',     -- 2.25x aether per spire
        'PreciousSpires',      -- 2.5x aether per spire
        'HellsWrath',          -- +15-25 aether per wave end
        'FiendishSpires',      -- spires +3 aether
        'FiendishMasses',      -- masses spawn aether fiends + aether bonus
        'PuffingMasses',       -- mass aether bonus
        'EmpoweredMasses',     -- mass damage + aether bonus
        'AetherRush',          -- aether grants move speed (more clears/min)
        'RuthlessLords',       -- aether lords +5 aether
        'GorgingMasses',       -- chance to spawn another mass on death
        'MassingMasses',       -- mass HP buff
        'SurgingHellborne',    -- +1 hellborne, +1 aether per
        'SkulkingHellborne',   -- hellborne hunting + aether
        'EmpoweredHellborne',
        'AmbushingHellborne',
        'InfernalLords',       -- aether lords spawn + aether
        'EnduringLords',
        'ColossalFiends',      -- aether fiends as lords (3x aether)
        'SurgingElites',
        'UnstoppableElites',
        'EmpoweredElites',
        'UnstableFiends',

        -- Less impactful but harmless picks
        'SummonedHellborne',
        'AnchoredMasses',
        'BlisteringHordes',

        -- Generally annoying mechanics, but pick them over nothing
        'IncreasedEvadeCooldown',
        'IncreasedPotionCooldown',
        'ReduceAllResistance',
        'CorruptingSpires',
        'DeadlySpires',
        'GreedySpires',
        'EnergizingMasses',
        'ThrivingMasses',
        'HellishMasses',
        'BlightedVerge',
        'DesolateVerge',
        'TransitiveSpires',
        'MeteoricHellborne',
        'RagingHellfire',
        'InvigoratingHellborne',
        'ForceChaosWaves',
        'ForceNextChaosWave',
        'ForceNoChaosWaves',
        'InfernalStalker',
    },

    -- ----- Blacklist: boons to skip even when offered -----------------------
    -- Anything listed here is treated as "not present" by the picker.  Add
    -- the canonical name (matching the priority list spelling).  Empty by
    -- default; populate to taste.  Example:
    --   blacklist = {
    --       'IncreasedPotionCooldown',
    --       'ReduceAllResistance',
    --   }
    blacklist = {},
}
