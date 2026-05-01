-- ---------------------------------------------------------------------------
-- activities/pit/tasks/interact_shrine.lua
--
-- Live-stream shrine interaction for pit floors.
--
-- Why a dedicated live-stream task instead of letting interact_poi handle
-- it: poi_priority builds its queue from StaticPatherPlugin.get_actors()
-- which only includes shrines that have been catalogued in the merged
-- WarMap zone JSONs.  Shrines in fresh / season-prefixed pit variants
-- often aren't catalogued yet, so they're invisible to the priority
-- queue but visible in the live actor stream.  This task fills that
-- gap with a direct stream scan -- mirrors NMD's loot_chest pattern.
--
-- Substring patterns cover the standard D4 shrine families.  Season
-- prefixes (S09_*, S12_*) and zone qualifiers (e.g. Pit_Shrine_Foo)
-- still match because we substring-test.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local find     = require 'core.find'
local settings = require 'activities.pit.settings'
local tracker  = require 'activities.pit.tracker'

local task = { name = 'interact_shrine', status = 'idle' }

local INTERACT_RADIUS = 3.0
local SCAN_RADIUS_SQ  = 60 * 60

-- Shrine skin substrings (case-insensitive).  Excludes 'Pyre_Helltide'
-- and 'Helltide_Pyre' which are helltide-specific and don't apply here.
local SHRINE_PATTERNS = {
    'shrine_lethal',
    'shrine_artillery',
    'shrine_conduit',
    'shrine_blast',
    'shrine_protect',
    'shrine_greed',
    'shrine_channeling',
    -- Generic catch-alls.  Case-insensitive scan picks up `Shrine_*`,
    -- `_Shrine_*`, `S09_Shrine_*`, etc.
    'shrine_',
    '_shrine',
}

local function find_shrine()
    return find.closest({
        patterns         = SHRINE_PATTERNS,
        require_interactable = true,
        source           = 'all',   -- shrines live in get_all_actors
        max_dist_sq      = SCAN_RADIUS_SQ,
        visited          = tracker.visited,
        visited_prefix   = 'shrine',
    })
end

task.shouldExecute = function ()
    if settings.do_shrines == false then return false end
    return find_shrine() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local shrine = find_shrine()
    if not shrine then task.status = 'no shrine'; return end
    local p = shrine:get_position()
    if not p then return end

    local dx, dy = p:x() - pp:x(), p:y() - pp:y()
    local d = math.sqrt(dx*dx + dy*dy)
    local sn = shrine:get_skin_name() or '?'

    if d <= INTERACT_RADIUS then
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        interact_object(shrine)
        tracker.visited = tracker.visited or {}
        tracker.visited[find.key_for('shrine', shrine, p)] = true
        if settings.debug_mode then
            console.print('[Pit] activated shrine: ' .. sn)
        end
        task.status = 'activated ' .. sn
        return
    end

    move.to_actor(shrine)
    task.status = string.format('walking to shrine (%.0fm)', d)
end

return task
