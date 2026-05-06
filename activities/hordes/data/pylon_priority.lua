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
    -- Order matches the user-supplied canonical pylons.lua list.  Inline
    -- comments below each name describe the boon's in-game effect for
    -- reference -- they don't affect the picker, the picker only looks
    -- at the position in this array.
    priority = {
        -- Always-take picks: outsized loot/aether vs the standard
        -- wave modifiers.
        'ChaoticOffering',         -- Chaos Rifts
        'AetherGoblins',           -- +100% monster HP, Aether Goblins can spawn

        -- Mass-tier modifiers.
        'ThrivingMasses',          -- Masses deal unavoidable damage; spawn an Aetheric Mass at wave start
        'FiendishMasses',          -- Masses spawn aether fiends on death; Aether Masses grant +3 Aether
        'FiendishLegions',         -- Elite + Aether Fiend dmg +25%; Fiends can spawn in place of Elites
        'BlisteringHordes',        -- Normal Monster spawn Aether Events 50% faster
        'SurgingElites',           -- Elite chance doubled; Aether Fiends grant +2 Aether
        'BlightedVerge',           -- Masses spawn more often; Soulspires spawn less often
        'UnstoppableElites',       -- Elites are unstoppable; Aether Fiends grant +2 Aether
        'EmpoweredElites',         -- Elite damage +25%; Aether Fiends grant +2 Aether
        'MassingMasses',           -- Aetheric Masses +100% HP; chance to spawn more masses on death
        'GorgingMasses',           -- Slaying Aetheric Masses slows you; chance to spawn another on death
        'PuffingMasses',           -- Damage from Masses applies Vulnerable; +1 Aether per Mass Offering
        'EmpoweredMasses',         -- Aetheric Mass dmg +25%; Aetheric Mass grants +1 Aether

        -- Lord-tier modifiers.
        'ColossalFiends',          -- Aether Lords cause Hellfire eruptions; Fiends spawn as Lords (3x Aether)
        'GestatingMasses',         -- Masses spawn an Aether Lord on death; Lords grant +3 Aether
        'InfernalLords',           -- Aether Lords spawn; grant +3 Aether
        'RuthlessLords',           -- Aether Lords gain HP/dmg per spawn; grant +5 Aether
        'InfernalStalker',         -- Infernal demon hunts you; slay for +100 Aether

        -- Hellborne modifiers (first chunk).
        'HellishMasses',           -- Masses explode on death; chance to spawn Hellborne on death
        'SummonedHellborne',       -- Hellborne can spawn with Aether Events; +1 Aether
        'AmbushingHellborne',      -- Hellborne can spawn as ambushes; +1 Aether

        -- Force-chaos modifiers.
        'ForceChaosWaves',         -- Force ALL waves to be Chaos Waves
        'ForceNextChaosWave',      -- Force next offering to have a Chaos Wave
        'ForceNoChaosWaves',       -- Turn off all access to Chaos Waves

        -- Wave-end / hellfire / Hellborne (second chunk).
        'HellsWrath',              -- Hellfire intensifies; +15-25 Aether at end of each wave
        'SkulkingHellborne',       -- Hellborne hunting you; +1 Aether
        'SurgingHellborne',        -- +1 Hellborne when spawned; +1 Aether
        'EmpoweredHellborne',      -- Hellborne damage +25%; +1 Aether
        'RagingHellfire',          -- Hellfire rains; +3-9 Aether at end of each wave
        'InvigoratingHellborne',   -- Hellborne damage +25%; slaying invigorates you

        -- Council modifiers.
        'EmpoweredCouncil',        -- Fell Council damage +50%; Council grants +15 Aether
        'IncreasedEvadeCooldown',  -- +2s Evade cooldown; Council grants +15 Aether
        'IncreasedPotionCooldown', -- +2s potion cooldown; Council grants +15 Aether
        'ReduceAllResistance',     -- All Resist -10%; Council grants +15 Aether

        -- Misc / spire / late tier.
        'MeteoricHellborne',       -- Hellfire spawns Hellborne; +1 Aether
        'DeadlySpires',            -- Soulspires drain HP; grant +2 Aether
        'AetherRush',              -- Normal Monsters dmg +25%; gathering Aether boosts movement speed
        'EnergizingMasses',        -- Slaying Aetheric Masses slow you; while slowed, UNLIMITED RESOURCES
        'GreedySpires',            -- Soulspire requires 2x kills; grants 2x Aether
        'UnstableFiends',          -- Elite damage +25%; Fiends explode and damage foes
        'EnduringLords',           -- Aether Lords don't despawn at round end; greatly increased HP
        'CorruptingSpires',        -- Soulspires empower nearby foes; pull enemies inward
        'BlightedSpires',          -- Soulspires no longer invigorate; spawn aether events
        'TransitiveSpires',        -- Soulspires double HP; while standing nearby, all kills count as in-range
        'CovetedSpires',           -- Soulspires spawn less often; grant 2x additional Aether
        'TreasuredSpires',         -- Soulspires spawn less often; grant 2.25x additional Aether
        'PreciousSpires',          -- Soulspires spawn less often; grant 2.5x additional Aether
        'DesolateVerge',           -- Soulspires spawn more often; Masses spawn less often
        'AnchoredMasses',          -- Aetheric Masses greatly increased atk speed; chance to spawn Soulspire on death
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
