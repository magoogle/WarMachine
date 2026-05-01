-- ---------------------------------------------------------------------------
-- activities/nmd/tasks/boss_room_hold.lua
--
-- Once we've spotted the boss, lock the bot inside the arena.  Without this
-- task the runner falls through to freeroam_fallback every time the boss
-- briefly leaves the actor stream (invuln phases, leap, summon, teleport,
-- etc.) -- and the Batmobile happily picks a path node OUTSIDE the boss
-- arena, the bot dashes through the doorway, and the encounter resets.
--
-- Reproduction in the live snapshot that motivated this fix:
--   tracker.boss_seen   = true
--   tracker.dungeon_done = false
--   live_enemies_in_30  = 0      <- boss off-screen for one tick
--   active task         = freeroam_fallback
--   pp                  = changing rapidly across the dungeon
--
-- This task sits BETWEEN kill_monster and freeroam_fallback in the runner:
--   * higher priority than freeroam: it claims the pulse first
--   * lower priority than kill_monster: as soon as a target is up,
--     kill_monster takes the pulse back and we attack
-- It also actively disables Batmobile freeroam so any momentum from a
-- previous freeroam_fallback pulse stops immediately.
-- ---------------------------------------------------------------------------

local move    = require 'core.move'
local tracker = require 'activities.nmd.tracker'

local task = { name = 'boss_room_hold', status = 'idle' }

local ARRIVE_RADIUS = 4.0   -- "close enough" to the anchor; stop walking
local ANCHOR_QUIET_S = 4.0  -- continuous "no enemy" time at anchor that
                            -- counts as "boss is dead" -> latch boss_killed_at

task.shouldExecute = function ()
    if not tracker.boss_seen then return false end
    if tracker.boss_killed_at then return false end
    if tracker.dungeon_done   then return false end
    if not tracker.boss_room_anchor then return false end
    return true
end

task.Execute = function ()
    -- Stop the walker (it may have been driven on the previous pulse
    -- by interact_poi or freeroam).  We want to STAY in the arena.
    local ok, walker = pcall(require, 'core.walker')
    if ok and walker and walker.stop then walker.stop() end
    -- Keep auto-attack on so we hit the boss the instant it returns to
    -- the stream (orbwalker handles target selection from there).
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end

    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end

    local a = tracker.boss_room_anchor
    local dx = pp:x() - a.x
    local dy = pp:y() - a.y
    local d  = math.sqrt(dx*dx + dy*dy)

    if d <= ARRIVE_RADIUS then
        -- We're at the anchor with no kill target.  Start (or continue)
        -- the "quiet" timer; once we've been quiet for ANCHOR_QUIET_S,
        -- the boss is dead.  Latch boss_killed_at so exit can fire.
        local now = get_time_since_inject() or 0
        tracker.hold_quiet_started_at = tracker.hold_quiet_started_at or now
        if not tracker.boss_killed_at and (now - tracker.hold_quiet_started_at) >= ANCHOR_QUIET_S then
            tracker.boss_killed_at = now
            task.status = 'boss confirmed dead'
            return
        end
        task.status = 'holding boss anchor'
        return
    end

    -- Walking back to anchor; reset quiet timer (we left the spot)
    tracker.hold_quiet_started_at = nil
    move.to_pos({ x = a.x, y = a.y, z = pp:z() }, { arrive_radius = ARRIVE_RADIUS })
    task.status = string.format('returning to boss anchor (%.1fm)', d)
end

return task
