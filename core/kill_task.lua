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
    -- Skin substrings that, when present, EXCLUDE the actor from
    -- triggering the boss_seen latch -- even if D4's host
    -- is_boss(actor) returns true.  Used to ignore miniboss-class
    -- spawns (e.g. enticement-wave summons in undercity) that the
    -- host flags as is_boss=true but are NOT the floor's real boss.
    -- Without this, picking up a miniboss flips boss_seen and
    -- shuts down enticement / interact_poi / floor_portal etc.
    -- Empty by default; activities opt in by passing patterns.
    local boss_neg_patterns  = cfg.boss_skin_negative_patterns
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
        -- Hijack short-circuit (special non-enemy targets like the
        -- boss-altar Suppressor barrier) bypasses the boss-intro gate
        -- because hijacks aren't auto-attack -- they're directed
        -- positioning that we want to fire even during the intro.
        if target_hijack then
            local h = target_hijack()
            if h then
                if orbwalker and orbwalker.set_clear_toggle then
                    orbwalker.set_clear_toggle(true)
                end
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
        -- the same frame they spawn).  Also stamps `<boss_seen_field>_at`
        -- with the wall clock so the boss-intro gate below can hold
        -- auto-attack for the configured grace.
        if tracker and not tracker[boss_seen_field] then
            local boss_match = target_module.is_boss(enemy)
                or (boss_patterns and looks_like(skin, boss_patterns))
            -- Negative-pattern exclusion: even if is_boss()=true or
            -- a positive pattern matched, drop the latch trigger
            -- when the skin matches an excluded substring (e.g.
            -- "Miniboss").  D4 flags miniboss-class wave spawns as
            -- is_boss=true, but they're not THE floor boss --
            -- letting them flip the latch shuts down the activity's
            -- enticement / POI / floor-portal flow even though the
            -- run isn't actually at the boss room yet.
            if boss_match and boss_neg_patterns
               and looks_like(skin, boss_neg_patterns)
            then
                boss_match = false
            end
            if boss_match then
                tracker[boss_seen_field] = true
                tracker[boss_seen_field .. '_at'] = get_time_since_inject() or 0
                if settings.debug_mode then
                    console.print(string.format('[%s] boss seen: %s',
                        debug_label, tostring(skin)))
                end
            end
        end

        -- Boss intro delay.  Bosses in NMD / Pit / Undercity have a
        -- short vulnerability-transition window after they spawn where
        -- attacking too early wastes DPS or desyncs mechanics.  When
        -- settings.boss_intro_delay > 0 and we're inside that window,
        -- hold orbwalker off and stop walking -- but stay on the kill
        -- pulse so freeroam doesn't pull us off the boss.  The original
        -- WonderCity / SigilRunner / ArkhamAsylum plugins all had this;
        -- it was previously declared in our settings but never wired up.
        local intro_delay = settings.boss_intro_delay or 0
        if intro_delay > 0
           and tracker and tracker[boss_seen_field .. '_at']
        then
            local seen_at = tracker[boss_seen_field .. '_at']
            local elapsed = (get_time_since_inject() or 0) - seen_at
            if elapsed < intro_delay then
                if orbwalker and orbwalker.set_clear_toggle then
                    orbwalker.set_clear_toggle(false)
                end
                move.clear()
                task.status = string.format('boss intro delay (%.1fs)',
                    intro_delay - elapsed)
                return
            end
        end

        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(true)
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
