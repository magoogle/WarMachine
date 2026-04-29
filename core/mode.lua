-- ---------------------------------------------------------------------------
-- Mode helpers — single source of truth for which activity is active.
-- ---------------------------------------------------------------------------

local mode = {}

-- Match indices in gui.modes
mode.IDLE      = 0
mode.HELLTIDE  = 1
mode.NIGHTMARE = 2
mode.UNDERCITY = 3
mode.WARPLAN   = 4
mode.HORDES    = 5
mode.PIT       = 6

mode.labels = {
    [0] = 'Idle',
    [1] = 'Helltide',
    [2] = 'Nightmare',
    [3] = 'Undercity',
    [4] = 'War Plan',
    [5] = 'Hordes',
    [6] = 'Pit',
}

mode.label = function (m)
    return mode.labels[m] or ('Unknown(' .. tostring(m) .. ')')
end

-- True when the active mode equals `m`, or when War Plan is active and the
-- War Plan dispatcher has selected this activity.
-- For Phase 1 we only honor the literal selection — War Plan dispatching
-- arrives in Phase 5.
mode.matches = function (settings, m)
    if settings.mode == m then return true end
    if settings.mode == mode.WARPLAN then
        -- Phase 5 will read tracker.warplan_active_activity here.
        return false
    end
    return false
end

return mode
