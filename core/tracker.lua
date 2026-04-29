-- ---------------------------------------------------------------------------
-- WarMachine shared run-state.
-- This is the single tracker for all activities. Per-activity ports add their
-- own keys to this object as they're brought in (helltide_*, nmd_*, etc.).
-- ---------------------------------------------------------------------------

local tracker = {
    -- Lifecycle
    start_time          = get_time_since_inject(),

    -- Mode tracking
    last_mode           = nil,             -- previous tick's mode for transition detection
    last_zone           = nil,             -- previous tick's zone

    -- War Plan dispatch (filled in Phase 5)
    warplan_active_activity = nil,         -- 'helltide'|'nightmare'|'undercity'|'turnin'|nil

    -- Cross-activity state placeholders (populated by phase ports)
    -- These are kept on the shared tracker so the GUI status line and War Plan
    -- orchestrator can read them without poking into task-private state.
    nmd       = {},
    helltide  = {},
    undercity = {},
    warplan   = {
        -- Cached read of warplan_state.read() — refreshed each pulse.
        -- Lets the GUI status bar and external facade read without
        -- re-walking get_quests().
        snapshot = nil,    -- { active=bool, quest={...}, activity=string }

        -- Test-click sequence state (Phase 5 prototype)
        test = {
            pending      = false,    -- true while a test sequence is in flight
            step         = 0,        -- 0=click slot, 1=click START, 2=verify
            current_slot = 1,        -- which slot index is being attempted
            timer        = 0,        -- timestamp of last action
            baseline     = 0,        -- #get_quests() at sequence start
            -- Player position at first slot click. Used to detect walk-away
            -- when a Confirm click hits world coords instead of the popup.
            start_pos_x  = nil,
            start_pos_y  = nil,
            result       = nil,      -- 'success'|'failed'|'walked_away'|'menu_closed'|nil
        },
        -- Next-Objective map-click test (Tab -> wait -> click map button)
        next_obj = {
            pending          = false,
            step             = 0,    -- 0=press Tab, 1=click button, 2=verify
            timer            = 0,
            verify_started_at = nil, -- when STEP_VERIFY first ran (for poll timeout)
            baseline_zone    = nil,
            baseline_pos_x   = nil,  -- position before tp, for in-zone jump detection
            baseline_pos_y   = nil,
            result           = nil,
        },
        -- Tyrael turn-in: retry interact until WarPlans_QST_TurnIn_Rewards
        -- disappears from the active quest list.
        turn_in = {
            pending          = false,
            timer            = 0,         -- when dispatch fired this
            first_attempt_at = nil,       -- when the first click was sent
            last_click_at    = nil,       -- last interact_object call time
            result           = nil,
        },
        -- Vendor menu open: retry interact until loot_manager.is_in_vendor_screen()
        start_cycle = {
            pending          = false,
            timer            = 0,
            first_attempt_at = nil,
            last_click_at    = nil,
            result           = nil,
        },

        -- Cooldowns to prevent dispatch from re-firing the same action mid-flight
        next_obj_cooldown_until    = 0,
        turn_in_cooldown_until     = 0,
        start_cycle_cooldown_until = 0,
        select_cooldown_until      = 0,

        -- Last-seen quest name for transition logging + grace tracking
        last_seen_warplan = nil,

        -- When the active warplan quest most recently CHANGED. Used by
        -- dispatch to delay firing next_obj after an activity completes,
        -- so the player has time to grab the floor loot that drops at
        -- chest-open / boss-kill / Tyrael-interact moments.
        activity_completed_at = nil,
    },
    -- Per-activity sub-trackers
    undercity = {
        enter = {
            pending          = false,
            first_attempt_at = nil,
            last_interact_at = nil,
            last_click_at    = nil,
            send_enter_at    = nil,    -- timestamp at which to fire Enter
                                         -- to accept the post-Open-Portal prompt
        },
    },
    nmd = {
        -- Standalone NMD entry: consume sigil + map-click state machine.
        use_sigil = {
            pending           = false,
            step              = 'idle',  -- idle / consuming / confirming / opening_map / waiting
            step_time         = -1,
            selected_sigil    = nil,
            portal_wait_start = -1,
            need_sigils       = false,   -- true when no usable sigils found
        },
    },
    pit = {
        -- In-pit run state
        start_time         = -1,    -- when we entered the pit
        exit_trigger_time  = nil,   -- when exit conditions first met
        glyph_gizmo_seen   = false, -- once Gizmo_Paragon_Glyph_Upgrade has been streamed in
        -- Entry retry state
        enter = {
            debounce_time = -1,
        },
        -- Map-travel state machine (Tab + click waypoint to reach Pit hub)
        travel = {
            pending           = false,
            step              = 0,    -- 0=open map, 1=click, 2=verify
            timer             = 0,
            verify_started_at = nil,
            baseline_zone     = nil,
            last_attempt_at   = -math.huge,
        },
    },

    -- Bot-level halt: any task can flip this to true to stop the entire run.
    bot_done  = false,
}

return tracker
