-- ---------------------------------------------------------------------------
-- WarMachine tracker -- orchestrator only.
-- ---------------------------------------------------------------------------

local tracker = {
    start_time          = get_time_since_inject(),
    last_mode           = nil,
    last_zone           = nil,
    bot_done            = false,

    warplan = {
        -- Cached read of warplan_state.read() -- refreshed each pulse
        snapshot = nil,

        -- Tracks active warplan transitions (used for sub-plugin handoff +
        -- loot grace timing).
        last_seen_warplan      = nil,
        activity_completed_at  = nil,

        -- Sub-plugin orchestration: which plugin we currently have enabled.
        -- WarMachine ensures only one is on at a time, transitions on
        -- activity change, disables all on warplan complete.
        active_sub_plugin = nil,    -- 'sigilrunner' / 'helltide' / 'wondercity' / 'arkhamasylum' / nil

        -- Auto-select click sequence state (the 15-slot grid + START + Confirm)
        test = {
            pending      = false,
            step         = 0,
            current_slot = 1,
            timer        = 0,
            baseline     = 0,
            start_pos_x  = nil,
            start_pos_y  = nil,
            result       = nil,
        },

        -- Tab + map-click Next-Obj sequence (poll-style verify)
        next_obj = {
            pending           = false,
            step              = 0,
            timer             = 0,
            verify_started_at = nil,
            baseline_zone     = nil,
            baseline_pos_x    = nil,
            baseline_pos_y    = nil,
            result            = nil,
        },

        -- Walk to Tyrael + interact (with retry-until-quest-cleared)
        turn_in = {
            pending          = false,
            timer            = 0,
            first_attempt_at = nil,
            last_click_at    = nil,
            result           = nil,
        },

        -- Walk to Warplans_Vendor + open menu (with retry-until-menu-open)
        start_cycle = {
            pending          = false,
            timer            = 0,
            first_attempt_at = nil,
            last_click_at    = nil,
            result           = nil,
        },

        -- Cooldowns to prevent dispatch from re-firing the same action
        next_obj_cooldown_until    = 0,
        turn_in_cooldown_until     = 0,
        start_cycle_cooldown_until = 0,
        select_cooldown_until      = 0,
    },

    -- Undercity Obelisk entry (from Temis with active UC warplan).
    -- Sub-plugin (WonderCity) doesn't know about Skov_Temis, so WarMachine
    -- handles the UC entry itself.
    undercity = {
        enter = {
            pending          = false,
            first_attempt_at = nil,
            last_interact_at = nil,
            last_click_at    = nil,
            send_enter_at    = nil,
        },
    },

    -- Pit entry (from Temis with active Pit warplan). Sub-plugin
    -- (ArkhamAsylum) gates on Cerrigar zone, doesn't fire from Temis,
    -- so WarMachine handles the entry itself.
    pit = {
        start_time          = -1,
        exit_trigger_time   = nil,
        glyph_gizmo_seen    = false,
        glyph_interacted_at = nil,    -- when we first clicked the upgrade gizmo
        enter = {
            debounce_time = -1,
        },
    },
}

return tracker
