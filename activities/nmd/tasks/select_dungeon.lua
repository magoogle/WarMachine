-- ---------------------------------------------------------------------------
-- activities/nmd/tasks/select_dungeon.lua
--
-- Standalone-mode "start the next NMD" handler.  Fires when the player
-- is in town with a Nightmare Sigil in inventory.  Consumes the sigil
-- via loot_manager.use_item(); the game opens a portal at the player's
-- feet which the standard interact_poi pipeline (or the player walking
-- into it after zone load) takes from there.
--
-- Skipped entirely in WarPlan mode -- WarPlan owns transit and will TP
-- us to the dungeon directly via Next-Obj.  Running select_dungeon in
-- WarPlan would race WarPlan's clicks and consume sigils the player
-- might be saving for a different objective.
--
-- Sigil skin patterns are mirrored from LooteerV2/src/item_manager.lua.
-- ---------------------------------------------------------------------------

local move      = require 'core.move'
local find      = require 'core.find'
local zone      = require 'core.zone'
local settings  = require 'activities.nmd.settings'
local tracker   = require 'activities.nmd.tracker'
local core_mode = require 'core.mode'

local task = { name = 'select_dungeon', status = 'idle' }

local PORTAL_INTERACT_RANGE = 3.0
local PORTAL_SCAN_RADIUS_SQ = 30 * 30   -- Portal spawns at player's feet,
                                        -- but give generous slack for jitter.

-- How long to wait after firing a sigil before re-checking inventory
-- for another one.  Covers the zone-change delay -- once we're in the
-- new dungeon, NMD.shouldExecute's in_dungeon() branch takes over and
-- this task's standalone-only-in-town gate stops it from re-firing.
local USE_COOLDOWN_S = 12

-- Substring patterns checked (case-insensitive) against item skin name.
-- Mirrors LooteerV2/src/item_manager.lua sigil list.
local SIGIL_PATTERNS = {
    'nightmare_sigil',     -- canonical core sigil
    's07_witchersigil',    -- season variants
    's07_drlg_sigil',
    's09_prop_astaroth_nmd',
}

-- Find the first inventory item whose skin name matches one of the sigil
-- patterns.  Returns the item (game.item_data) or nil.
local function find_sigil()
    local lp = get_local_player()
    if not lp or not lp.get_inventory_items then return nil end
    local items = lp:get_inventory_items() or {}
    for _, item in ipairs(items) do
        local sn = item.get_skin_name and item:get_skin_name() or nil
        if sn then
            local sl = sn:lower()
            for _, pat in ipairs(SIGIL_PATTERNS) do
                if sl:find(pat, 1, true) then return item end
            end
        end
    end
    return nil
end

-- After loot_manager.use_item(sigil) the game spawns a Prefab_Portal_*
-- at the player's feet.  Find it in the live actor stream so we can
-- walk into it to enter the dungeon.
local function find_nmd_portal()
    return find.closest({
        patterns = { 'prefab_portal_' },
        require_interactable = true,
        source = 'all',
        max_dist_sq = PORTAL_SCAN_RADIUS_SQ,
        filter = function (a)
            local sn = a.get_skin_name and a:get_skin_name() or ''
            return not sn:find('Light_NoShadows', 1, true)
        end,
    })
end

task.shouldExecute = function ()
    -- Standalone Nightmare only; WarPlan owns transit.
    if core_mode.is_warplan() then return false end
    if not core_mode.is(core_mode.NIGHTMARE) then return false end

    -- Only fire OUTSIDE dungeons (in town / overworld).  Inside a DGN_*,
    -- the in-dungeon tasks own the pulse and we don't want to consume a
    -- second sigil mid-run.
    if zone.in_dungeon() then return false end

    -- If a portal we already opened is sitting nearby, prioritize walking
    -- into it (regardless of cooldown / sigil presence).
    if find_nmd_portal() then return true end

    -- Cooldown so we don't spam use_item while the portal opens / we
    -- walk through.
    local now = get_time_since_inject() or 0
    if tracker.last_sigil_use_t and (now - tracker.last_sigil_use_t) < USE_COOLDOWN_S then
        return false
    end

    -- No-op if no sigil to consume.  (Bot will fall through to whatever
    -- next task -- typically idle or freeroam fallback.)  This is the
    -- "user is out of sigils" case: NMD effectively pauses until they
    -- restock manually or AlfredTheButler's restock pipeline runs.
    return find_sigil() ~= nil
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local now = get_time_since_inject() or 0

    -- Step 1 (priority): if a portal is already open, walk into it.
    local portal = find_nmd_portal()
    if portal then
        local p = portal:get_position()
        if p then
            local dx, dy = p:x() - pp:x(), p:y() - pp:y()
            local d = math.sqrt(dx*dx + dy*dy)
            if d <= PORTAL_INTERACT_RANGE then
                if orbwalker and orbwalker.set_clear_toggle then
                    orbwalker.set_clear_toggle(false)
                end
                interact_object(portal)
                task.status = 'entering NMD portal'
                return
            end
            move.to_actor(portal)
            task.status = string.format('walking to NMD portal (%.0fm)', d)
            return
        end
    end

    -- Step 2: no portal yet -> consume a sigil to spawn one.
    local sigil = find_sigil()
    if not sigil then task.status = 'no sigil in inventory'; return end

    if not (loot_manager and loot_manager.use_item) then
        task.status = 'no loot_manager.use_item host fn'
        return
    end

    local sn = sigil.get_skin_name and sigil:get_skin_name() or '?'
    if settings.debug_mode then
        console.print('[NMD] consuming sigil: ' .. sn)
    end
    loot_manager.use_item(sigil)
    -- D4 pops a "Are you sure?" notification when consuming a sigil for
    -- the first time in a session.  utility.confirm_sigil_notification
    -- is a no-op if the popup isn't up.
    if utility and utility.confirm_sigil_notification then
        pcall(utility.confirm_sigil_notification)
    end
    tracker.last_sigil_use_t = now
    task.status = 'sigil consumed: ' .. sn
end

return task
