-- ---------------------------------------------------------------------------
-- activities/pit/tasks/post_boss_grace.lua
--
-- Detects pit-boss death and holds position briefly so Looteer (or any
-- auto-pickup plugin) can vacuum the boss drops before the bot walks
-- off to the glyph stone.
--
-- Background: kill_task latches `tracker.boss_seen = true` the moment a
-- boss family skin enters the kill loop, but it never stamped a
-- `boss_killed_at` -- the field was declared in tracker.lua and read
-- by exit.lua / seek_progression.lua, but never written.  The result
-- was that after a successful boss kill, seek_progression's yield
-- (`if boss_killed_at and not glyph_done`) never fired, freeroam took
-- over, and the bot walked away from the boss death spot during the
-- death animation -- pulling the player out of pickup range for the
-- chest that drops there.
--
-- Detection: kill_task already maintains tracker.boss_seen.  Here we
-- watch for "boss_seen + no enemy in kill_range for KILL_QUIET_S" as
-- the kill signal, then stamp boss_killed_at and pause nav for
-- POST_BOSS_GRACE_S seconds.  After grace, the latch stays set so
-- exit.lua's safety-valve path + seek_progression's yield work as
-- intended; this task just yields its own pulse and lets upgrade_glyph
-- fire (if the gizmo is in stream) or seek_progression / freeroam
-- take over otherwise.
--
-- Runner placement: BEFORE upgrade_glyph so we hold the kill spot
-- before walking to the gizmo, AFTER kill_monster so any stragglers
-- can still get attacked.  Yields automatically once glyph_done is
-- set so it doesn't fight the exit task at end-of-run.
-- ---------------------------------------------------------------------------

local find     = require 'core.find'
local move     = require 'core.move'
local zone     = require 'core.zone'
local tracker  = require 'activities.pit.tracker'
local settings = require 'activities.pit.settings'

-- Quiet time after boss_seen before we declare the kill.  Long enough
-- to skip a brief one-frame "no target" gap during the boss's invuln
-- transitions; short enough that the loot grace covers the death
-- animation.
local KILL_QUIET_S       = 1.5
-- How long to hold the death spot for loot pickup once the kill is
-- confirmed.  Mirrors the universal exit_grace tuning at a smaller
-- scale -- the chest+drops grace at the death spot is tighter than
-- the full end-of-run grace; just enough for Looteer to pick up the
-- pile before we move to the glyph stone.
local POST_BOSS_GRACE_S  = 6.0

local _quiet_started_t = nil
local _grace_until_t   = nil
local _nav_paused      = false

local function release_nav()
    if _nav_paused then
        move.resume()
        _nav_paused = false
    end
end

local task = { name = 'post_boss_grace', status = 'idle' }

task.shouldExecute = function ()
    -- Reset on activity boundary / end-of-run.
    if not zone.in_pit()           then release_nav(); return false end
    if not tracker.boss_seen       then release_nav(); return false end
    if tracker.glyph_done          then release_nav(); return false end

    local now = get_time_since_inject() or 0

    -- Already in grace window: own the pulse so other tasks can't move
    -- the bot until grace expires.
    if _grace_until_t and now < _grace_until_t then return true end

    -- Detect kill: enemies in kill_range reset the quiet timer.
    if find.any_enemy_in_range(settings.kill_range or 25) then
        _quiet_started_t = nil
        release_nav()
        return false
    end

    _quiet_started_t = _quiet_started_t or now
    if (now - _quiet_started_t) < KILL_QUIET_S then
        release_nav()
        return false
    end

    -- Quiet long enough -- latch the kill timestamp and arm the grace.
    if not tracker.boss_killed_at then
        tracker.boss_killed_at = now
        if settings.debug_mode then
            console.print(string.format(
                '[Pit] boss confirmed dead -- holding %.1fs for loot pickup',
                POST_BOSS_GRACE_S))
        end
    end
    _grace_until_t = now + POST_BOSS_GRACE_S
    return true
end

task.Execute = function ()
    if not _nav_paused then
        move.clear()
        move.pause()
        _nav_paused = true
    end
    -- Defensive auto-attack: if a straggler comes in range while we're
    -- holding for loot, let orbwalker swing.  We're not moving via nav
    -- so it doesn't pull the player off the loot spot -- worst case
    -- the player fires a few skills in place.
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    local now = get_time_since_inject() or 0
    local left = (_grace_until_t or now) - now
    if left < 0 then left = 0 end
    task.status = string.format('boss-loot grace (%.1fs)', left)
end

return task
