-- ---------------------------------------------------------------------------
-- core/mount_manager.lua
--
-- Toggles the player's mount (Z key) based on enemy proximity.  Lifted from
-- HelltideRevamped where it shipped first.  Promoted to a shared
-- WarMachine module so every activity (helltide, overworld travel during
-- warplan transit, etc.) can use it identically.
--
-- Behavior:
--   * Mount when caller says "ok to mount" AND no enemy within MOUNT_RADIUS
--   * Dismount when mounted AND any enemy within DISMOUNT_RADIUS
--   * Hysteresis (MOUNT_RADIUS > DISMOUNT_RADIUS) prevents flapping
--   * 1.5s cooldown between Z presses prevents key-spam
-- ---------------------------------------------------------------------------

local M = {}

local VK_Z              = 0x5A
local TOGGLE_COOLDOWN_S = 1.5
local MOUNT_RADIUS      = 25
local DISMOUNT_RADIUS   = 12

local last_toggle_t = -math.huge

local function is_mounted()
    local lp = get_local_player()
    if not lp or not lp.get_attribute then return false end
    local ok, val = pcall(function () return lp:get_attribute(attributes.CURRENT_MOUNT) end)
    return ok and val and val < 0
end

local function nearest_enemy_distance()
    local lp = get_local_player()
    if not lp then return math.huge end
    local pp = lp:get_position()
    if not pp then return math.huge end
    if not target_selector or not target_selector.get_near_target_list then
        return math.huge
    end
    local enemies = target_selector.get_near_target_list(pp, MOUNT_RADIUS + 5)
    local closest = math.huge
    for _, e in pairs(enemies or {}) do
        local ep = e.get_position and e:get_position() or nil
        if ep then
            local d = pp:dist_to(ep)
            if d < closest then closest = d end
        end
    end
    return closest
end

local function press_z()
    local now = get_time_since_inject()
    if (now - last_toggle_t) < TOGGLE_COOLDOWN_S then return false end
    last_toggle_t = now
    if utility and utility.send_key_press then utility.send_key_press(VK_Z) end
    return true
end

-- update(opts) -> 'mounted' | 'dismounted' | 'noop'
--   opts.disabled       no-op (master kill-switch)
--   opts.force_dismount dismount if mounted (about to interact)
--   opts.allow_mount    may mount when no enemies near (caller-supplied
--                       state hint -- defaults to true if absent)
M.update = function (opts)
    opts = opts or {}
    if opts.disabled then return 'noop' end

    local mounted = is_mounted()

    if opts.force_dismount then
        if mounted and press_z() then return 'dismounted' end
        return 'noop'
    end

    if mounted then
        local d = nearest_enemy_distance()
        if d <= DISMOUNT_RADIUS then
            if press_z() then return 'dismounted' end
        end
        return 'noop'
    end

    -- Default to "may mount" if caller didn't specify.
    if opts.allow_mount == false then return 'noop' end

    local d = nearest_enemy_distance()
    if d > MOUNT_RADIUS then
        if press_z() then return 'mounted' end
    end
    return 'noop'
end

M.is_mounted = is_mounted
M.nearest_enemy_distance = nearest_enemy_distance

return M
