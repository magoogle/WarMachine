-- ---------------------------------------------------------------------------
-- activities/hordes/tasks/open_chest.lua
--
-- Post-boss reward phase.  After the boss dies in the boss arena there
-- are two interactable surfaces:
--
-- 1) BurningAether -- aether currency drops as floor pickups.  Walk over
--    them (or interact) to add to currency.  Skin: 'BurningAether'.
--
-- 2) Reward chests -- multiple skins appear, but the bot only engages
--    a curated subset per user direction:
--       BSK_UniqueOpChest_GreaterAffix    -- top priority (settings.do_chest_ga)
--       BSK_UniqueOpChest_Materials       -- secondary (settings.chest_secondary)
--       BSK_UniqueOpChest_Gold            -- secondary alternative
--    Materials and Gold are mutually exclusive (only enough aether for
--    one after GA), exposed as a single dropdown in the GUI.  Equipment
--    is intentionally NOT in the priority list.
--    Each costs aether to open.  Cost isn't queryable from the host, so
--    we attempt in priority order and detect outcome by watching
--    is_interactable across a retry window.
--
-- Live skins are decorated with runtime suffixes (e.g. `_01_Dyn`), so
-- chest indexing canonicalizes by extracting the TIER token (the word
-- right after `BSK_UniqueOpChest_`).  The exact-skin lookup that was
-- here previously silently missed every chest in production builds --
-- the user-reported "horde is not looting the chests" bug.
--
-- Click pattern: hammer interact_object on a CLICK_COOLDOWN_S cadence
-- until either the chest flips non-interactable (SUCCESS) or we hit
-- CLICK_TIMEOUT_S of unsuccessful retries (FAILURE -> insufficient
-- aether or silently rejected; mark failed and fall through to the
-- next priority).  Mirrors the loot_chest retry pattern in NMD.
--
-- Once every enabled chest tier is either opened or marked-failed,
-- tracker.chest_phase_done is set and exit.lua takes over.
-- ---------------------------------------------------------------------------

local move     = require 'core.move'
local find     = require 'core.find'
local settings = require 'activities.hordes.settings'
local tracker  = require 'activities.hordes.tracker'

local task = {
    name              = 'open_chest',
    status            = 'idle',
    -- Per-attempt state.  Cleared after each attempt resolves.
    pending_skin      = nil,    -- the canonical tier we're trying ('GreaterAffix' / 'Materials' / 'Gold')
    pending_t         = nil,    -- time of the FIRST click on this attempt
    last_click_t      = nil,    -- time of the most recent click (cooldown gate)
    click_count       = 0,
}

-- Click retry pattern (mirrors loot_chest in NMD): hammer interact_object
-- on a cooldown until the chest's is_interactable flips false (success)
-- or we hit the timeout (= insufficient aether / silently rejected).
local CLICK_COOLDOWN_S    = 1.0
local CLICK_TIMEOUT_S     = 8.0    -- mark failed after this many seconds of no flip
local AETHER_PICKUP_RANGE = 1.8

-- Priority list.  Match each priority entry's `tier` against the live
-- chest skin via PREFIX (since the runtime sometimes decorates the skin
-- with `_01_Dyn` etc., the historical exact-skin lookup silently missed
-- every chest -- the user-reported "horde is not looting the chests"
-- bug).  GA is fixed at slot 1; the secondary slot is resolved at
-- run-time from settings.chest_secondary.
local TIER_GA        = 'GreaterAffix'
local TIER_MATERIALS = 'Materials'
local TIER_GOLD      = 'Gold'

local SKIN_PREFIX = 'BSK_UniqueOpChest_'

local function find_aether_drop()
    return find.closest({
        patterns = { 'burningaether' },
        require_interactable = false,    -- aether floor drops aren't interactable
        source = 'all',
    })
end

