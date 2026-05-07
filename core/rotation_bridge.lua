-- ---------------------------------------------------------------------------
-- core/rotation_bridge.lua
--
-- Cross-plugin signalling to the user's UniversalRotation plugin.  When
-- WarMachine is in a TRAVEL phase (walking between POIs, walking back
-- to the boss anchor, etc. -- not actively engaged with a kill target),
-- we set a global flag the rotation reads to suppress non-self-cast
-- spells.  The result: defensive cooldowns / barriers / mist / bone
-- storm / iron skin still fire, but offensive nukes don't blow CDs and
-- resources on stragglers we're walking past.
--
-- Design discussion is in the chat log; tldr: there's no plugin global
-- on UniversalRotation to call into, so the contract is a single
-- `_G.EXTERNAL_ROTATION_TRAVEL_MODE` boolean.  UniversalRotation reads
-- it in its rotation_engine.lua spell loop and skips spells where
-- `cfg.self_cast == false`.  `self_cast` is the existing per-spell
-- checkbox in the rotation profile -- defensives are conventionally
-- self_cast in real builds, so no new tagging is required.  The
-- contract is intentionally generic so other plugins (Gem Farmer, etc.)
-- can use the same channel without UR caring who set the flag.
--
-- Usage from a task:
--
--   local rotation = require 'core.rotation_bridge'
--   rotation.set_travel_mode(true)        -- entering travel phase
--   rotation.set_travel_mode(false)       -- engaging combat / interacting
--
-- Idempotent + cheap; safe to call every pulse.
-- ---------------------------------------------------------------------------

local M = {}

-- Single source of truth for the cross-plugin flag.  Direct global
-- access is intentional -- we don't want to require the rotation plugin
-- to load WarMachine modules.
M.set_travel_mode = function (active)
    _G.EXTERNAL_ROTATION_TRAVEL_MODE = active and true or false
end

M.get_travel_mode = function ()
    return _G.EXTERNAL_ROTATION_TRAVEL_MODE == true
end

-- ---------------------------------------------------------------------------
-- Kill-target hint.
--
-- Activities (hordes/kill_monster, nmd/kill_monster, etc.) call
-- set_kill_target(actor) every Execute pulse with the actor they've
-- chosen to engage.  UniversalRotation reads `_G.EXTERNAL_ROTATION_TARGET`
-- in its spell loop and prefers it over its own target_selector pick
-- when present + valid -- so when WarMachine decides we're attacking
-- the Soulspire 30y away, UR casts at the Soulspire instead of the
-- closer mob the orbwalker is auto-targeting.  Without this, UR was
-- firing spells at whichever enemy the host's enemy stream put first,
-- and orbwalker's cursor was pulling the bot's facing back to those
-- mobs -- the user-reported "keeps turning around to fight monsters"
-- symptom when WarMachine wants to engage a structure.
--
-- Set `actor` to the Lua-side actor object (NOT a position).  Pass nil
-- to clear (e.g. when no target is chosen this pulse).  UR ignores the
-- hint if the actor is dead / untargetable / out of the spell's range.
-- ---------------------------------------------------------------------------
M.set_kill_target = function (actor)
    _G.EXTERNAL_ROTATION_TARGET = actor or nil
end

M.get_kill_target = function ()
    return _G.EXTERNAL_ROTATION_TARGET
end

-- Convenience: reset all cross-plugin state.  Used on plugin shutdown /
-- mode change / activity deactivate so stale flags / target hints don't
-- outlive WarMachine.
M.clear = function ()
    _G.EXTERNAL_ROTATION_TRAVEL_MODE = false
    _G.EXTERNAL_ROTATION_TARGET      = nil
end

return M
