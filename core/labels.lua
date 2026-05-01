-- ---------------------------------------------------------------------------
-- core/labels.lua
--
-- Human-readable label mapping for the on-screen overlay.  The overlay
-- previously surfaced raw internal names like "WarPlans_QST_NightmareDungeon"
-- and "freeroam_fallback (warmachine_nmd)"; this module converts them to
-- short user-facing strings:
--
--   activity tag    'nightmare' -> 'Nightmare Dungeon'
--                   'pit'       -> 'The Pit'
--                   'boss'      -> 'Boss Lair'
--                   etc.
--
--   task name       'kill_monster'    -> 'Killing monsters'
--                   'interact_poi'    -> 'Looking for objective'
--                   'freeroam_fallback' -> 'Exploring'
--                   'boss_room_hold'  -> 'Holding boss room'
--                   etc.
--
-- Mappings live in one place so the GUI rendering (main.lua) and any
-- diagnostic dumps stay consistent.
-- ---------------------------------------------------------------------------

local M = {}

-- Activity tag -> human label.  Falls back to a Title-cased tag.
local ACTIVITY_LABELS = {
    nightmare  = 'Nightmare Dungeon',
    nmd        = 'Nightmare Dungeon',
    pit        = 'The Pit',
    helltide   = 'Helltide',
    undercity  = 'Undercity',
    hordes     = 'Infernal Hordes',
    boss       = 'Boss Lair',
    turnin     = 'Turning in War Plan',
    unknown    = 'War Plan',
}

M.activity = function (tag)
    if not tag then return 'Idle' end
    local l = ACTIVITY_LABELS[tag]
    if l then return l end
    -- Title-case the tag as a defensive fallback.
    return (tag:sub(1,1):upper() .. tag:sub(2))
end

-- Task internal name -> short user-facing verb phrase.  These are the
-- task.name values produced by per-activity tasks (see e.g.
-- activities/nmd/tasks/*.lua) plus the few legacy names from
-- core/freeroam.lua.
local TASK_LABELS = {
    -- Generic flow
    idle              = 'Idle',
    freeroam_fallback = 'Exploring',
    explorer          = 'Exploring',

    -- Combat
    kill_monster      = 'Killing monsters',
    boss_room_hold    = 'Holding boss room',
    walk_boss_room    = 'Returning to boss room',

    -- Interactions
    interact_poi      = 'Looking for objective',
    interact_altar    = 'Activating boss altar',
    interact_shrine   = 'Using shrine',
    cursed_shrine     = 'Cursed shrine',
    loot_chest        = 'Looting chest',
    open_chest        = 'Looting boss chest',
    floor_portal      = 'Descending floor',
    upgrade_glyph     = 'Upgrading glyphs',
    ambush            = 'Ambush event',

    -- NMD lifecycle
    select_dungeon    = 'Opening sigil',
    enter_pit         = 'Opening pit',
    select_boss       = 'Travelling to boss',

    -- Run completion
    exit              = 'Heading to town',
}

M.task = function (name)
    if not name then return '' end
    local l = TASK_LABELS[name]
    if l then return l end
    -- Fallback: replace underscores with spaces, title-case first word.
    local s = name:gsub('_', ' ')
    return (s:sub(1,1):upper() .. s:sub(2))
end

return M
