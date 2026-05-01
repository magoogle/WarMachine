-- ---------------------------------------------------------------------------
-- activities/helltide/quest_state.lua
--
-- Reads the active Helltide WarPlan quest objective and surfaces it as a
-- structured "directive" the rest of the helltide module can use to
-- bias POI priority.  Same shape as activities/hordes/quest_state.lua
-- and activities/nmd/quest_state.lua.
--
-- Captured live S09 (zone Skov_Temis):
--
--   name: WarPlans_QST_Helltide_TorturedGifts
--   objective: "Collect {icon:Helltide_Currency, 2.5} Aberrant Cinders
--               to open {c:ff00ff00}0/2{/c} {icon:Marker_Helltide_Chest, 2.5}
--               Tortured Gifts."
--
-- We don't have to parse the cinder cost (the priority queue's chest_cost
-- gate handles affordability via get_helltide_coin_cinders).  What we DO
-- want to extract is the chest-type the WarPlan is asking for and the
-- count progress so the GUI overlay can show "X/Y" cleanly.
--
-- Returned shape:
--   {
--     active           = bool,                  -- a Helltide warplan is active
--     name             = quest_name,
--     directive        = 'tortured_gifts'|'silent_chests'|'random_chests'|nil,
--     progress         = { cur, max } | nil,    -- "0/2" parsed if present
--     all_complete     = bool,                  -- objective state == 1
--     raw_objective    = string,                -- text with format codes stripped
--   }
-- or nil if no helltide warplan is active.
-- ---------------------------------------------------------------------------

local M = {}

local STATE_COMPLETE = 1

-- Substring patterns (case-insensitive on the quest NAME) that identify
-- a Helltide WarPlan quest.
local HELLTIDE_QUEST_PATTERNS = {
    'warplans_qst_helltide_',     -- canonical S09
    '_helltide_',                 -- defensive
}

-- Substring patterns (case-insensitive on the OBJECTIVE TEXT) that map
-- to a directive.  Order matters: more specific first.
local DIRECTIVE_PATTERNS = {
    { pat = 'tortured gift',  d = 'tortured_gifts' },
    { pat = 'tortured cache', d = 'tortured_gifts' },   -- defensive seasonal variant
    { pat = 'silent chest',   d = 'silent_chests'  },
    { pat = 'helltide chest', d = 'random_chests'  },
    { pat = 'chest',          d = 'random_chests'  },
}

local function strip_format(s)
    if type(s) ~= 'string' then return '' end
    s = s:gsub('%{icon:[^}]+%}', '')
    s = s:gsub('%{c:[%w]+%}', '')
    s = s:gsub('%{/c%}', '')
    s = s:gsub('%s+', ' ')
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function parse_progress(s)
    local cur, max = s:match('(%d+)%s*/%s*(%d+)')
    if cur and max then return { cur = tonumber(cur), max = tonumber(max) } end
    return nil
end

local function is_helltide_quest_name(name)
    if not name then return false end
    local n = name:lower()
    for _, pat in ipairs(HELLTIDE_QUEST_PATTERNS) do
        if n:find(pat, 1, true) then return true end
    end
    return false
end

local function classify_directive(text)
    if not text then return nil end
    local t = text:lower()
    for _, row in ipairs(DIRECTIVE_PATTERNS) do
        if t:find(row.pat, 1, true) then return row.d end
    end
    return nil
end

-- Returns the helltide WarPlan snapshot, or nil.
M.read = function ()
    if not get_quests then return nil end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return nil end

    for _, q in pairs(quests) do
        local name = q.get_name and q:get_name() or ''
        if is_helltide_quest_name(name) then
            local objs_ok, objs = pcall(function () return q:get_objectives() end)
            if not objs_ok then objs = {} end
            -- Find the actionable objective: the first one whose text
            -- doesn't start with "War Plan:" (that's the macro counter,
            -- not the gameplay step).
            local actionable_text   = ''
            local actionable_state  = nil
            local all_done = true
            for _, o in ipairs(objs or {}) do
                local stripped = strip_format(o.text)
                if o.state ~= STATE_COMPLETE then all_done = false end
                if actionable_text == ''
                   and stripped ~= ''
                   and not stripped:find('War Plan')
                then
                    actionable_text  = stripped
                    actionable_state = o.state
                end
            end
            if #(objs or {}) == 0 then all_done = false end
            return {
                active        = true,
                name          = name,
                directive     = classify_directive(actionable_text),
                progress      = parse_progress(actionable_text),
                all_complete  = all_done,
                raw_objective = actionable_text,
            }
        end
    end
    return nil
end

return M
