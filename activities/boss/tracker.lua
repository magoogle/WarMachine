-- activities/boss/tracker.lua

local tracker = {
    visited           = {},
    -- State machine flags.  Tasks gate on these:
    --   altar_seen         set when interact_altar finds the altar in stream
    --   altar_activated    set the moment the altar-actor disappears post-click
    --   altar_activate_t   wall-clock time of that transition
    --   chest_opened       set after open_chest fires interact on a reward chest
    --   chest_opened_t     wall-clock of the click
    --   run_done           triggers exit task (standalone) / WarPlan Next-Obj
    altar_seen        = false,
    altar_activated   = false,
    altar_activate_t  = nil,
    chest_opened      = false,
    chest_opened_t    = nil,
    run_done          = false,
    run_start_t       = nil,
    boss_quest_seen   = false,    -- mirrors Reaper's boss_quest_present sticky bit
    current_task      = { name = 'idle', status = 'idle' },
}

tracker.reset_run = function ()
    tracker.visited           = {}
    tracker.altar_seen        = false
    tracker.altar_activated   = false
    tracker.altar_activate_t  = nil
    tracker.chest_opened      = false
    tracker.chest_opened_t    = nil
    tracker.run_done          = false
    tracker.run_start_t       = get_time_since_inject and get_time_since_inject() or 0
    tracker.boss_quest_seen   = false
    tracker.current_task      = { name = 'idle', status = 'idle' }
end

return tracker
