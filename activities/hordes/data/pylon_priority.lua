-- activities/hordes/data/pylon_priority.lua
--
-- Ordered preference for pylon (boon) selection between waves.
-- Top of list = strongest preference.  Distilled from HordeDev/data/
-- pylons.lua but trimmed/reordered toward maximum-aether output, which
-- is how most builds farm hordes.  Tweakable per-build later.
-- ---------------------------------------------------------------------------

return {
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
    'ChaoticOffering',     -- chaos rifts; situational
    'AetherGoblins',
    -- Generally skip these (annoying mechanics) but pick over nothing
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
}
