-- ---------------------------------------------------------------------------
-- core/poi_pick.lua
--
-- "Walk a priority queue, return the first reachable target."  The
-- shared picker every WarMachine activity's interact_poi.lua calls
-- to choose its next walk-to-and-click target.
--
-- Replaces the duplicated pick_reachable_target / next_target helpers
-- that used to live (and slowly drift) in each per-activity file.
-- Centralizing here means:
--   * One A*-budget knob applies everywhere (was easy to set
--     differently per activity by accident)
--   * One "soft stale" semantics across activities so if a chest is
--     unreachable the bot won't re-A* it for SHORT_STALE_S no matter
--     which activity is driving
--   * One place to swap the underlying reach primitive when the host
--     pathfinder changes
--
-- API:
--   local pick = require 'core.poi_pick'
--   local picker = pick.make_picker(opts)   -- per-activity instance
--   local target = picker.pick(queue, opts2)
--
-- We return a "picker instance" rather than a stateless function
-- because each activity needs its OWN soft-stale ledger -- if NMD
-- and helltide shared one, marking a chest stale in NMD would hide
-- it from helltide's catalog (different keys would help, but
-- per-activity instances are simpler and more isolated).
--
-- per-instance opts:
--   budget         (default 4)   max A* calls per pick
--   short_stale_s  (default 6)   how long to skip an unreachable POI
--   require_player_pos (default true)
--                                when true and player pos is unavailable,
--                                pick() returns nil; some early-pulse
--                                callers want this opt-out.
--
-- per-pick opts (passed to picker.pick):
--   kind_filter    optional table {kind_name = true, ...}.  Only POIs
--                  whose kind is in this set are considered.
--   key_for        optional fn(poi) -> string for the soft-stale key.
--                  Defaults to "skin:floor(x):floor(y)" which is
--                  what every activity used.
--   player_pos     optional vec3 to check reachability from.
--                  Defaults to the live player's position.
-- ---------------------------------------------------------------------------

local reach        = require 'core.reach'
local entry_portal = require 'core.entry_portal'

local M = {}

local function default_key_for(poi)
    return string.format('%s:%d:%d',
        poi.skin or poi.kind or '?',
        math.floor(poi.x or 0),
        math.floor(poi.y or 0))
end

-- ---------------------------------------------------------------------------
-- Factory.  Returns an instance with its own _short_stale ledger.
-- ---------------------------------------------------------------------------
M.make_picker = function (cfg)
    cfg = cfg or {}
    local self = {
        budget        = cfg.budget        or 4,
        short_stale_s = cfg.short_stale_s or 6.0,
        _short_stale  = {},   -- "skin:x:y" -> expiry_t
    }

    -- Drop expired entries.  Cheap; called inside pick().
    local function purge_stale(now)
        for k, exp in pairs(self._short_stale) do
            if now >= exp then self._short_stale[k] = nil end
        end
    end

    -- Soft-mark a POI stale (skip for short_stale_s).  Exposed so
    -- callers can mark a target stale outside of pick() (e.g. when
    -- live_actor_for couldn't find a match).
    self.mark_stale = function (poi, now)
        now = now or (get_time_since_inject and get_time_since_inject()) or 0
        local key = default_key_for(poi)
        self._short_stale[key] = now + self.short_stale_s
    end

    -- Drop the stale ledger.  Useful on zone change.
    self.clear = function ()
        self._short_stale = {}
    end

    -- Diagnostics for the GUI.
    self.stats = function ()
        local n = 0
        for _ in pairs(self._short_stale) do n = n + 1 end
        return { stale_entries = n }
    end

    -- ---- The main pick.  Walks `queue` in given order, returns
    -- the first reachable POI.  Stops scanning once budget is
    -- exhausted (returns the next non-stale candidate without
    -- A*-checking; the caller's stuck-detect catches genuinely-
    -- unreachable late picks).  Returns nil when all candidates are
    -- either stale, filtered, or unreachable. ----
    self.pick = function (queue, opts)
        if not queue or #queue == 0 then return nil end
        opts = opts or {}
        local now = (get_time_since_inject and get_time_since_inject()) or 0
        purge_stale(now)

        local kind_filter = opts.kind_filter
        local key_for     = opts.key_for or default_key_for
        local player_pos  = opts.player_pos
        if not player_pos then
            local lp = get_local_player and get_local_player()
            player_pos = lp and lp:get_position() or nil
        end

        local budget = self.budget
        for _, poi in ipairs(queue) do
            -- Activity-specified kind filter (e.g. pit's IN_PIT_POI_KINDS).
            if not kind_filter or kind_filter[poi.kind or ''] then
                local key = key_for(poi)
                -- Entry-portal exclusion.  Skip catalog entries that sit
                -- right next to where we teleported into the zone (the
                -- door we came through, ready to send us straight back).
                -- See core/entry_portal.lua.  Caller can pass
                -- opts.allow_entry_portal = true to opt out (e.g. an
                -- exit task that DOES want to find the entry warp).
                if not opts.allow_entry_portal
                   and entry_portal.is_poi_near_entry(poi)
                then
                    -- noop: silently skip this candidate
                elseif not self._short_stale[key] then
                    -- No player pos = caller invoked us as a cheap
                    -- "is there ANY work to do" check from
                    -- shouldExecute.  Return the first non-stale
                    -- candidate without A*-checking.
                    if not player_pos then
                        return poi
                    end
                    if budget <= 0 then
                        -- Budget exhausted; accept this candidate
                        -- without A* and let the caller's stuck-
                        -- detect catch genuinely-unreachable picks.
                        return poi
                    end
                    budget = budget - 1
                    local goal = vec3:new(poi.x, poi.y, poi.z or player_pos:z())
                    if reach.is_reachable(player_pos, goal) then
                        return poi
                    end
                    -- Mark stale and try the next one.
                    self._short_stale[key] = now + self.short_stale_s
                end
            end
        end
        return nil
    end

    return self
end

-- Re-export reach for callers that want to A*-check a single position
-- without going through the full picker.
M.reach = reach

return M
