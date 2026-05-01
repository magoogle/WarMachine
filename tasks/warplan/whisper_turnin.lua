-- ---------------------------------------------------------------------------
-- tasks/warplan/whisper_turnin.lua
--
-- Tree-of-Whispers / Bounty Raven turn-in piggyback.  Three-click
-- sequence: NPC interact -> reward card -> Accept button.  Driven by
-- the bounty quest's objective text rather than fixed timing -- D4
-- updates the objective when the panel opens, so we can use that as
-- the "UI is actually ready" signal before firing click points.
--
-- Quest state transitions (live-validated S09):
--
--   "Return to the Tree of Whispers..."   <- panel closed, ready
--   (interact NPC)
--   "Choose your reward"                  <- panel open, ready for click
--   (click reward card -- no objective change; brief fixed wait)
--   (click Accept)
--   (quest disappears entirely from log)  <- success
--
-- We watch the panel-open transition before firing the reward click so
-- we don't blast clicks into empty screen space when the NPC interact
-- failed to open the UI.  The reward-to-accept gap is fixed time (no
-- intermediate state to check), and accept-to-success is verified by
-- the quest being gone from the log.
--
-- Failure mode: if the panel doesn't open within NPC_CLICK_TIMEOUT_S,
-- retry the NPC click (up to MAX_RETRIES).  If the quest is still in
-- the log after the accept click + ACCEPT_VERIFY_TIMEOUT_S, retry the
-- whole sequence.  Each retry sends Escape first to clear any open UI.
-- ---------------------------------------------------------------------------

local move        = require 'core.move'
local interact    = require 'core.interact'
local settings    = require 'core.settings'
local whispers    = require 'core.whispers'
local zone        = require 'core.zone'

local task = {
    name        = 'whisper_turnin',
    status      = nil,
    state       = nil,
    state_t     = nil,
    attempts    = 0,
    -- Snapshot of the bounty objective text right before we click the
    -- NPC.  Used to detect the "Return -> Choose" panel-open transition
    -- on first attempt; nil/sticky on retries (fall back to timing).
    pre_click_objective = nil,
    -- In-state interact-retry counter + last-fire timestamp.  We keep
    -- re-firing interact_object every INTERACT_RETRY_INTERVAL_S until
    -- the panel verifies open (transition) or we've fired enough times
    -- in sticky mode.  Reset on entering / leaving INTERACTING_NPC.
    interacts_fired   = 0,
    last_interact_t   = nil,
    interact_npc      = nil,    -- cached actor for re-interact (nil = re-find)
}

-- Fixed-timing fallback used when the objective text is already "Choose
-- your reward" before we even click (sticky state from a prior attempt
-- or a manual open).  We can't see the transition flip in that case,
-- so we wait a generous window to cover D4's built-in walk-up to the
-- NPC (interact_object triggers walk-and-click rather than instant
-- click) plus the panel render.  3s handles the typical case; if the
-- player was already next to the NPC, the extra time is harmless.
local PANEL_RENDER_S       = 3.0

-- States:
--   nil                  -> idle, waiting to start
--   'WALK'               -> moving toward NPC
--   'INTERACTING_NPC'    -> clicked NPC, waiting for panel-open quest text
--   'CLICKING_CARD'      -> clicked reward card, waiting brief before Accept
--   'CLICKING_ACCEPT'    -> clicked Accept, waiting for quest disappearance
--   'WAIT_RETRY'         -> short pause between retries

local INTERACT_RANGE       = 30.0    -- D4 walks the last few yards itself
-- Panel-open timeout includes D4's built-in walk-up time (interact_object
-- triggers a walk-and-click, not an instant click).  From ~30y the
-- walk-up alone is ~4-5s in town, then ~0.5s for panel render.  Set
-- comfortably so the in-state interact-retry loop has time to land.
local NPC_CLICK_TIMEOUT_S  = 8.0
-- Inside INTERACTING_NPC we re-fire interact_object on this cadence
-- until either the panel-open signal arrives (transition) or the
-- fixed-timing fallback elapses (sticky state).  Mirrors the pattern
-- in tasks/warplan/start_cycle.lua's vendor-menu flow -- one interact
-- often isn't enough; the host's interact_object is best-effort.
local INTERACT_RETRY_INTERVAL_S = 1.5
local MIN_INTERACTS_STICKY = 2       -- sticky state: don't fire clicks
                                      -- until we've re-interacted at
                                      -- least this many times
