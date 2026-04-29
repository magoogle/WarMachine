-- ---------------------------------------------------------------------------
-- War Plan state -- pure read of the live quest API.
--
-- Exposes:
--   warplan_state.read()  -> { active = bool, quest = {...}, activity = string|nil }
--
-- Where activity is one of: 'nightmare' | 'helltide' | 'undercity' | 'unknown'
-- derived from the quest name suffix.
--
-- Detection rule:
--   Iterate get_quests(); the first quest whose name starts with
--   'WarPlans_QST_' is the active War Plan. (We've never seen more than one
--   active concurrently.)  If none found -> no active war plan.
--
-- Sigil inventory helper:
--   warplan_state.usable_sigils()  -> filtered list of items where
--   stack_count > 0, namespaced by activity. Useful for the standalone NMD
--   mode (which DOES need a sigil, unlike War Plan NMD).
-- ---------------------------------------------------------------------------

local warplan_state = {}

local QUEST_NAME_PREFIX = 'WarPlans_QST_'
local BOUNTY_HELLTIDE_PREFIX = 'Bounty_Helltide_'

-- ---------------------------------------------------------------------------
-- Objective text helpers.
--
-- Quest objective text from the host carries inline format codes:
--   {icon:Helltide_Currency, 2.5}      -> drop entirely
--   {c:ff00ff00}1/3{/c}                -> strip the wrapper, keep "1/3"
-- ---------------------------------------------------------------------------
local function strip_format_codes(s)
    if type(s) ~= 'string' then return s end
    -- Drop {icon:...}
    s = s:gsub('%{icon:[^}]+%}', '')
    -- Strip color codes but keep inner content
    s = s:gsub('%{c:[%w]+%}', '')
    s = s:gsub('%{/c%}', '')
    -- Collapse stray spaces
    s = s:gsub('%s+', ' ')
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- Parses "N/M" progress out of a stripped objective string.
-- Returns { cur = N, max = M } or nil if no match.
local function parse_progress(s)
    local cur, max = s:match('(%d+)%s*/%s*(%d+)')
    if cur and max then return { cur = tonumber(cur), max = tonumber(max) } end
    return nil
end

-- Map quest-name suffix substrings to activity tags.
-- More-specific patterns first.
local ACTIVITY_PATTERNS = {
    { pat = 'TurnIn_Rewards',   activity = 'turnin'    },
    { pat = 'TurnIn',           activity = 'turnin'    },
    { pat = 'NightmareDungeon', activity = 'nightmare' },
    { pat = 'Nightmare',        activity = 'nightmare' },
    { pat = 'Helltide',         activity = 'helltide'  },
    { pat = 'Undercity',        activity = 'undercity' },
}

local function classify_activity(name)
    for _, row in ipairs(ACTIVITY_PATTERNS) do
        if name:find(row.pat, 1, true) then
            return row.activity
        end
    end
    return 'unknown'
end

-- Read a single quest's objectives into a clean table with parsed progress.
local function read_objectives(q)
    local raw = q:get_objectives()
    if not raw then return {} end
    local out = {}
    for i, obj in ipairs(raw) do
        local text   = strip_format_codes(obj.text)
        local prog   = parse_progress(text or '')
        out[i] = {
            text     = text,
            raw_text = obj.text,
            state    = obj.state,           -- bitfield; 1 == complete (per docs)
            sno      = obj.objective_sno,
            progress = prog,                -- { cur, max } or nil
        }
    end
    return out
end

-- Reads ALL active War Plans plus Bounty_Helltide_* quests and returns a
-- snapshot. Cheap to call every pulse.
--
-- Returns:
--   {
--     active           = bool,
--     quest            = { id, name, phase_id, ..., objectives = [...] },
--     activity         = 'nightmare'|'helltide'|'undercity'|'unknown',
--     macro_progress   = { cur, max } or nil    -- "War Plan: 1/3"
--     all_warplans     = [ ...same shape as quest... ],
--     helltide_bounties = [ {name, phase_id, objectives=[...] } ],
--   }
warplan_state.read = function ()
    local result = {
        active = false, quest = nil, activity = nil,
        macro_progress = nil, all_warplans = {}, helltide_bounties = {},
    }
    local quests = get_quests()

    -- Pass 1: WarPlans_QST_*
    for _, q in ipairs(quests) do
        local name = q:get_name()
        if name:sub(1, #QUEST_NAME_PREFIX) == QUEST_NAME_PREFIX then
            local objs = read_objectives(q)
            local entry = {
                id              = q:get_id(),
                name            = name,
                phase_id        = q:get_phase_id(),
                secondary_phase = q:get_secondary_phase_id(),
                objective_count = #objs,
                objectives      = objs,
            }
            table.insert(result.all_warplans, entry)
            -- Pick the first WarPlans_QST as the "active one" until we have a
            -- better heuristic. Per live observation, the game keeps only one
            -- active during play; the others stay queued at constant phase.
            if not result.active then
                result.active   = true
                result.quest    = entry
                result.activity = classify_activity(name)
                -- Look for the macro-progress objective. Two formats observed:
                --   "War Plan: 1/3"               (NMD/Helltide phase)
                --   "War Plans Progress: 2/3"     (Undercity phase)
                for _, o in ipairs(objs) do
                    if o.text and o.progress
                       and (o.text:find('War Plan:') or o.text:find('War Plans Progress')) then
                        result.macro_progress = o.progress
                        break
                    end
                end
            end
        end
    end

    -- Pass 2: Bounty_Helltide_* (concurrent helltide bounties -- useful for
    -- helltide path-priority decisions)
    for _, q in ipairs(quests) do
        local name = q:get_name()
        if name:sub(1, #BOUNTY_HELLTIDE_PREFIX) == BOUNTY_HELLTIDE_PREFIX then
            table.insert(result.helltide_bounties, {
                name       = name,
                phase_id   = q:get_phase_id(),
                objectives = read_objectives(q),
            })
        end
    end

    return result
end

-- Returns inventory items grouped by activity, filtered by stack_count > 0.
-- Used by the standalone "Nightmare" / "Undercity" modes.
-- Skin-name patterns:
--   Item_Nightmare_Sigil_*     -> nightmare
--   Item_Undercity_Tribute_*   -> undercity
warplan_state.usable_sigils = function ()
    local lp = get_local_player()
    if not lp then return { nightmare = {}, undercity = {}, total = 0 } end

    local items = lp:get_dungeon_key_items()
    local out = { nightmare = {}, undercity = {}, total = 0 }
    if not items then return out end

    for _, item in ipairs(items) do
        local stack = item:get_stack_count()
        if stack and stack > 0 then
            local skin = item:get_skin_name()
            local name = item:get_name()
            local entry = {
                name      = name,
                skin      = skin,
                rarity    = item:get_rarity(),
                stack     = stack,
                ancestral = item:is_ancestral(),
                sacred    = item:is_sacred(),
            }
            if skin:find('Item_Nightmare_Sigil', 1, true) then
                table.insert(out.nightmare, entry)
                out.total = out.total + stack
            elseif skin:find('Item_Undercity_Tribute', 1, true) then
                table.insert(out.undercity, entry)
                out.total = out.total + stack
            end
        end
    end
    return out
end

return warplan_state
