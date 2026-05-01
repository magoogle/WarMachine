-- ---------------------------------------------------------------------------
-- WarMachine run mode.
--
-- One of these is always active.  WARPLAN is the autopilot that follows the
-- WarPlans_QST_* quest line and auto-cycles between activities; the others
-- are standalone "just farm this activity forever" modes.
--
-- The activity_manager (core/activity_manager.lua) reads `settings.mode` to
-- decide which activity module to drive each pulse.  Mode dropdown is
-- rendered by gui.lua.
-- ---------------------------------------------------------------------------

local mode = {}

mode.IDLE      = 0
mode.WARPLAN   = 1
mode.NIGHTMARE = 2
mode.UNDERCITY = 3
mode.PIT       = 4
mode.HORDES    = 5
mode.HELLTIDE  = 6
mode.BOSS      = 7

mode.labels = {
    [0] = 'Idle',
    [1] = 'War Plan',
    [2] = 'Nightmare',
    [3] = 'Undercity',
    [4] = 'Pit',
    [5] = 'Hordes',
    [6] = 'Helltide',
    [7] = 'Boss',
}

-- Order shown in the GUI combo box.  WarPlan first because it's the
-- "everything in one" autopilot most users will pick.
mode.dropdown_order = { 'IDLE', 'WARPLAN', 'NIGHTMARE', 'UNDERCITY', 'PIT', 'HORDES', 'HELLTIDE', 'BOSS' }

mode.dropdown_labels = (function ()
    local out = {}
    for i, k in ipairs(mode.dropdown_order) do out[i] = mode.labels[mode[k]] end
    return out
end)()

-- Combo-box index <-> mode value (combo_box returns 0-based index into
-- the array given to :render()).
mode.from_index = function (idx)
    local key = mode.dropdown_order[idx + 1]   -- combo is 0-indexed
    return key and mode[key] or mode.IDLE
end

mode.to_index = function (m)
    for i, k in ipairs(mode.dropdown_order) do
        if mode[k] == m then return i - 1 end
    end
    return 0
end

mode.label = function (m)
    return mode.labels[m] or ('Unknown(' .. tostring(m) .. ')')
end

-- Maps a mode to the activity tag that should be driven.  WARPLAN is
-- special -- the actual activity is read from the live WarPlans_QST_*
-- quest, so this returns nil for it (activity_manager dispatches via
-- warplan_state for that mode).
mode.activity_for = function (m)
    if m == mode.NIGHTMARE then return 'nmd'       end
    if m == mode.UNDERCITY then return 'undercity' end
    if m == mode.PIT       then return 'pit'       end
    if m == mode.HORDES    then return 'hordes'    end
    if m == mode.HELLTIDE  then return 'helltide'  end
    if m == mode.BOSS      then return 'boss'      end
    return nil
end

-- Convenience predicates for tasks that need to gate on WarPlan vs
-- standalone-mode behavior.  Many tasks previously inlined
-- `core_settings.mode == core_mode.WARPLAN` -- centralize it.
local _settings_lazy = nil
local function get_settings()
    -- Late-bound require to avoid a circular dep (core.settings -> core.mode).
    if _settings_lazy == nil then
        local ok, s = pcall(require, 'core.settings')
        if ok then _settings_lazy = s else _settings_lazy = false end
    end
    return _settings_lazy or nil
end

mode.is_warplan = function ()
    local s = get_settings()
    return s and s.mode == mode.WARPLAN or false
end

mode.is_standalone = function ()
    local s = get_settings()
    if not s then return false end
    return s.mode ~= mode.IDLE and s.mode ~= mode.WARPLAN
end

mode.is_idle = function ()
    local s = get_settings()
    return s and s.mode == mode.IDLE or false
end

-- True when settings.mode == the given mode constant.
mode.is = function (m)
    local s = get_settings()
    return s and s.mode == m or false
end

return mode
