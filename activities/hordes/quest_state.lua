-- activities/hordes/quest_state.lua
--
-- Reads the active Hordes quest objective text and extracts a "wave
-- directive" keyword we can use to dynamically promote the right actor
-- family in kill_monster's tier selection.
--
-- D4's Hordes quest objectives are short imperative sentences like:
--   "Defeat 5 Aether Lords"
--   "Destroy 3 Soulspires"
--   "Slay 1 Bartuc"
--   "Collect Bonus Aether"
--   "Kill Hellborne"
--   "Defeat the Council of Hatred"
--
-- We pattern-match the noun to one of a small set of directives and
-- return it.  If we can't parse anything, return nil and the caller
-- falls back to the static priority order.
--
-- Cheap: get_quests() + get_objectives() are designed to be called every
-- pulse per the host docs.  We don't cache here -- callers can throttle
-- if they want.

local M = {}

-- Order matters: more-specific patterns first.  E.g. "Bonus Aether" must
-- match before "Aether" alone, otherwise we'd misclassify an aether-
-- structure directive as plain aether-collection.
local PATTERNS = {
    -- High-specificity (pull these out first)
    { pat = '[Bb]onus [Aa]ether',       d = 'aether_structure' },
    { pat = '[Aa]ether [Ll]ord',         d = 'lord'             },
    { pat = '[Cc]ouncil',               d = 'boss'             },
    { pat = 'Bartuc',                   d = 'boss'             },
    { pat = '[Mm]iniboss',              d = 'miniboss'         },
    -- Mid-specificity nouns
    { pat = '[Ss]oulspire',             d = 'spire'            },
    { pat = '[Ss]pire',                 d = 'spire'            },
    { pat = '[Hh]ellborne',             d = 'hellborne'        },
    { pat = '[Gg]oblin',                d = 'goblin'           },
    { pat = '[Hh]ellseeker',            d = 'hellseeker'       },
    -- Catch-all family nouns (less specific)
    { pat = '[Mm]ass',                  d = 'mass'             },
    { pat = '[Zz]ombie',                d = 'mass'             },
    -- Aether bare noun -- only if no other match (handled by ordering)
    { pat = '[Aa]ether',                d = 'aether_collect'   },
}

-- Heuristic: which quest counts as "the Hordes quest"?  HordeDev hardcodes
-- quest id 2023962 ("Infernal Horde").  IDs are stable across patches but
-- can change between seasons; matching by name prefix is more durable.
local function is_hordes_quest(name)
    if not name then return false end
    -- Both observed in season 5/6/7: "BSK_QST_..." and "Infernal Horde..."
    return name:find('BSK_', 1, true)       ~= nil
        or name:find('Infernal', 1, true)   ~= nil
        or name:find('Horde',    1, true)   ~= nil
end

-- Public: find the active hordes quest's first incomplete objective and
-- return the matched directive ("mass" | "spire" | "hellborne" | "goblin"
-- | "lord" | "miniboss" | "boss" | "hellseeker" | "aether_structure" |
-- "aether_collect"), or nil if nothing matched.
M.read_directive = function ()
    if not get_quests then return nil end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return nil end

    for _, q in pairs(quests) do
        if q and q.get_name then
            local name = q:get_name() or ''
            if is_hordes_quest(name) and q.get_objectives then
                local objs_ok, objs = pcall(function () return q:get_objectives() end)
                if objs_ok and objs then
                    for _, o in ipairs(objs) do
                        -- state == 1 means complete per the host docs.
                        -- Skip completed objectives -- we want the active one.
                        if o.text and (o.state ~= 1) then
                            for _, kw in ipairs(PATTERNS) do
                                if o.text:find(kw.pat) then
                                    return kw.d, o.text
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

return M
