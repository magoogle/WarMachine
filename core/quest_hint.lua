-- ---------------------------------------------------------------------------
-- core/quest_hint.lua
--
-- "What are we supposed to be killing right now?"
--
-- Reads active D4 quest objective text and extracts the noun phrase
-- the player is being asked to kill / find / defeat.  Other modules
-- (notably core/target.lua) consult this to give matching enemies
-- top targeting priority -- so when the objective is "Slay the
-- Aldurkin", an Aldurkin streaming into our actor list beats a
-- closer-but-irrelevant skeleton.
--
-- Live data (S09 NMD examples):
--
--   DPO_Scos_Aldurwood    "Slay the Aldurkin: {c:ff00ff00}1{/c}"
--   DPO_Step_BuriedHalls  "Cleanse the Heart of Daragath"
--   DPO_Hawe_Champions_E  "Defeat the Champions: {c:ff00ff00}3{/c}"
--   QST_Class_Sorc        "Follow the astral call"
--
-- The objective text contains D4 inline format codes ({c:RRGGBBAA}n{/c}
-- for colored counters, {icon:Marker_*}, etc.).  We strip those and
-- pull the noun phrases that follow common kill verbs ("Slay",
-- "Defeat", "Kill", "Destroy", "Cleanse", "Hunt", "Eliminate", ...).
--
-- Cache: parsed snapshot is refreshed at most every CACHE_TTL_S so a
-- target.pick happening 20 times per second doesn't re-walk the
-- quest list each call.
-- ---------------------------------------------------------------------------

local M = {}

local CACHE_TTL_S = 2.0   -- re-scan quest log this often

-- Verbs that introduce a kill target in D4's quest copy.  The next
-- noun phrase after one of these is what we want to extract.  All
-- lowercased; matched against lowercased objective text.
local KILL_VERBS = {
    'slay',
    'defeat',
    'kill',
    'destroy',
    'eliminate',
    'hunt',
    'cleanse',     -- "Cleanse the Heart of Daragath" etc.
    'banish',
    'vanquish',
    'dispatch',
    'execute',
}

-- Filler words that follow the verb and should be skipped before the
-- noun.  Catches articles + a couple of common D4 idioms.
local FILLER_WORDS = {
    ['the']    = true,
    ['a']      = true,
    ['an']     = true,
    ['of']     = true,
    ['all']    = true,
    ['any']    = true,
    ['some']   = true,
    ['these']  = true,
    ['those']  = true,
    ['that']   = true,
    ['this']   = true,
}

-- D4 quest objectives sometimes pluralize the noun ("Aldurkins",
-- "Champions").  We register both forms so a runtime skin like
-- 'Aldurkin_Boss' substring-matches whether the quest said
-- "Aldurkin" or "Aldurkins".
local function singular_of(s)
    if not s or #s < 4 then return s end
    if s:sub(-3) == 'ies' then return s:sub(1, -4) .. 'y' end
    if s:sub(-1) == 's'   then return s:sub(1, -2)         end
    return s
end

-- Strip D4 inline format codes from an objective text.  The codes
-- look like:
--   {c:ff00ff00}1{/c}                  -- colored counter
--   {icon:Marker_Foo, 2.5}             -- icon glyph
--   {/c}                               -- close-color marker (no-op for us)
-- We replace each with whitespace so word boundaries stay intact.
local function strip_format_codes(text)
    if not text then return '' end
    local out = text
    -- Remove anything between { and } (non-greedy).
    out = out:gsub('{[^}]-}', ' ')
    -- Collapse runs of whitespace.
    out = out:gsub('%s+', ' ')
    return out
end

