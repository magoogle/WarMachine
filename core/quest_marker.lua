-- ---------------------------------------------------------------------------
-- core/quest_marker.lua
--
-- Quest-driven navigation primitive.
--
-- D4's host puts a special actor named `TrackedCheckpoint_Marker`
-- in the stream at the current quest's next waypoint -- the same
-- position the player sees as a pulsing marker on the minimap.
-- It moves around the world as the quest advances:
--   * "Slay the Aldurkin: 1"     -> roughly where the last Aldurkin is
--   * "Travel to <area>"         -> at the destination
--   * "Activate the X switch"    -> on the switch
--
-- Without this primitive, WarMachine had no way to answer "where is
-- the next thing the quest wants me to do?" when the quest text
-- referred to a place the static catalog had no entry for (uncharted
-- dungeon, generated procedural objective, "Travel to" navigation).
-- The bot would explore at 1.5y / 8y rings hoping to bump into the
-- objective; with this we can walk straight to it.
--
-- API:
--
--   quest_marker.find()         -> live actor | nil
--   quest_marker.position()     -> vec3 | nil  (convenience)
--   quest_marker.distance()     -> number      (math.huge when no marker)
--
-- Cheap: scans actors_manager:get_all_actors once per call.  Callers
-- usually wrap in a per-pulse cache if they care about cost.
-- ---------------------------------------------------------------------------

local M = {}

-- Skin name of the quest-checkpoint marker actor.  Observed live in
-- S09 NMD; we keep it as a substring match in case Blizzard re-skins
-- it across seasons or appends a season prefix.
local MARKER_SKIN_PATTERNS = {
    'trackedcheckpoint_marker',     -- canonical
    'tracked_checkpoint_marker',    -- defensive variant
    'questmarker',                  -- defensive
    'quest_marker',                 -- defensive
}

local function skin_matches(sn)
    if not sn or sn == '' then return false end
    local lower = sn:lower()
    for _, p in ipairs(MARKER_SKIN_PATTERNS) do
        if lower:find(p, 1, true) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Public: locate the live quest-checkpoint marker actor.  Returns
-- the closest one to the player when multiple are present (rare;
-- only happens during quest hand-off frames where the old + new
-- markers briefly co-exist).
-- ---------------------------------------------------------------------------
M.find = function ()
    if not actors_manager or not actors_manager.get_all_actors then
        return nil
    end
    local lp = get_local_player and get_local_player() or nil
    local pp = lp and lp.get_position and lp:get_position() or nil

    local best, best_d2 = nil, math.huge
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn and skin_matches(sn) then
            if not pp then
                -- No player ref -- return the first match.
                return a
            end
            local p = a.get_position and a:get_position() or nil
            if p then
                local dx = p:x() - pp:x()
                local dy = p:y() - pp:y()
                local d2 = dx * dx + dy * dy
                if d2 < best_d2 then
                    best, best_d2 = a, d2
                end
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Public: live marker position (vec3) or nil.
-- ---------------------------------------------------------------------------
M.position = function ()
    local a = M.find()
    if not a or not a.get_position then return nil end
    local ok, p = pcall(function () return a:get_position() end)
    if not ok then return nil end
    return p
end

-- ---------------------------------------------------------------------------
-- Public: 2D distance from player to marker.  Returns math.huge when
-- no marker is in stream OR the player has no position.
-- ---------------------------------------------------------------------------
M.distance = function ()
    local lp = get_local_player and get_local_player() or nil
    if not lp or not lp.get_position then return math.huge end
    local pp = lp:get_position()
    if not pp then return math.huge end
    local mp = M.position()
    if not mp then return math.huge end
    local dx = pp:x() - mp:x()
    local dy = pp:y() - mp:y()
    return math.sqrt(dx * dx + dy * dy)
end

-- ---------------------------------------------------------------------------
-- Diagnostic / debug helper: returns a snapshot for status displays.
-- ---------------------------------------------------------------------------
M.snapshot = function ()
    local a = M.find()
    if not a then return { present = false } end
    local p = a.get_position and a:get_position() or nil
    return {
        present = true,
        skin    = a.get_skin_name and a:get_skin_name() or '?',
        x       = p and p:x() or nil,
        y       = p and p:y() or nil,
        z       = p and p:z() or nil,
        distance = M.distance(),
    }
end

return M
