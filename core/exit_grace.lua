-- ---------------------------------------------------------------------------
-- core/exit_grace.lua
--
-- Universal end-of-run loot-grace period.  Whenever a WarMachine
-- activity detects "the run is mechanically complete" (boss dead,
-- horadric chest opened, hordes chest phase done, pit glyph upgrade
-- finished, undercity chest looted), it MUST hold the run-done state
-- for at least MIN_GRACE_S seconds before teleporting / resetting --
-- so:
--
--   * Reward chests have time to spawn + loot UI finishes
--   * Stragglers from the boss fight finish dropping loot
--   * Pickup-on-walk loot the player hasn't reached gets a beat
--   * The user can see "yes the run completed, here's the loot drop"
--     before the screen flashes to a new zone
--
-- Per the user-spec'd "we have to have at least 15 seconds to loot.
-- That should be universal for any end of run with warmachine."
--
-- API:
--
--   exit_grace.MIN_GRACE_S      -> the constant (15)
--   exit_grace.has_elapsed(t)   -> bool: has MIN_GRACE_S passed since t?
--                                  Returns false when t is nil so callers
--                                  don't have to nil-check.
--   exit_grace.remaining(t)     -> seconds left until grace ends, or 0
--                                  when already elapsed / t is nil.
--                                  Useful for the GUI "exiting in 7s..."
--                                  status string.
-- ---------------------------------------------------------------------------

local M = {}

-- 15 seconds.  Tuned per user spec; bump up if loot UI gets slower in
-- a future patch.  Per-activity exit tasks reference M.MIN_GRACE_S so
-- changing this constant updates every consumer at once.
M.MIN_GRACE_S = 15

local function now_s()
    return get_time_since_inject and get_time_since_inject() or 0
end

-- True when MIN_GRACE_S has elapsed since the completion timestamp.
-- Defensive: returns false when completion_t is nil (= run isn't
-- complete yet, can't have elapsed).
M.has_elapsed = function (completion_t)
    if not completion_t then return false end
    return (now_s() - completion_t) >= M.MIN_GRACE_S
end

-- Seconds remaining (clamped at 0).  For status lines.
M.remaining = function (completion_t)
    if not completion_t then return M.MIN_GRACE_S end
    local elapsed = now_s() - completion_t
    if elapsed >= M.MIN_GRACE_S then return 0 end
    return M.MIN_GRACE_S - elapsed
end

return M
