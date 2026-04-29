-- ---------------------------------------------------------------------------
-- Nightmare Dungeon objective actor skin name patterns.
--
-- HOW TO USE:
--   1. Enable Debug Mode in the SigilRunner menu.
--   2. Run several dungeons.  Unknown interactables will be printed to
--      console (and sigilrunner_debug.txt if file logging is on).
--   3. Add the new skin names / patterns to the relevant section below.
--   4. Enable "Interact Objectives" in settings to activate this task.
--
-- Patterns are Lua string patterns (not regexes).
-- Use plain substrings for exact prefix/suffix matching, e.g. 'NMD_Pedestal'
-- Use wildcards sparingly: '.*' matches anything between two anchors.
--
-- OBJECTIVE TYPES (sent by D4Assistant OCR as OBJECTIVE_TYPE:<n>)
--   1 = Activate / interact (pedestals, levers, altars, switches)
--   2 = Cleanse / corruption (stand in or interact with corruption pools)
--   3 = Carry object (pick up an item and bring it somewhere)
--   4 = Kill specific named target (mini-boss or champion unlocks door)
--   0 = Unknown / generic (use the combined priority list)
-- ---------------------------------------------------------------------------

local objective_actors = {}

-- ---------------------------------------------------------------------------
-- PRIORITY LIST – searched in order, top = highest priority.
-- Add patterns here as you discover them from debug runs.
-- ---------------------------------------------------------------------------
objective_actors.priority = {
    -- War Plan reward chests (Phase 5 — observed in NMDs and Helltides)
    -- Take priority over everything else: completing the war plan is the goal.
    'Warplans_NMD_%d+_Chest',
    'Warplans_Helltide_%d+_Chest',
    'Warplans_UC_%d+_Chest',
    'Warplans_.*_Chest',

    -- Dungeon Affix interactables (DGNAFX_*) — found throughout NMDs
    'DGNAFX_',

    -- Doors and gates — match when interactable (i.e. key has been picked up)
    -- Pattern covers all zone variants: DGN_hawe_*, DGN_scos_*, DGN_kehj_*, etc.
    'DGN_.*[Dd]oor',
    'DGN_.*[Gg]ate',
    'DGN_Standard_Door',
    'Hell_Fort.*[Dd]oor',
    'DRLG_Blocker',              -- zone-specific blockers e.g. DRLG_Blocker_Ancients_Sand_DGN_Kehj_SunkenLibrary

    -- Chests
    'DE_Universal_Rare_Chest',
    'DE_Universal.*[Cc]hest',
    'DGN_.*[Cc]hest',
    'Chest_Rare',
    'Chest_Magic',
    'Chest_Normal',

    -- Activation / switch / pedestal / lever / altar
    'NMD_Activate',
    'NMD_Pedestal',
    'NMD_Lever',
    'NMD_Altar',
    'NMD_Switch',
    'DGN_Lever',
    'DGN_Altar',
    'DGN_Switch',
    'DGN_Pedestal',
    'Obj_Dungeon.*Activate',
    'Obj_Dungeon.*Switch',
    'Obj_Dungeon.*Lever',

    -- Cleanse / corruption pools
    'NMD_Corruption',
    'NMD_Cleanse',
    'DGN_CorruptPool',
    'DGN_Cleanse',

    -- Carry-object drop-off points
    'NMD_Dropoff',
    'NMD_Deposit',
    'DGN_Dropoff',

    -- Door / seal unlocks (interact after killing a named target)
    'NMD_Seal',
    'NMD_Door.*Unlock',
    'DGN_Door.*Unlock',
    'DGN_Seal',

    -- Generic objective fallback patterns – broad, lower priority
    'NMD_Obj',
    'DGN_Obj',
    'Obj_Dungeon',
}

