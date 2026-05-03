-- ---------------------------------------------------------------------------
-- core/kill_task.lua
--
-- Factory for the standard "fallback combat" task every activity ships
-- (NMD, Pit, Boss, Undercity, Helltide).  Replaces 5 nearly-identical
-- copies that drifted slightly over time.
--
-- The pattern they all share:
--
--   shouldExecute:
--     1. settings.kill_monsters gate
--     2. (optional) activity-specific "is the engagement window open"
--        gate -- e.g. boss requires altar_activated, helltide ignores
--        when in-maiden.
--     3. core.target.pick({range = settings.kill_range}) returns nil?
--
--   Execute:
--     1. (optional) target hijack -- something specific that ALWAYS
--        wins over normal targeting when present (boss activity's
--        Suppressor barrier).
--     2. core.target.pick({range = settings.kill_range})
--     3. (optional) boss-seen latch -- match enemy skin against
--        activity-specific patterns, set tracker.boss_seen on first
--        sight.  Distinct from target.is_boss because pit/undercity
--        bosses don't always set the host's is_boss flag at the
--        moment they spawn.
--     4. orbwalker.set_clear_toggle(true)
--     5. In-range short-circuit (move.clear) when within attack range.
--     6. Otherwise, move.to_actor(enemy).
--
-- API:
--
--   local kill_task = require 'core.kill_task'
--   return kill_task.make({
--       name             = 'kill_monster',
--       settings         = require('activities.X.settings'),
--       tracker          = require('activities.X.tracker'),  -- optional
--       extra_should     = function () return tracker.altar_activated end,
--       target_hijack    = function () return find_suppressor() end,
--       boss_skin_patterns = { 'TWR_Boss_', 'Pit_Boss_', ... },  -- optional
--       debug_label      = 'Pit',                                -- optional
--   })
--
-- Hordes is intentionally NOT a consumer -- its kill_monster has a
-- richer wave-directive priority system that doesn't fit this shape.
-- ---------------------------------------------------------------------------

local move          = require 'core.move'
local target_module = require 'core.target'

local M = {}

-- Default skin-pattern matcher: returns true if any pattern is a
-- substring of the actor's skin name.  Defensive against missing
-- get_skin_name (prop-like actors).
local function looks_like(skin, patterns)
    if not skin or not patterns then return false end
    for _, p in ipairs(patterns) do
        if skin:find(p, 1, true) then return true end
    end
    return false
end

-- Factory.  Returns the task table the runner expects.
M.make = function (cfg)
    cfg = cfg or {}
    assert(cfg.settings, 'core.kill_task: cfg.settings is required')
    local settings           = cfg.settings
    local tracker            = cfg.tracker
    local extra_should       = cfg.extra_should
    local target_hijack      = cfg.target_hijack
    local boss_patterns      = cfg.boss_skin_patterns
    local boss_seen_field    = cfg.boss_seen_field or 'boss_seen'
    local debug_label        = cfg.debug_label or '?'

    local task = { name = cfg.name or 'kill_monster', status = 'idle' }

    local function pick_enemy()
        return target_module.pick({ range = settings.kill_range })
    end

    task.shouldExecute = function ()
        if not settings.kill_monsters then return false end
        if extra_should and not extra_should() then return false end
        -- Hijack target (e.g. suppressor) is always a yes when present
        -- so we don't accidentally yield the pulse to a lower-priority
        -- task while a critical-but-non-enemy target is up.
        if target_hijack and target_hijack() then return true end
        return pick_enemy() ~= nil
    end

    task.Execute = function ()
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(true)
        end

        -- Hijack short-circuit: chase + burst the special target if any.
        if target_hijack then
            local h = target_hijack()
            if h then
                move.to_actor(h)
                task.status = 'hijack: ' ..
                    (h.get_skin_name and h:get_skin_name() or 'unknown')
                return
            end
        end

        local enemy = pick_enemy()
        if not enemy then task.status = 'idle'; return end

        local skin = enemy.get_skin_name and enemy:get_skin_name() or '?'

        -- Boss-seen latch.  Two trigger paths -- the host's is_boss
        -- predicate (always honored) plus optional skin patterns
        -- (catches pit/undercity bosses that don't flip is_boss
        -- the same frame they spawn).
        if tracker and not tracker[boss_seen_field] then
            local boss_match = target_module.is_boss(enemy)
                or (boss_patterns and looks_like(skin, boss_patterns))
            if boss_match then
                tracker[boss_seen_field] = true
                if settings.debug_mode then
                    console.print(string.format('[%s] boss seen: %s',
                        debug_label, tostring(skin)))
                end
            end
        end

        -- In-range short-circuit -- DON'T pull the walker toward an
        -- enemy already in attack range.  orbwalker auto-attacks from
        -- where we stand; clearing the walker target prevents the
        -- host pathfinder from still routing toward a stale 100y
        -- destination (the user-visible "orbwalker point WAYYY too
        -- far" symptom).
        if target_module.distance_to(enemy) <= target_module.IN_RANGE_DEFAULT then
            move.clear()
            task.status = 'in-range: ' .. tostring(skin)
            return
        end

        move.to_actor(enemy)
        task.status = 'engaging ' .. tostring(skin)
    end

    return task
end

return M
