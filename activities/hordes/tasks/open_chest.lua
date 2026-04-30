-- activities/hordes/tasks/open_chest.lua
--
-- Post-boss reward phase.  After the boss dies in the boss arena there
-- are two interactable surfaces:
--
-- 1) BurningAether -- the aether currency drops as floor pickups.  Walking
--    over (or interacting with) them adds to your aether currency, which
--    is what you spend to open the chests.  Skin: 'BurningAether'.
--
-- 2) Reward chests -- 4 fixed-skin chests appear:
--       BSK_UniqueOpChest_GreaterAffix    -- guaranteed Greater-Affix item
--       BSK_UniqueOpChest_Equipment       -- random gear pieces
--       BSK_UniqueOpChest_Materials       -- crafting mats
--       BSK_UniqueOpChest_Gold            -- pile of gold
--    Each costs aether to open; the costs aren't queryable through any
--    API we know of, so we just attempt in user-priority order and let
--    the game itself reject the click when we run out (the chest stays
--    in interactable state -- we'll just attempt the next priority).
--
-- Aether-cost gating heuristic: we collect aether bombs FIRST, then
-- attempt chest opens.  If a chest is interactable but our click fails
-- silently (chest stays interactable after CLICK_DEBOUNCE_S * 2), we
-- assume insufficient aether and move to the next priority.
--
-- User chest selection (settings.lua + gui.lua):
--   do_chest_ga         (default true)   -- Greater Affix
--   do_chest_equipment  (default true)
--   do_chest_materials  (default false)
--   do_chest_gold       (default false)
-- Priority order is fixed: GA -> Equipment -> Materials -> Gold.
-- A friend can disable any combination via the GUI checkboxes.
--
-- Once at least one chest has been opened, tracker.chest_opened is set
-- so exit.lua can fire the run-done handoff.

local move     = require 'core.move'
local settings = require 'activities.hordes.settings'
local tracker  = require 'activities.hordes.tracker'

local task = {
    name             = 'open_chest',
    status           = 'idle',
    last_click_t     = nil,
    last_chest_attempt = nil,    -- (skin, started_t) for failure detection
    failed_skins     = {},       -- skins that consumed CLICK_DEBOUNCE_S*2 with no state change -> insufficient aether
}

local CLICK_DEBOUNCE_S = 4         -- chest VFX takes ~2-3s to play out
local AETHER_PICKUP_RANGE = 1.8    -- how close we have to be for the pickup to register

-- Priority order.  Match settings.do_chest_<flag> against each.
local CHEST_PRIORITY = {
    { skin = 'BSK_UniqueOpChest_GreaterAffix', flag = 'do_chest_ga',         label = 'GreaterAffix' },
    { skin = 'BSK_UniqueOpChest_Equipment',    flag = 'do_chest_equipment',  label = 'Equipment'    },
    { skin = 'BSK_UniqueOpChest_Materials',    flag = 'do_chest_materials',  label = 'Materials'    },
    { skin = 'BSK_UniqueOpChest_Gold',         flag = 'do_chest_gold',       label = 'Gold'         },
}

local function find_aether_drop()
    if not actors_manager or not actors_manager.get_all_actors then return nil, math.huge end
    local lp = get_local_player()
    if not lp then return nil, math.huge end
    local pp = lp:get_position()
    if not pp then return nil, math.huge end
    local best, best_d = nil, math.huge
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if sn == 'BurningAether' then
            local p = a:get_position()
            if p then
                local dx = p:x() - pp:x()
                local dy = p:y() - pp:y()
                local d  = math.sqrt(dx*dx + dy*dy)
                if d < best_d then best, best_d = a, d end
            end
        end
    end
    return best, best_d
end

-- Find the highest-priority chest matching the user's selected types
-- that's still interactable AND hasn't been marked failed (= insufficient
-- aether).  Returns actor, distance, skin, label.
local function find_priority_chest()
    if not actors_manager or not actors_manager.get_all_actors then return nil end
    local lp = get_local_player()
    if not lp then return nil end
    local pp = lp:get_position()
    if not pp then return nil end

    -- Build a skin -> actor map of currently-interactable chests.
    local chests_by_skin = {}
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        if a.is_interactable and a:is_interactable()
           and sn:sub(1, #'BSK_UniqueOpChest_') == 'BSK_UniqueOpChest_' then
            chests_by_skin[sn] = a
        end
    end

    -- Walk the priority list; first match wins.
    for _, p in ipairs(CHEST_PRIORITY) do
        local enabled = settings[p.flag]
        if enabled and not task.failed_skins[p.skin] then
            local a = chests_by_skin[p.skin]
            if a then
                local ap = a:get_position()
                if ap then
                    local dx = ap:x() - pp:x()
                    local dy = ap:y() - pp:y()
                    local d  = math.sqrt(dx*dx + dy*dy)
                    return a, d, p.skin, p.label
                end
            end
        end
    end
    return nil
end

task.shouldExecute = function ()
    if not settings.do_chests and not settings.do_chest_ga
       and not settings.do_chest_equipment and not settings.do_chest_materials
       and not settings.do_chest_gold then
        return false
    end
    -- Don't bother scanning until the boss is down -- chests don't spawn
    -- before that anyway.  Once boss_killed flips, we keep firing as long
    -- as ANY enabled chest type is visible OR an aether drop is on the
    -- floor (gotta pick those up regardless).
    if not tracker.boss_killed and not tracker.chest_opened then
        -- Back-fill the boss-killed flag if a chest is somehow already
        -- interactable in a BSK zone (the boss-kill detector might have
        -- missed; if a reward chest is present, the boss must have died).
        if find_priority_chest() ~= nil then
            tracker.boss_killed = true
            return true
        end
        return false
    end
    if find_aether_drop() ~= nil then return true end
    return find_priority_chest() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local now = get_time_since_inject and get_time_since_inject() or 0

    -- Phase 1: pick up any aether floor drops first.  Walking close to
    -- them auto-collects (they're not is_interactable but the game adds
    -- to currency on proximity).  We move into pickup range; once the
    -- actor disappears from the stream, we fall through to chests.
    local drop, drop_d = find_aether_drop()
    if drop then
        if drop_d <= AETHER_PICKUP_RANGE then
            -- Within pickup range; the next pulse will see it gone.  But
            -- some hosts require an explicit interact -- attempt it as
            -- a no-op-if-not-interactable.
            if drop.is_interactable and drop:is_interactable() then
                interact_object(drop)
            end
            task.status = 'collecting aether'
            return
        end
        move.to_pos(drop:get_position())
        task.status = string.format('walking to aether drop (%.0fm)', drop_d)
        return
    end

    -- Phase 2: chest open.  Walk to the highest-priority enabled chest,
    -- click it, watch for the interactable state to drop (= success).
    local chest, d, skin, label = find_priority_chest()
    if not chest then task.status = 'no chest available'; return end

    if task.last_click_t and (now - task.last_click_t) < CLICK_DEBOUNCE_S then
        task.status = 'waiting for chest VFX (' .. label .. ')'
        return
    end

    -- Insufficient-aether detection: if we just attempted this same skin
    -- and it's still interactable after CLICK_DEBOUNCE_S * 2 seconds,
    -- assume the click was rejected (insufficient aether) and skip this
    -- skin for the rest of the run.
    if task.last_chest_attempt
       and task.last_chest_attempt.skin == skin
       and (now - task.last_chest_attempt.t) > (CLICK_DEBOUNCE_S * 2) then
        task.failed_skins[skin] = true
        task.last_chest_attempt = nil
        if settings.debug_mode then
            console.print('[Hordes] skipping ' .. label .. ' chest (insufficient aether)')
        end
        task.status = label .. ': insufficient aether'
        return
    end

    if d <= 3 then
        if orbwalker and orbwalker.set_clear_toggle then orbwalker.set_clear_toggle(false) end
        interact_object(chest)
        task.last_click_t = now
        task.last_chest_attempt = { skin = skin, t = now }
        tracker.chest_opened = true
        if settings.debug_mode then
            console.print('[Hordes] clicking ' .. label .. ' chest (' .. skin .. ')')
        end
        task.status = 'opening ' .. label
        return
    end
    move.to_actor(chest)
    task.status = string.format('walking to %s chest (%.0fm)', label, d)
end

return task