-- ---------------------------------------------------------------------------
-- PER-TYPE OVERRIDES – when D4Assistant sends OBJECTIVE_TYPE:<n>,
-- the task prepends these patterns to the priority list so type-specific
-- actors are checked first.
-- ---------------------------------------------------------------------------
objective_actors.by_type = {
    [1] = {   -- Activate — interact with pedestals, levers, altars, switches
              -- Plus "Free the Prisoners" objective (observed in DGN_Step_BuriedHalls):
              -- click each Cultist_SacrificePillar_02 to free a prisoner.
        'Cultist_SacrificePillar',
        'Cultist_.*[Pp]illar',
        'NMD_Activate', 'NMD_Pedestal', 'NMD_Lever', 'NMD_Altar', 'NMD_Switch',
        'DGN_Lever', 'DGN_Altar', 'DGN_Switch', 'DGN_Pedestal',
    },
    [2] = {   -- Cleanse — stand in / interact with corruption pools
        'NMD_Corruption', 'NMD_Cleanse', 'DGN_CorruptPool', 'DGN_Cleanse',
    },
    [3] = {   -- Carry — pick up object and bring to drop-off point
        'NMD_Dropoff', 'NMD_Deposit', 'DGN_Dropoff',
    },
    [4] = {   -- Kill named target — kill_monster handles combat;
              -- seals/unlocks appear after the kill
        'NMD_Seal', 'DGN_Seal', 'NMD_Door.*Unlock', 'DGN_Door.*Unlock',
    },
    [5] = {   -- Kill all / Slay / Explore & Kill
              -- Pure combat — no special interactable needed.
              -- kill_monster and explore_dungeon handle everything.
              -- Doors still open normally via the always-on door check.
    },
    [6] = {   -- Collect Animus — full flow:
              --   Phase 1: kill Animus Carriers, pick up DGN_Standard_Mote_01 drops
              --   Phase 2: "Deposit Animus" — walk to MoteJar/Urn and interact
              -- pickup_key handles the ground motes; interact_objective handles the jar.
        'DGN_Standard_MoteJar',
        'DGN_.*MoteJar',
        'DGN_.*[Aa]nimus.*[Uu]rn',
        'DGN_.*[Uu]rn',
        'NMD_.*MoteJar',
        'MoteJar',
    },
    [7] = {   -- Destroy objects — idols, totems, pillars, braziers, statues
              -- These are destructible world objects, attacked like enemies.
              -- kill_monster handles combat; interact_objective handles any
              -- remaining interactable remnants after destruction.
              -- Plus DRLG_Structure_Spider_Cocoon (observed in DGN_Scos_SaratsLair
              -- as the "Destroy the Silken Spire" objective target — NOT
              -- interactable, attacked like an enemy)
        'DRLG_Structure_.*[Cc]ocoon',
        'DRLG_Structure_Spider_Cocoon',
        'DGN_.*[Ii]dol',
        'DGN_.*[Tt]otem',
        'DGN_.*[Pp]illar',
        'DGN_.*[Bb]razier',
        'DGN_.*[Ss]tatue',
        'DGN_.*[Ss]hrine.*[Ee]vil',
        'NMD_.*[Ii]dol',
        'NMD_.*[Tt]otem',
        'Obj_.*[Ii]dol',
        'Obj_.*[Tt]otem',
    },
}

-- ---------------------------------------------------------------------------
-- OBJECTIVE TYPE LABELS — human-readable names for each type number.
-- Used for console logging.
-- ---------------------------------------------------------------------------
objective_actors.type_labels = {
    [0] = 'Unknown/Generic',
    [1] = 'Activate (pedestals/levers)',
    [2] = 'Cleanse/Corruption',
    [3] = 'Carry Object',
    [4] = 'Kill Named Target',
    [5] = 'Kill All / Slay / Explore',
    [6] = 'Collect Animus (MoteJar)',
    [7] = 'Destroy Objects (Idols/Totems)',
}

-- ---------------------------------------------------------------------------
-- KNOWN NON-OBJECTIVE interactables to always ignore (never add to blacklist,
-- just skip silently so they don't pollute debug logs either).
-- ---------------------------------------------------------------------------
objective_actors.ignore = {
    'Shrine_DRLG',           -- shrines (handled by interact_shrine)
    'BetrayersEyeSwitch',    -- seasonal
    'NMD_Dungeon_Entrance_Portal',
    'DGN_Standard_Portal_Entrance',
    'EGD_MSWK_World_Portal',
    'Prefab_Portal_Dungeon_Generic',  -- exit portal at NMD spawn (Phase 5 obs)
    'Cultist_Triune_.*Arrangement',   -- Triune cultist decorations (Phase 5 obs)
    'TWN_',                  -- town actors
    'Checkpoint_',
    'Waypoint_',
    'PlayerBlocker',
    -- NOTE: NMDs have no exit portal or chest — do NOT add portal patterns here
}

-- ---------------------------------------------------------------------------
-- ACTIVITY-SPECIFIC INTERACTABLES — used by tasks/warplan/supervisor.lua
-- to drive objective targeting per activity type.
-- ---------------------------------------------------------------------------

-- Helltide: chests + cinder-dropping props.
objective_actors.helltide = {
    'Helltide_RewardChest',         -- Tortured Gifts (the war plan target)
    'S04_Helltide_FlamePillar_Switch_Dyn',  -- Flame Pillar event
    'Hell_Prop_.*Clicky',           -- destructible props that drop cinders
    'Hell_Prop_BreakableContainer', -- breakable containers
}

-- Undercity: end-of-run attunement chest, then enticement triggers.
objective_actors.undercity = {
    'X1_Undercity_Chest_Attunement',                  -- end chest (war plan target)
    'X1_Undercity_Enticements_SpiritBeaconSwitch',    -- spirit beacons (loot boost)
    'SpiritHearth_Switch',                             -- hearth events
    'Portal_Dungeon_Undercity',                        -- entrance portal (used in entry flow)
}

-- Helltide chest cinder costs (port from HelltideRevamped/data/enums.lua).
-- Used by helltide_step to gate "do I have enough cinders to bother".
objective_actors.helltide_chest_costs = {
    usz_rewardGizmo_1H          = 150,
    usz_rewardGizmo_2H          = 150,
    usz_rewardGizmo_ChestArmor  = 75,
    usz_rewardGizmo_Rings       = 75,
    usz_rewardGizmo_Amulet      = 125,
    usz_rewardGizmo_Gloves      = 75,
    usz_rewardGizmo_Legs        = 75,
    usz_rewardGizmo_Boots       = 75,
    usz_rewardGizmo_Helm        = 75,
    usz_rewardGizmo_Uber        = 250,
    Helltide_RewardChest_Random = 75,
}

return objective_actors