local CARD_TO_ACCEPT_S     = 1.0     -- pause between Reward click and Accept click
-- Quest log takes a beat to update after a successful Accept click.
-- Set generously so we don't Escape-retry over a successful claim
-- whose log entry just hadn't propagated yet.
local ACCEPT_VERIFY_TIMEOUT_S = 5.0
local INTER_ATTEMPT_S      = 1.5     -- pause between failed retries (let panel close)
local MAX_RETRIES          = 3

-- Per-zone latch so we don't re-attempt after a successful turn-in
-- this town visit.  Reset when the player leaves the zone.
local last_zone_handled = nil

local function reset_state()
    task.state               = nil
    task.state_t             = nil
    task.attempts            = 0
    task.pre_click_objective = nil
    task.interacts_fired     = 0
    task.last_interact_t     = nil
    task.interact_npc        = nil
end

-- Live-validated S09: the host does NOT classify the whispers reward
-- UI as a "vendor screen", so loot_manager.is_in_vendor_screen() stays
-- false even with the panel open.  We use the quest objective text as
-- a proxy:
--
--   "Return to the Tree of Whispers..."  -- panel never opened
--   "Choose your reward"                 -- panel opened AT LEAST ONCE
--                                           (sticky -- doesn't unset
--                                           when the panel closes)
--
-- This means the text TRANSITION (Return -> Choose) is a reliable
-- "panel opened just now" signal for the FIRST attempt of a fresh
-- turn-in cycle.  Subsequent retries can't use it because the text
-- is sticky -- those fall back to fixed timing.