-- Tokenize a stripped string into lowercase word array.
local function tokens(text)
    local out = {}
    for w in text:gmatch('([%w%-]+)') do
        out[#out + 1] = w:lower()
    end
    return out
end

-- For a token sequence, find the noun phrase following a kill verb.
-- Heuristic: skip filler words, take the next 1-2 words as the noun.
-- Returns nil when no kill-verb is found.
local function noun_after_verb(toks)
    for i, w in ipairs(toks) do
        for _, v in ipairs(KILL_VERBS) do
            if w == v then
                -- Skip fillers
                local j = i + 1
                while toks[j] and FILLER_WORDS[toks[j]] do
                    j = j + 1
                end
                if not toks[j] then return nil end
                -- Take the noun.  If the next word is also a noun
                -- (no filler / no number), allow a 2-word capture for
                -- compound names like "Cursed Knight".
                local first = toks[j]
                local second = toks[j + 1]
                if second
                   and not FILLER_WORDS[second]
                   and not tonumber(second)
                   -- Don't extend across a verb boundary
                   and not (function ()
                        for _, vv in ipairs(KILL_VERBS) do
                            if second == vv then return true end
                        end
                        return false
                   end)()
                then
                    return first, second
                end
                return first
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Cache state.
-- _hints[i] = { keyword = 'aldurkin', source_quest = 'DPO_...' }
-- ---------------------------------------------------------------------------
local _hints   = {}
local _cache_t = -math.huge

local function now_s()
    return get_time_since_inject and get_time_since_inject() or 0
end

-- Refresh the keyword list from the live quest log.  Cheap when the
-- TTL hasn't elapsed.
local function refresh()
    local now = now_s()
    if (now - _cache_t) < CACHE_TTL_S then return end
    _cache_t = now
    local seen = {}
    local new_hints = {}

    if not get_quests then return end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return end

    for _, q in pairs(quests) do
        local qname = nil
        if q.get_name then
            local nok, n = pcall(function () return q:get_name() end)
            if nok then qname = n end
        end
        local objs = nil
        if q.get_objectives then
            local ook, list = pcall(function () return q:get_objectives() end)
            if ook then objs = list end
        end
        for _, o in ipairs(objs or {}) do
            -- Only objectives still in progress contribute keywords.
            -- state == 1 means complete; everything else (including
            -- the in-progress 16777216 sentinel) is "still wanted".
            if o.state ~= 1 and o.text then
                local stripped = strip_format_codes(o.text)
                local toks = tokens(stripped)
                local n1, n2 = noun_after_verb(toks)
                local function add(k)
                    if not k or #k < 3 then return end
                    if seen[k] then return end
                    seen[k] = true
                    new_hints[#new_hints + 1] = {
                        keyword       = k,
                        source_quest  = qname,
                        source_text   = stripped,
                    }
                end
                if n1 then
                    add(n1)
                    add(singular_of(n1))
                end
                if n2 then
                    add(n2)
                    add(singular_of(n2))
                end
            end
        end
    end
    _hints = new_hints
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns true if the given skin name substring-matches any current
-- quest hint keyword.  Case-insensitive.  Matches BOTH the singular
-- and plural forms when the quest provides a plural ("Champions" ->
-- 'champion' substring matches).
M.skin_matches_hint = function (skin)
    if not skin or skin == '' then return false end
    refresh()
    if #_hints == 0 then return false end
    local lower = skin:lower()
    for _, h in ipairs(_hints) do
        if lower:find(h.keyword, 1, true) then return true end
    end
    return false
end

-- Returns the active hint list (read-only-ish copy).  GUI / debug use.
M.list = function ()
    refresh()
    local out = {}
    for i, h in ipairs(_hints) do
        out[i] = { keyword = h.keyword, source_quest = h.source_quest }
    end
    return out
end

-- Force-refresh -- useful after the player accepts/turns-in a quest
-- and wants the keyword list updated immediately rather than waiting
-- the cache TTL.
M.refresh = function ()
    _cache_t = -math.huge
    refresh()
end

-- Clear the cache.  Useful on activity transitions.
M.clear = function ()
    _hints   = {}
    _cache_t = -math.huge
end

return M
