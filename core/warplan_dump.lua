-- ---------------------------------------------------------------------------
-- core/warplan_dump.lua
--
-- One-shot debug dump of the live WAR PLANS vendor panel.  Triggered by
-- the "Dump WarPlan panel" button in the Debug tree of the WarMachine
-- GUI.  Player must be at Warplans_Vendor with the panel open or the
-- host's `warplan` API returns no data.
--
-- Surface used (see #api/warplan.lua):
--   warplan.is_ready()              bool
--   warplan.required_picks()        number
--   warplan.selected_count()        number
--   warplan.selected_path()         table<number, number>   -- ids
--   warplan.get_root_node_ids()     table<number, number>
--   warplan.get_selectable_now()    table<number, number>
--   warplan.enumerate_nodes()       table<number, warplan_node>
--   warplan.node_name(id)           string
--   warplan.node_reward_name(id)    string
--   warplan.get_node(id)            { id, selected, neighbors }
--
-- The dump is intentionally verbose -- it prints every node's name,
-- reward, selected state, and neighbors so the user can compare the
-- in-game tree screenshot against what the host believes is in the
-- panel.  That's enough to debug both "why did the picker pick X"
-- (test_select.pick_next_id) and "are the names case-different from
-- what we're substring-matching" cases.
-- ---------------------------------------------------------------------------

local M = {}

local function safe_call(fn, ...)
    if type(fn) ~= 'function' then return nil, 'not a function' end
    local ok, ret = pcall(fn, ...)
    if not ok then return nil, tostring(ret) end
    return ret
end

local function fmt_ids(t)
    if type(t) ~= 'table' or #t == 0 then return '(none)' end
    local out = {}
    for i, v in ipairs(t) do out[i] = tostring(v) end
    return '[' .. table.concat(out, ', ') .. ']'
end

local function set_from_list(t)
    local s = {}
    if type(t) == 'table' then
        for _, v in ipairs(t) do s[v] = true end
    end
    return s
end

M.dump = function ()
    console.print('[WarMachine] === WarPlan panel dump ===')

    if type(_G.warplan) ~= 'table' then
        console.print('[WarMachine]   host warplan API not present (_G.warplan == nil)')
        return
    end

    local ready = safe_call(warplan.is_ready)
    console.print(string.format('[WarMachine]   is_ready()=%s', tostring(ready)))
    if ready ~= true then
        console.print('[WarMachine]   panel not open -- walk to the WarPlans vendor and open it, then click again')
        return
    end

    local required = safe_call(warplan.required_picks)    or '?'
    local selected = safe_call(warplan.selected_count)    or '?'
    local complete = safe_call(warplan.is_complete)
    console.print(string.format('[WarMachine]   required_picks=%s selected_count=%s is_complete=%s',
        tostring(required), tostring(selected), tostring(complete)))

    local roots       = safe_call(warplan.get_root_node_ids)  or {}
    local selectable  = safe_call(warplan.get_selectable_now) or {}
    local path        = safe_call(warplan.selected_path)      or {}
    console.print('[WarMachine]   roots=' .. fmt_ids(roots))
    console.print('[WarMachine]   selectable_now=' .. fmt_ids(selectable))
    console.print('[WarMachine]   selected_path=' .. fmt_ids(path))

    local sel_set  = set_from_list(selectable)
    local root_set = set_from_list(roots)
    local path_set = set_from_list(path)

    local nodes = safe_call(warplan.enumerate_nodes) or {}
    if type(nodes) ~= 'table' or next(nodes) == nil then
        console.print('[WarMachine]   enumerate_nodes() returned empty -- nothing else to print')
        return
    end

    -- Stable ordering by id for readable output.
    local ids = {}
    for _, n in pairs(nodes) do
        if type(n) == 'table' and n.id then ids[#ids + 1] = n.id end
    end
    table.sort(ids)

    console.print(string.format('[WarMachine]   nodes (%d):', #ids))
    for _, id in ipairs(ids) do
        local node    = safe_call(warplan.get_node, id)
        local name    = safe_call(warplan.node_name, id)        or ''
        local reward  = safe_call(warplan.node_reward_name, id) or ''
        local nbrs
        if type(node) == 'table' then
            nbrs = node.neighbors
        end
        local nbr_str = '(none)'
        if type(nbrs) == 'table' then
            local list = {}
            for _, v in pairs(nbrs) do list[#list + 1] = tostring(v) end
            if #list > 0 then nbr_str = '[' .. table.concat(list, ',') .. ']' end
        end
        local flags = {}
        if root_set[id]    then flags[#flags + 1] = 'ROOT' end
        if sel_set[id]     then flags[#flags + 1] = 'SELECTABLE' end
        if path_set[id]    then flags[#flags + 1] = 'PICKED' end
        if node and node.selected then flags[#flags + 1] = 'selected_flag' end
        local flag_str = #flags > 0 and (' [' .. table.concat(flags, ',') .. ']') or ''

        console.print(string.format(
            "[WarMachine]     id=%-4d  name='%s'  reward='%s'  neighbors=%s%s",
            id, tostring(name), tostring(reward), nbr_str, flag_str))
    end

    console.print('[WarMachine] === end dump ===')
end

return M
