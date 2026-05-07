-- activities/hordes/tasks/kill_monster.lua
--
-- Hordes is mostly stay-in-place + AOE.  We pick the closest hostile each
-- pulse and walk-toward it; orbwalker handles the actual attacks.  Aether
-- masses are prioritized because killing them = currency + wave progress.

local move        = require 'core.move'
local rotation    = require 'core.rotation_bridge'
local settings    = require 'activities.hordes.settings'
local quest_state = require 'activities.hordes.quest_state'
local tracker     = require 'activities.hordes.tracker'

local task = { name = 'kill_monster', status = 'idle' }

-- Directive cache: read once per pulse so each pick_target call doesn't
-- re-scan get_quests().  Fresh enough because quest objectives only flip
-- at wave boundaries.
local last_directive_pulse_t = 0
local cached_directive       = nil
local DIRECTIVE_TTL_S        = 0.5

local function get_directive()
    local now = get_time_since_inject and get_time_since_inject() or 0
    if (now - last_directive_pulse_t) < DIRECTIVE_TTL_S then
        return cached_directive
    end
    last_directive_pulse_t = now
    local d, txt = quest_state.read_directive()
    cached_directive = d
    -- Mirror onto tracker for status overlay / debug.
    tracker.wave_directive       = d
    tracker.wave_directive_text  = txt
    return d
end

-- Map a wave directive to a predicate that matches actors in that family.
-- Returns true if the actor's skin/special-rank matches the directive.
local function actor_matches_directive(directive, skin, special)
    if not directive then return false end
    if directive == 'mass'             then return skin:find('Mass',   1, true) ~= nil
                                         or  skin:find('Zombie', 1, true) ~= nil end
    if directive == 'spire'            then return skin:find('Soulspire', 1, true) ~= nil end
    if directive == 'goblin'           then return skin:find('goblin',    1, true) ~= nil end
    if directive == 'hellseeker'       then return skin:find('HellSeeker', 1, true) ~= nil end
    if directive == 'miniboss'         then return skin:find('Miniboss',   1, true) ~= nil end
    if directive == 'lord'             then return special end   -- aether lords spawn as elites
    if directive == 'hellborne'        then return special end   -- hellborne are champion/elite-ranked
    -- 'boss' directive: ONLY the three Council members + Bartuc, the
    -- four enemies that live in the boss room post-portal.  We
    -- intentionally don't match generic 'boss' substring here -- skins
    -- like BSK_skeleton_boss / BSK_cannibal_brute_boss / BSK_elias_boss
    -- are wave-script spawns in the arena, not the actual end boss; tier
    -- 2 still picks them up via the BSK_*_boss family check below.
    if directive == 'boss'             then return skin:find('Bartuc',  1, true) ~= nil
                                          or skin:find('Council', 1, true) ~= nil end
    if directive == 'aether_structure' then return skin:find('BonusAether', 1, true) ~= nil end
    -- aether_collect targets currency drops, not enemies; nothing to promote
    return false
end

-- High-priority objective skins.  Lifted from HordeDev/tasks/horde.lua's
-- is_objective() + bomber:get_target() combined logic.  Order in the
-- tier checks below: hellborne (boss/champion/elite) > masses/aether
-- > minibosses/seekers/goblins/markers > soulspires > generic enemies.
--
-- Why prioritize these:
--   * masses/zombies/aether structures: aether currency on death
--   * soulspires: required to clear waves; if alive, wave isn't over
--   * markers (BSK_Occupied): membrane that gates progression
--   * BSK_Miniboss / BSK_HellSeeker / BSK_treasure_goblin: extra rewards
--   * S05_coredemon / S05_fallen / boss skins: scripted spawns
local OBJ_SKINS_ANY = {
    'BSK_Structure_BonusAether',
    'MarkerLocation_BSK_Occupied',
    'BSK_treasure_goblin',
    'BSK_HellSeeker',
    'BSK_Miniboss',
    'BSK_elias_boss', 'BSK_cannibal_brute_boss', 'BSK_skeleton_boss',
    'S05_coredemon', 'S05_fallen',
}

local function is_objective_any(skin)
    if not skin then return false end
    for _, p in ipairs(OBJ_SKINS_ANY) do
        if skin:find(p, 1, true) then return true end
    end
    return false
end

-- Aether-mass: needs a health > 1 check (corpses keep spawning aether briefly).
local function is_aether_mass(skin)
    if not skin then return false end
    return (skin:find('Mass',   1, true)
         or skin:find('Zombie', 1, true)) ~= nil
end

local function is_soulspire(skin)
    return skin and skin:find('Soulspire', 1, true) ~= nil
end

