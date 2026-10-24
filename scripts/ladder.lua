-- Ladders (2026-10-08, the Stalker 2 profile's ladder input override, adapted).
--
-- Symptom: climbing DOWN a ladder the view does not turn to face it and the player clips through the world.
-- MCP trace (descending BP_Ladder_C_0): PlayerCharacter.SetLadderReferenceAndActivateAbility sets
-- Pawn.LadderReference and activates GA_ClimbingLadder_C in the same tick; the ability calls
-- ResetCameraRotation every tick in the later part of the climb (it drives the control rotation to face the
-- ladder) and ends in the tick LadderReference goes back to nil. Yet the pawn's yaw and the control yaw stayed
-- at the approach yaw for the whole climb: libs/input.lua writes the HMD aim into the control rotation every tick,
-- overwriting the game's ladder turn.
--
-- Fix: tick input.lua's "Disabled" override for the whole climb (pawn.LadderReference ~= nil, read every tick, so
-- it is off from the first ladder tick). setDisabled(true) also clears input.lua's decoupled yaw / body offset, so
-- when the climb ends the view re-seeds from the pawn's NEW facing - the is_input_disabled callback path alone
-- kept the stale pre-ladder yaw in Stalker 2. A manual tick of the checkbox is never touched (we only release an
-- override we set). Applies in every hands mode: input.lua writes the control rotation in all of them.
--
-- Hands during the climb: montage state rule "* Rule: Ladder" (uevrmenus.lua) hides the VR hands / IK arms and shows
-- the game's arms on the rungs; editable in the Montage Config panel.

local uevrUtils = require('libs/uevr_utils')
local input = require('libs/input')
local configui = require('libs/configui')

local ladderOwnsOverride = false

local function setInputOverride(val)
	input.setDisabled(val)
	pcall(configui.setValue, "uevr_input_isDisabledOverride", val, true) -- keep the dev panel checkbox in sync, no callbacks
end

local function isOnLadder()
	local onLadder = false
	pcall(function()
		local pawn = uevr.api:get_local_pawn(0)
		onLadder = pawn ~= nil and pawn.LadderReference ~= nil
	end)
	return onLadder
end
_G.hrIsOnLadder = isOnLadder

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local wantDisabled = isOnLadder()
	if wantDisabled and not ladderOwnsOverride then
		if not input.isDisabledOverride() then
			setInputOverride(true)
			ladderOwnsOverride = true
			print("[ladder] on ladder: input.lua override on")
		end
	elseif not wantDisabled and ladderOwnsOverride then
		ladderOwnsOverride = false
		setInputOverride(false)
		print("[ladder] off ladder: input.lua override released")
	end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
	if ladderOwnsOverride then
		ladderOwnsOverride = false
		setInputOverride(false)
	end
end)
