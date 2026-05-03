-- ---------------------------------------------------------------------------
-- core/entry_portal.lua
--
-- "Don't click the door I just came through."
--
-- When the player teleports into a dungeon (NMD, Undercity, Pit floor,
-- whatever), they spawn directly on the entry portal -- the same actor
-- that takes them BACK to where they came from if interacted with.
-- Without an exclusion mechanism, interact_poi / seek_progression /
-- exit / floor_portal can pick that very portal as their next click
-- target and immediately yank the bot back to town.
--
-- Pit had per-floor `tracker.back_portal_pos` for this since forever;
-- this module generalizes the same idea to EVERY zone transition,
-- accessible from any task without per-activity tracker plumbing.
--
-- How it works:
--
--   1. Every pulse (driven by core/runner.lua) we tick this module.
--      On detecting a zone change, we drop the previous entry
--      snapshot and wait for the next valid player position.
--
--   2. The first valid player position after a zone change becomes
--      the entry snapshot.  D4 spawns the player AT the entry portal
--      after a teleport, so this is the position to exclude.
--
--   3. Tasks that pick portal/door/POI targets (interact_poi,
--      floor_portal, exit) consult M.is_near_entry(x, y, radius?)
--      and skip candidates whose coordinates are within the radius.
--      Default radius DEFAULT_RADIUS_M is 25y -- D4 sometimes drops
--      the player a few yards away from the actual portal actor on
--      large dungeons, so the radius is generous.
--
-- Stays per-zone: when the player leaves the zone the snapshot is
-- considered stale; on the next zone-change the next snapshot
-- captures the new entry.  Pit's per-floor world_id changes count as
-- zone changes for our purposes (the zone string is the WORLD name in
-- pit, which changes between floors).
-- ---------------------------------------------------------------------------

local M = {}

-- Default exclusion radius in yards.  Tight on purpose: in NMD,
-- Undercity, and most dungeons D4 spawns the player LITERALLY ON
-- TOP of the entry portal (the portal's clickbox covers the spawn
-- point).  5y is enough to keep the bot from instant-clicking it
-- without sweeping in legitimate POIs that happen to be in the
-- starting room.
--
-- Larger gaps (e.g. pit floor descent's ~22y spawn-to-back-portal
-- distance per pit/floor_portal.lua) need their OWN larger radius;
-- pit handles that with tracker.back_portal_pos + 25y check, this
-- module is the cross-activity baseline for "literally on top of
-- you" entries.
local DEFAULT_RADIUS_M  = 5.0
local DEFAULT_RADIUS_SQ = DEFAULT_RADIUS_M * DEFAULT_RADIUS_M

-- Module-level state.  One snapshot at a time -- when the player
-- leaves the zone we drop it and the next zone-change captures fresh.
local _entry      = nil   -- { zone, x, y, set_t }
local _last_zone  = nil

local function now_s()
    return get_time_since_inject and get_time_since_inject() or 0
end

local function current_zone_name()
    local w = get_current_world and get_current_world() or nil
    if not w or not w.get_current_zone_name then return nil end
    local ok, z = pcall(function () return w:get_current_zone_name() end)
    if ok then return z end
    return nil
end

-- Pit-specific: for pit floors the zone name stays 'PIT_Subzone'
-- across descents, but the WORLD name changes between floors
-- (PIT_Cave_Coast on F1 -> PIT_Hell_Fort on F2 etc.).  We use the
-- world name there as a tighter zone signal so each floor descent
-- triggers a fresh entry snapshot.
local function current_zone_signal()
    local w = get_current_world and get_current_world() or nil
    if not w then return nil end
    local zone = current_zone_name()
    -- Pit composite: zone + world for better per-floor granularity.
    if zone == 'PIT_Subzone' then
        local world_name = w.get_name and w:get_name() or '?'
        return 'PIT|' .. tostring(world_name)
    end
    return zone
end

-- ---------------------------------------------------------------------------
-- Public: tick.  Called from core.runner once per pulse.  Cheap; only
-- expensive on the rare zone-change frame.
-- ---------------------------------------------------------------------------
M.tick = function ()
    local cur_signal = current_zone_signal()
    if not cur_signal then return end

    -- Zone changed -> invalidate the snapshot.  Next valid player
    -- position takes over as the new entry.
    if cur_signal ~= _last_zone then
        if _entry then
            -- Brief log when transitioning so an operator tailing the
            -- console can see when exclusion zones change.
            -- Quiet by default; comment out if too noisy.
            -- console.print(string.format('[entry_portal] zone: %s -> %s', tostring(_last_zone), cur_signal))
        end
        _last_zone = cur_signal
        _entry = nil
    end

    -- Capture entry snapshot the first frame the player has a valid
    -- position in the new zone.  D4's teleport-arrival has a brief
    -- window where get_position can return nil; we just wait for it.
    if not _entry then
        local lp = get_local_player and get_local_player() or nil
        if lp and lp.get_position then
            local ok, pp = pcall(function () return lp:get_position() end)
            if ok and pp then
                _entry = {
                    zone  = cur_signal,
                    x     = pp:x(),
                    y     = pp:y(),
                    set_t = now_s(),
                }
                console.print(string.format(
                    '[entry_portal] %s entry @ (%.1f, %.1f) -- %dy radius excluded',
                    tostring(cur_signal), _entry.x, _entry.y, DEFAULT_RADIUS_M))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Public: is the given (x, y) within the entry-exclusion radius?
-- Returns false (not excluded) when:
--   * No entry snapshot exists yet (haven't moved into a dungeon
--     this session)
--   * Caller-provided coords are nil
-- Returns true when within `radius` (default 25y) of the snapshot.
-- ---------------------------------------------------------------------------
M.is_near_entry = function (x, y, radius)
    if not _entry then return false end
    if not x or not y then return false end
    local r = radius or DEFAULT_RADIUS_M
    local dx = x - _entry.x
    local dy = y - _entry.y
    return (dx * dx + dy * dy) <= (r * r)
end

-- Convenience for callers that have an actor instead of raw coords.
M.is_actor_near_entry = function (actor, radius)
    if not actor or not actor.get_position then return false end
    local ok, p = pcall(function () return actor:get_position() end)
    if not ok or not p then return false end
    return M.is_near_entry(p:x(), p:y(), radius)
end

-- Convenience for callers with a catalog POI table { x, y, ... }.
M.is_poi_near_entry = function (poi, radius)
    if not poi then return false end
    return M.is_near_entry(poi.x, poi.y, radius)
end

-- ---- Diagnostics + admin helpers ----

-- Returns a copy of the current snapshot (or nil).
M.get = function ()
    if not _entry then return nil end
    return {
        zone  = _entry.zone,
        x     = _entry.x,
        y     = _entry.y,
        set_t = _entry.set_t,
    }
end

-- Returns the default exclusion radius (callers may want to display
-- this in a GUI).
M.default_radius = function () return DEFAULT_RADIUS_M end

-- Force-clear the snapshot.  Useful if a sibling task is sure the
-- player has moved past the entry portal and wants subsequent
-- pulses to reconsider previously-excluded actors (rarely needed --
-- the natural zone-change reset covers most cases).
M.clear = function ()
    _entry = nil
    _last_zone = nil
end

return M