-- Read the current bounty objective's lowercase text, or '' if absent.
local function bounty_objective_text()
    if not get_quests then return '' end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return '' end
    for _, q in pairs(quests) do
        local n = q.get_name and q:get_name() or ''
        if n == 'Bounty_Meta_Quest' or n:sub(1, #'Bounty_Meta_') == 'Bounty_Meta_' then
            local objs_ok, objs = pcall(function () return q:get_objectives() end)
            if objs_ok and objs and objs[1] then
                return (objs[1].text or ''):lower()
            end
            return ''
        end
    end
    return ''
end

-- True when the objective text indicates the panel has been opened at
-- least once during this turn-in cycle.
local function objective_says_opened(text)
    if not text or text == '' then return false end
    return text:find('choose your reward', 1, true) ~= nil
        or text:find('choose a reward',  1, true) ~= nil
        or text:find('select your reward', 1, true) ~= nil
end

local function send_escape()
    if utility and utility.send_key_press then
        pcall(utility.send_key_press, 0x1B)   -- Escape
    end
end

local function reward_click_frac()
    local sw = settings.warplan or {}
    return sw.whisper_reward_x_frac or whispers.DEFAULT_REWARD_CLICK_X_FRAC,
           sw.whisper_reward_y_frac or whispers.DEFAULT_REWARD_CLICK_Y_FRAC
end

local function accept_click_frac()
    local sw = settings.warplan or {}
    return sw.whisper_accept_x_frac or whispers.DEFAULT_ACCEPT_CLICK_X_FRAC,
           sw.whisper_accept_y_frac or whispers.DEFAULT_ACCEPT_CLICK_Y_FRAC
end

task.shouldExecute = function ()
    -- Master toggle.  Default OFF.
    local sw = settings.warplan
    if not sw or not sw.whisper_turn_in then
        if task.state ~= nil then reset_state() end
        return false
    end

    local cur_zone = zone.current()
    if not cur_zone then return false end

    -- Already turned in this visit; wait for a zone change.
    if last_zone_handled == cur_zone then return false end

    -- Mid-sequence: own the pulse regardless of below gates.
    if task.state ~= nil then return true end

    if not whispers.is_in_town() then return false end
    if whispers.count_ready_bounties() == 0 then return false end

    -- Live actor in stream OR catalogued position from WarPath.
    return whispers.find_tree_npc() ~= nil
        or whispers.find_tree_position() ~= nil
end

task.Execute = function ()
    local now = get_time_since_inject() or 0

    -- ---- Retry pause ----
    if task.state == 'WAIT_RETRY' then
        if (now - (task.state_t or 0)) < INTER_ATTEMPT_S then
            task.status = 'pausing before retry'
            return
        end
        task.state   = nil
        task.state_t = nil
        -- fall through into the WALK/INTERACT branch below
    end

    -- ---- CLICKING_ACCEPT: wait for quest to disappear ----
    if task.state == 'CLICKING_ACCEPT' then
        local elapsed = now - (task.state_t or 0)
        if not whispers.is_bounty_quest_present() then
            last_zone_handled = zone.current()
            if settings.debug_mode then
                console.print(string.format(
                    '[Whispers] turn-in succeeded after %d attempt(s)',
                    task.attempts))
            end
            reset_state()
            task.status = 'reward claimed'
            return
        end
        if elapsed < ACCEPT_VERIFY_TIMEOUT_S then
            task.status = string.format('verifying turn-in (%.1fs)',
                ACCEPT_VERIFY_TIMEOUT_S - elapsed)
            return
        end
        -- Quest still in log -> click missed somewhere; retry or give up.
        if task.attempts >= MAX_RETRIES then
            if settings.debug_mode then
                console.print(string.format(
                    '[Whispers] FAILED after %d attempts -- check click points in GUI',
                    task.attempts))
            end
            last_zone_handled = zone.current()
            reset_state()
            task.status = 'turn-in failed (check click points)'
            return
        end
        send_escape()
        task.state   = 'WAIT_RETRY'
        task.state_t = now
        task.status  = string.format('retrying (attempt %d/%d)',
            task.attempts + 1, MAX_RETRIES)
        return
    end

    -- ---- CLICKING_CARD: brief pause then fire Accept click ----
    if task.state == 'CLICKING_CARD' then
        if (now - (task.state_t or 0)) < CARD_TO_ACCEPT_S then
            task.status = 'waiting before Accept'
            return
        end
        local fx, fy = accept_click_frac()
        whispers.click_at_frac(fx, fy)
        if settings.debug_mode then
            console.print(string.format(
                '[Whispers] clicked Accept at (%.2f, %.2f)', fx, fy))
        end
        task.state   = 'CLICKING_ACCEPT'
        task.state_t = now
        task.status  = 'clicked Accept'
        return
    end

    -- ---- INTERACTING_NPC: re-interact + verify panel, then click reward ----
    -- Two verification paths:
    --   * pre_click_objective was "Return to Tree" -> wait for it to
    --     flip to "Choose your reward".  Reliable transition signal.
    --   * pre_click_objective was already "Choose your reward" (sticky
    --     state from a prior attempt or manual open) -> can't see a
    --     transition; fall back to MIN_INTERACTS_STICKY interacts spaced
    --     INTERACT_RETRY_INTERVAL_S apart, plus PANEL_RENDER_S total.
    --
    -- We re-fire interact_object on a cadence here -- one click often
    -- isn't enough.  Same pattern as start_cycle.lua's vendor flow.
    if task.state == 'INTERACTING_NPC' then
        local elapsed = now - (task.state_t or 0)
        local pre_was_sticky = objective_says_opened(task.pre_click_objective)
        local panel_likely_open = false

        if pre_was_sticky then
            -- Sticky path: need both enough elapsed time AND minimum
            -- interact count.  Without the count gate the bot can race
            -- past the first interact when it didn't actually register.
            panel_likely_open = elapsed >= PANEL_RENDER_S
                and (task.interacts_fired or 0) >= MIN_INTERACTS_STICKY
        else
            -- Transition signal: pre was "Return to Tree", we're waiting
            -- for "Choose your reward" to appear.  As soon as it does,
            -- the panel is definitely open -- click immediately.
            panel_likely_open = objective_says_opened(bounty_objective_text())
        end

        if panel_likely_open then
            local fx, fy = reward_click_frac()
            whispers.click_at_frac(fx, fy)
            if settings.debug_mode then
                console.print(string.format(
                    '[Whispers] panel verified (%s, %d interacts) -- clicked reward at (%.2f, %.2f)',
                    pre_was_sticky and 'timing' or 'transition',
                    task.interacts_fired or 0, fx, fy))
            end
            task.state   = 'CLICKING_CARD'
            task.state_t = now
            task.status  = 'clicked reward card'
            return
        end

        -- Not verified yet.  Re-fire interact_object on cadence; D4's
        -- interact_object is best-effort and routinely needs 2-3 attempts.
        if (now - (task.last_interact_t or 0)) >= INTERACT_RETRY_INTERVAL_S then
            local npc = task.interact_npc or whispers.find_tree_npc()
            if npc then
                task.interact_npc = npc
                interact_object(npc)
                task.interacts_fired = (task.interacts_fired or 0) + 1
                task.last_interact_t = now
                if settings.debug_mode then
                    console.print(string.format(
                        '[Whispers] re-interact (#%d, %s mode)',
                        task.interacts_fired,
                        pre_was_sticky and 'sticky' or 'transition'))
                end
                task.status = string.format('re-interact #%d', task.interacts_fired)
                return
            end
            -- NPC dropped out of stream mid-sequence; let outer logic re-find.
            task.interact_npc = nil
        end

        if elapsed < NPC_CLICK_TIMEOUT_S then
            task.status = string.format('waiting for panel (%.1fs, %d interacts)',
                NPC_CLICK_TIMEOUT_S - elapsed, task.interacts_fired or 0)
            return
        end
        -- Timeout: panel didn't render in time.  Outer retry or give up.
        if task.attempts >= MAX_RETRIES then
            if settings.debug_mode then
                console.print(string.format(
                    '[Whispers] panel never opened after %d outer attempts (%d interacts) -- giving up',
                    task.attempts, task.interacts_fired or 0))
            end
            last_zone_handled = zone.current()
            reset_state()
            task.status = 'NPC click never opened panel'
            return
        end
        send_escape()
        task.state   = 'WAIT_RETRY'
        task.state_t = now
        task.status  = 'panel did not open; retrying'
        return
    end

    -- ---- (state == nil OR fall-through from WAIT_RETRY) WALK + INTERACT ----
    -- (We removed the "pre-detect panel open and skip NPC click" branch
    -- because the host doesn't expose a reliable panel-open signal -- the
    -- objective text is sticky once the panel has been opened once.  We
    -- always interact with the NPC; if the panel is already open, the
    -- click closes-then-reopens it cleanly.)

    -- Find the NPC: prefer live actor (gives is_interactable check) but
    -- fall back to WarPath catalog so we can walk toward a known position
    -- before the actor stream populates after a zone change.
    local npc = whispers.find_tree_npc()
    if npc then
        -- Snapshot the objective text BEFORE the click.  Used in
        -- INTERACTING_NPC to choose between the "transition" verification
        -- (objective flips Return -> Choose) and the "timing" fallback
        -- (objective was already Choose; can't see a flip).
        task.pre_click_objective = bounty_objective_text()

        local r = interact.walk_and_interact(npc, INTERACT_RANGE)
        if r == 'too_far' then
            move.to_actor(npc)
            task.state  = 'WALK'
            task.status = 'walking to NPC'
            return
        end
        if r == 'no_actor' then
            task.status = 'NPC actor invalid'
            reset_state()
            return
        end
        -- Seed the in-state interact counter -- walk_and_interact just
        -- fired interact_object once, which counts as the first try.
        -- Subsequent re-interacts happen inside INTERACTING_NPC on the
        -- INTERACT_RETRY_INTERVAL_S cadence.
        task.attempts        = task.attempts + 1
        task.state           = 'INTERACTING_NPC'
        task.state_t         = now
        task.interacts_fired = 1
        task.last_interact_t = now
        task.interact_npc    = npc
        if settings.debug_mode then
            console.print(string.format(
                '[Whispers] interacted with NPC (attempt %d/%d) -- pre="%s"',
                task.attempts, MAX_RETRIES,
                task.pre_click_objective or ''))
        end
        task.status = 'interacted with NPC'
        return
    end

    -- Live actor not in stream -- walk toward catalogued position.
    local lp = get_local_player()
    if not lp then return end
    local pp = lp:get_position()
    if not pp then return end
    local cat = whispers.find_tree_position()
    if not cat then
        task.status = 'NPC unknown'
        reset_state()
        return
    end
    local dx, dy = cat.x - pp:x(), cat.y - pp:y()
    local d = math.sqrt(dx*dx + dy*dy)
    move.to_pos({ x = cat.x, y = cat.y, z = cat.z or pp:z() },
                { arrive_radius = INTERACT_RANGE })
    task.state  = 'WALK'
    task.status = string.format('walking to known NPC pos (%.0fm)', d)
end

return task
