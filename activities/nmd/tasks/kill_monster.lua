-- activities/nmd/tasks/kill_monster.lua

local move           = require 'core.move'
local target_module  = require 'core.target'
local settings       = require 'activities.nmd.settings'
local tracker        = require 'activities.nmd.tracker'

local task = { name = 'kill_monster', status = 'idle' }

-- Tiered selection: boss > elite/champion > everything else, closest
-- within tier.  Implemented in core/target.lua so NMD / Pit / Undercity
-- share the same priority semantics.
local function pick_target()
    return target_module.pick({ range = settings.kill_range })
end

task.shouldExecute = function ()
    if not settings.kill_monsters then return false end
    return pick_target() ~= nil
end

task.Execute = function ()
    local enemy = pick_target()
    if not enemy then task.status = 'idle'; return end
    local skin = enemy:get_skin_name() or ''
    -- We have a kill target -> combat is live, so cancel the boss-room
    -- "quiet" timer.  Without this, a boss with adds (where adds take
    -- the kill-target slot) would never let boss_room_hold count down.
    tracker.hold_quiet_started_at = nil
    if target_module.is_boss(enemy) and not tracker.boss_seen then
        tracker.boss_seen = true
        -- Anchor the boss room so boss_room_hold can keep us inside the
        -- arena during invuln/leap phases when the boss briefly leaves
        -- the stream.  Use the player's current position (we're inside
        -- the arena since we just spotted the boss).
        local lp = get_local_player()
        local pp = lp and lp:get_position() or nil
        if pp then
            tracker.boss_room_anchor = { x = pp:x(), y = pp:y() }
        end
        if settings.debug_mode then console.print('[NMD] boss seen: ' .. skin) end
    end
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    -- In-range short-circuit -- see core/target.lua's IN_RANGE_DEFAULT
    -- and the comment in pit/kill_monster.lua for the rationale.
    if target_module.distance_to(enemy) <= target_module.IN_RANGE_DEFAULT then
        move.clear()
        task.status = 'in-range: ' .. skin
        return
    end
    move.to_actor(enemy)
    task.status = 'engaging ' .. skin
end

return task
