-- ---------------------------------------------------------------------------
-- core/interact.lua
--
-- Lightweight wrappers for finding actors and clicking them.
--
-- D4's built-in `interact_object(actor)` walks the player the final few
-- yards on its own, the same way clicking an NPC name in normal play does.
-- So as long as the actor is in our stream radius, a direct interact_object
-- call is sufficient.  For long-range movement use core/move.lua.
-- ---------------------------------------------------------------------------

local interact = {}

-- Returns first actor whose skin name matches `skin`. Optionally requires
-- the actor to be currently interactable.
interact.find_by_skin = function (skin, require_interactable)
    if not actors_manager then return nil end
    local list = actors_manager:get_all_actors()
    for _, a in pairs(list) do
        if a:get_skin_name() == skin then
            if not require_interactable or a:is_interactable() then
                return a
            end
        end
    end
    return nil
end

-- Euclidean distance between two positions (or position-bearing things).
local function distance(a, b)
    if a.get_position then a = a:get_position() end
    if b.get_position then b = b:get_position() end
    if not a or not b then return math.huge end
    local dx = a:x() - b:x()
    local dy = a:y() - b:y()
    return math.sqrt(dx*dx + dy*dy)
end
interact.distance = distance

-- Direct interact -- D4 walks the player the last few yards itself.
-- Returns:
--   'interacted'  -- interact_object() called
--   'too_far'     -- actor exists but beyond interact_range (defaults to 30y,
--                   which is roughly the actor stream radius in town)
--   'no_actor'    -- actor is nil or has no position
interact.walk_and_interact = function (actor, interact_range)
    interact_range = interact_range or 30.0
    if not actor then return 'no_actor' end
    local lp = get_local_player()
    if not lp then return 'no_actor' end

    local d = distance(lp, actor)
    if d == math.huge then return 'no_actor' end
    if d > interact_range then return 'too_far' end

    interact_object(actor)
    return 'interacted'
end

return interact