-- Scan get_all_actors() for objective-skinned candidates (Soulspires,
-- Aether Masses, BSK structures, BSK bosses, MarkerLocation_BSK_*, etc.)
-- that target_selector.get_near_target_list omits because the host
-- classifies them as structures/destructibles rather than enemies.
-- Without this scan, the bot would only see "real" monsters in the 60y
-- enemy stream and idle when the wave's progression-gating objects sit
-- across the arena -- the user-reported "horde arena is one big room
-- and we don't see events/spires/masses on the other side."
local function scan_objective_actors(pp, range)
    local out = {}
    if not actors_manager or not actors_manager.get_all_actors then return out end
    local r2 = range * range
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn then
            local interesting = is_aether_mass(sn)
                              or is_soulspire(sn)
                              or is_objective_any(sn)
                              or sn:find('BSK_', 1, true)   -- broad BSK_* catch
            if interesting then
                local p = a.get_position and a:get_position() or nil
                if p then
                    local dx = p:x() - pp:x()
                    local dy = p:y() - pp:y()
                    if dx*dx + dy*dy <= r2 then
                        local hp   = a.get_current_health and a:get_current_health() or 0
                        local dead = a.is_dead and a:is_dead() or false
                        if hp > 1 and not dead then
                            out[#out + 1] = a
                        end
                    end
                end
            end
        end
    end
    return out
end

local function pick_target()
    local lp = get_local_player()
    if not lp then return nil end
    local pp = get_player_position and get_player_position() or lp:get_position()
    if not pp then return nil end
    if not target_selector or not target_selector.get_near_target_list then return nil end
    local enemies = target_selector.get_near_target_list(pp, settings.kill_range)

    -- Augment with structure-class objectives the enemy scan omits.
    -- These are merged into the same tiered selection below; their
    -- skin-based tiering (mass / spire / objective) is unchanged.
    local extras = scan_objective_actors(pp, settings.kill_range)
    if #extras > 0 then
        enemies = enemies or {}
        -- Dedup by actor identity -- same Lua-side actor object wouldn't
        -- normally appear in both lists (target_selector excludes
        -- structures), but be defensive for actors flagged as both.
        local seen = {}
        for _, e in pairs(enemies) do seen[e] = true end
        for _, a in ipairs(extras) do
            if not seen[a] then enemies[#enemies + 1] = a end
        end
    end

    -- Read the wave directive from quest objectives.  When the active
    -- objective says "Defeat 5 Soulspires" we want to ignore everything
    -- else and chase spires; without a directive, fall back to the
    -- static priority order.
    local directive = get_directive()

    -- Tiered selection.  Walk all candidates once, classify into tiers,
    -- pick the closest from the highest non-empty tier.
    --
    -- OBJECTIVES BEFORE ELITES.  Per user direction: aether events
    -- don't spawn until objectives are cleared, so even a 5y elite
    -- waits while we knock down a 30y soulspire / mass / scripted
    -- objective.  Elites tier sits below all the wave-progression
    -- targets; bosses still top everything (true boss kills end the
    -- run).
    --
    --   tier 1: matches the active wave directive (dynamic, top)
    --   tier 2: BSK bosses (Bartuc / Council scripted boss kills)
    --   tier 3: aether masses (currency + wave progress)
    --   tier 4: soulspires (gate wave clear)
    --   tier 5: scripted objectives (Miniboss / goblins / markers / S05_*)
    --   tier 6: special-rank champions / elites
    --   tier 7: anything else
    --
    -- BSK_*_boss skins go in tier 2 specifically; generic is_boss flag
    -- without that skin family lands in tier 6 (some "boss"-flagged
    -- actors are sub-objectives that aren't progression-critical).
    local tiers = { {}, {}, {}, {}, {}, {}, {} }
    for _, e in pairs(enemies or {}) do
        local hp = e.get_current_health and e:get_current_health() or 0
        if hp > 1 then
            local ep = e:get_position()
            if ep then
                local dx = ep:x() - pp:x()
                local dy = ep:y() - pp:y()
                local d  = math.sqrt(dx*dx + dy*dy)
                if d <= settings.kill_range then
                    local skin    = e.get_skin_name and e:get_skin_name() or ''
                    local boss    = e.is_boss      and e:is_boss()      or false
                    local champ   = e.is_champion  and e:is_champion()  or false
                    local elite   = e.is_elite     and e:is_elite()     or false
                    local special = boss or champ or elite
                    local is_bsk_boss = skin:find('BSK_', 1, true)
                                    and (skin:find('_boss', 1, true)
                                      or skin:find('Bartuc', 1, true)
                                      or skin:find('Council', 1, true))

                    local tier
                    if actor_matches_directive(directive, skin, special) then
                        tier = 1
                    elseif is_bsk_boss                then tier = 2
                    elseif is_aether_mass(skin)       then tier = 3
                    elseif is_soulspire(skin)         then tier = 4
                    elseif is_objective_any(skin)     then tier = 5
                    elseif special                    then tier = 6
                    else                                   tier = 7 end

                    local cur = tiers[tier]
                    if not cur.actor or d < cur.d then
                        cur.actor, cur.d = e, d
                    end
                end
            end
        end
    end

    for i = 1, 7 do
        if tiers[i].actor then return tiers[i].actor end
    end
    return nil
end

task.shouldExecute = function ()
    if not settings.kill_monsters then return false end
    return pick_target() ~= nil
end

task.Execute = function ()
    local target = pick_target()
    if not target then
        rotation.set_kill_target(nil)
        task.status = 'idle'
        return
    end
    -- Tell UniversalRotation which actor we're engaging.  UR reads
    -- _G.EXTERNAL_ROTATION_TARGET in its spell loop and casts at it when
    -- valid, which keeps the bot's facing aligned with our walk target.  Without
    -- this, UR would spam the closest plain monster while WarMachine is
    -- walking toward a 30y Soulspire and the bot would constantly turn
    -- around mid-walk to face the closer target.
    rotation.set_kill_target(target)
    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(true)
    end
    -- In-range short-circuit (see core/target.lua's IN_RANGE_DEFAULT).
    -- Hordes-specific note: spires need to be CLOSE for the bot's
    -- AOE; same threshold works here since IN_RANGE_DEFAULT (8y) is
    -- well within typical AOE radius.
    local target_mod = require 'core.target'
    if target_mod.distance_to(target) <= target_mod.IN_RANGE_DEFAULT then
        move.clear()
        task.status = 'in-range: ' .. tostring(target:get_skin_name())
        return
    end
    move.to_actor(target)
    task.status = 'engaging ' .. tostring(target:get_skin_name())
end

return task
