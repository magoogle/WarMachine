-- activities/nmd/data/objective_patterns.lua
--
-- NMD objective interactable skin patterns -- the things that gate
-- progression (pedestals, levers, doors that need a key, corruption pools,
-- etc.).  Distilled from SigilRunner/data/objective_actors.lua's priority
-- list; trimmed to the ones actor_capture in the recorder will see.
-- ---------------------------------------------------------------------------

return {
    -- Dungeon affix interactables (DGNAFX_*)
    'DGNAFX_',

    -- Doors / gates / blockers
    'DGN_.*[Dd]oor',
    'DGN_.*[Gg]ate',
    'DGN_Standard_Door',
    'Hell_Fort.*[Dd]oor',
    'DRLG_Blocker',

    -- Pedestals / levers / altars / switches
    'NMD_Pedestal',
    'NMD_Lever',
    'NMD_Altar',
    'NMD_Switch',
    'NMD_Activate',
    'DGN_Pedestal',
    'DGN_Lever',
    'DGN_Altar',
    'DGN_Switch',
    'Obj_Dungeon.*Activate',
    'Obj_Dungeon.*Switch',

    -- Carry-objects
    'Obj_Dungeon.*Carry',
    'Item_Dungeon.*Carry',

    -- Boss-room glyphstone (NMD glyph upgrade)
    'NMD_GlyphStone',
    'Awakened_Glyphstone',
}