-- Extract the tier ('GreaterAffix' / 'Equipment' / 'Materials' / 'Gold')
-- from a live chest skin like 'BSK_UniqueOpChest_GreaterAffix_01_Dyn'.
-- Returns nil if the skin doesn't match the BSK chest family.
local function tier_of(skin)
    if not skin then return nil end
    if skin:sub(1, #SKIN_PREFIX) ~= SKIN_PREFIX then return nil end
    -- After the prefix, the next token (up to the next '_' or end of
    -- string) is the tier.  Examples:
    --   'BSK_UniqueOpChest_GreaterAffix'           -> 'GreaterAffix'
    --   'BSK_UniqueOpChest_GreaterAffix_01_Dyn'    -> 'GreaterAffix'
    --   'BSK_UniqueOpChest_Materials_01'           -> 'Materials'
    local rest = skin:sub(#SKIN_PREFIX + 1)
    local us = rest:find('_', 1, true)
    if us then return rest:sub(1, us - 1) end
    return rest
end

-- Build a (tier -> actor) map keyed by canonical tier name (not full
-- skin), so the priority lookup can find the chest regardless of any
-- runtime suffix on the skin.
local function index_chests()
    local out = {}
    if not actors_manager or not actors_manager.get_all_actors then return out end
    for _, a in pairs(actors_manager:get_all_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or ''
        local t = tier_of(sn)
        if t then
            -- Multiple actors might share a tier across the arena (rare,
            -- but defensive).  Prefer the one that's still interactable.
            local existing = out[t]
            if not existing
               or (a.is_interactable and a:is_interactable())
            then
                out[t] = a
            end
        end
    end
    return out
end

-- Resolve the priority list from current settings.  GA always sits at
-- slot 1 when enabled; slot 2 is whatever the secondary dropdown says
-- (Materials / Gold / nothing).  Returns a list of { tier = 'GreaterAffix',
-- label = 'GA' } pairs.
local function build_priority()
    local out = {}
    if settings.do_chest_ga then
        out[#out + 1] = { tier = TIER_GA, label = 'GA' }
    end
    local sec = settings.chest_secondary
    if sec == TIER_MATERIALS then
        out[#out + 1] = { tier = TIER_MATERIALS, label = 'Materials' }
    elseif sec == TIER_GOLD then
        out[#out + 1] = { tier = TIER_GOLD, label = 'Gold' }
    end
    return out
end

-- Walk the priority list; first match (= a chest of an enabled tier
-- that hasn't been marked failed AND is still interactable) wins.
local function find_priority_chest(chests)
    for _, p in ipairs(build_priority()) do
        if not (tracker.failed_chest_skins or {})[p.tier] then
            local a = chests[p.tier]
            if a and a.is_interactable and a:is_interactable() then
                return a, p.tier, p.label
            end
        end
    end
    return nil
end

-- Resolve the pending click: did the previously-clicked chest go
-- non-interactable (success) or are we still hammering it on cooldown?
-- Updates tracker latches accordingly.
local function resolve_pending(now, chests)
    if not task.pending_skin then return end
    local elapsed = now - (task.pending_t or 0)
    local actor = chests[task.pending_skin]
    -- Success: actor gone from stream OR no longer interactable.
    if not actor
       or not actor.is_interactable
       or not actor:is_interactable()
    then
        tracker.chest_opened_count = (tracker.chest_opened_count or 0) + 1
        tracker.chest_opened       = true
        if settings.debug_mode then
            console.print(string.format(
                '[Hordes] chest opened: %s (%d clicks)',
                task.pending_skin, task.click_count or 0))
        end
        task.pending_skin = nil
        task.pending_t    = nil
        task.last_click_t = nil
        task.click_count  = 0
        return
    end
    -- Failure: still interactable past CLICK_TIMEOUT_S of retries.
    -- Likely insufficient aether or the chest is bugged -- mark failed
    -- and move on so we don't loop forever.
    if elapsed >= CLICK_TIMEOUT_S then
        tracker.failed_chest_skins = tracker.failed_chest_skins or {}
        tracker.failed_chest_skins[task.pending_skin] = true
        if settings.debug_mode then
            console.print(string.format(
                '[Hordes] chest failed after %d clicks: %s (likely insufficient aether)',
                task.click_count or 0, task.pending_skin))
        end
        task.pending_skin = nil
        task.pending_t    = nil
        task.last_click_t = nil
        task.click_count  = 0
        return
    end
    -- Still within the retry window; Execute will fire another click on
    -- cooldown.
end

-- Are there any enabled, not-failed chest skins still interactable?
-- exit.lua reads this via the tracker.chest_phase_done latch.
local function any_remaining_attempts(chests)
    return find_priority_chest(chests) ~= nil
end

-- Update the "we're done with the chest phase" latch.  Set when there
-- are no more attempts to make AND we're not waiting on a pending click.
local function update_phase_done(chests)
    if task.pending_skin then return end
    if not tracker.boss_killed then return end
    if any_remaining_attempts(chests) then return end
    if not tracker.chest_phase_done then
        tracker.chest_phase_done = true
        if settings.debug_mode then
            console.print(string.format(
                '[Hordes] chest phase done (opened=%d, failed=%d)',
                tracker.chest_opened_count or 0,
                (function ()
                    local n = 0
                    for _ in pairs(tracker.failed_chest_skins or {}) do n = n + 1 end
                    return n
                end)()))
        end
    end
end

task.shouldExecute = function ()
    -- Master toggle off -> skip the entire chest phase.
    if not settings.do_chests then return false end
    -- All sub-types disabled -> nothing to attempt.  Cheaper than
    -- iterating index_chests + build_priority each pulse.
    if not settings.do_chest_ga
       and (settings.chest_secondary == nil or settings.chest_secondary == 'None')
    then
        return false
    end

    local now = get_time_since_inject() or 0
    local chests = index_chests()

    -- Resolve any in-flight click first so the rest of the logic works
    -- with up-to-date latches.
    resolve_pending(now, chests)
    update_phase_done(chests)

    -- Boss-killed back-fill: if a chest is in stream the boss is dead.
    if not tracker.boss_killed and any_remaining_attempts(chests) then
        tracker.boss_killed = true
    end
    if not tracker.boss_killed then return false end

    -- Done with all attempts -> we're done; let exit fire.
    if tracker.chest_phase_done then return false end

    -- Still resolving a click -> own the pulse so we don't drift.
    if task.pending_skin then return true end

    -- Anything to do?  Pickups OR a remaining attempt.
    if find_aether_drop() then return true end
    return any_remaining_attempts(chests)
end

task.Execute = function ()
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local now = get_time_since_inject() or 0

    -- Pending click in flight: keep hammering on cooldown until the
    -- chest's is_interactable flips false (success) or we hit the
    -- timeout (failure -> resolve_pending marks failed and clears).
    if task.pending_skin then
        local chests = index_chests()
        local actor = chests[task.pending_skin]
        if not actor then
            task.status = 'pending ' .. task.pending_skin .. ' (actor lost)'
            return
        end
        local p = actor.get_position and actor:get_position() or nil
        if p then
            local d = find.dist2d(pp, p)
            if d > 3 then
                -- Drifted out -- walk back in.
                move.to_actor(actor)
                task.status = string.format('returning to %s chest (%.0fm)',
                    task.pending_skin, d)
                return
            end
        end
        if orbwalker and orbwalker.set_clear_toggle then
            orbwalker.set_clear_toggle(false)
        end
        if not task.last_click_t or (now - task.last_click_t) >= CLICK_COOLDOWN_S then
            interact_object(actor)
            task.last_click_t = now
            task.click_count  = (task.click_count or 0) + 1
            if settings.debug_mode then
                console.print(string.format('[Hordes] click #%d on %s chest',
                    task.click_count, task.pending_skin))
            end
        end
        task.status = string.format('opening %s (#%d)',
            task.pending_skin, task.click_count or 0)
        return
    end

    -- Phase 1: collect aether drops (free currency).
    local drop = find_aether_drop()
    if drop then
        local p = drop:get_position()
        if p then
            local d = find.dist2d(pp, p)
            if d <= AETHER_PICKUP_RANGE then
                if drop.is_interactable and drop:is_interactable() then
                    interact_object(drop)
                end
                task.status = 'collecting aether'
                return
            end
            move.to_pos(p)
            task.status = string.format('walking to aether drop (%.0fm)', d)
            return
        end
    end

    -- Phase 2: chest open.  Walk to the highest-priority enabled chest
    -- and start hammering.  Subsequent pulses hit the pending-click
    -- branch above for retry-on-cooldown until success / timeout.
    local chests = index_chests()
    local chest, tier, label = find_priority_chest(chests)
    if not chest then
        task.status = 'no chest available'
        return
    end

    local p = chest:get_position()
    if not p then return end
    local d = find.dist2d(pp, p)

    if d > 3 then
        move.to_actor(chest)
        task.status = string.format('walking to %s chest (%.0fm)', label, d)
        return
    end

    if orbwalker and orbwalker.set_clear_toggle then
        orbwalker.set_clear_toggle(false)
    end
    interact_object(chest)
    task.pending_skin = tier
    task.pending_t    = now
    task.last_click_t = now
    task.click_count  = 1
    if settings.debug_mode then
        console.print('[Hordes] click #1 on ' .. label .. ' chest (' .. tier .. ')')
    end
    task.status = 'opening ' .. label
end

return task
