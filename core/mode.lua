-- ---------------------------------------------------------------------------
-- WarMachine mode -- orchestrator-only design.
--
-- WarMachine's job is to run the War Plan cycle: open vendor menu, accept
-- a plan, tp between activities, hand off each activity to the appropriate
-- sub-plugin (SigilRunner / HelltideRevamped / WonderCity / ArkhamAsylum),
-- and turn in at the end.
--
-- Standalone activities (running NMD on its own, helltide farming, etc.)
-- live in those sub-plugins. The user enables them directly when they
-- want to run an activity outside a war plan.
-- ---------------------------------------------------------------------------

local mode = {}

mode.IDLE    = 0
mode.WARPLAN = 1

mode.labels = {
    [0] = 'Idle',
    [1] = 'War Plan',
}

mode.label = function (m)
    return mode.labels[m] or ('Unknown(' .. tostring(m) .. ')')
end

return mode
