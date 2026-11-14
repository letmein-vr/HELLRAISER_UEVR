-- VR tutorial: image pages explaining the VR controls, ported from the Atomic Heart profile's libs/tutorial.lua
-- (jbusfield's uevrlib) + the Cronos additions (gesture toggle, setCompleted, slot-0 guard). Pages: data/tutorial/intro.png
-- + 1.png .. N.png (counted at runtime), icons data/tutorial/buttons/. They are rendered from the launcher art by
-- UnrealVRMod\0. Hellraiser Tutorial\make_pages.ps1.
--
--   * Startup (2026-11-14, same rules as Cronos 1.7): shown when gameplay is first reached (never in the main menu,
--     loading, videos or in-world cutscenes, see inGameplay), unless the panel option "Show it when gameplay starts"
--     (tut_startup) is off. It keeps coming back at every start until the player closes it once (B or the gesture),
--     finishes it ("Done" on the last page) or turns on "Hide at startup" (Y). After that only the gesture opens it, in
--     the same session or any later one. data/tutorial_state.json remembers that, plus the last page; it is never
--     shipped, and the launcher carries it over on updates.
--   * Any time: left controller up to the eyes + left trigger opens it at the saved page (libs/gestures EYESCRATCH:
--     within 15 cm in front of the HMD). The trigger has to be PULLED there: a left trigger that is already held when
--     the hand passes the eyes never opens it. Opening is refused only while that pull belongs to something else
--     (menus / pause, cutscenes, videos, puzzles, the chair, ladders, the boss grab, two-handing, an LT-grabbed item,
--     the cube in the left hand); a refused pull reaches the game unchanged.
--   * While open: every button is kept from the game and the other scripts (A next / start / done, X back, B close,
--     Y hide at startup - physical buttons, read before buttonswitch.lua's X/B swap), the UI stays in place (ui.lua
--     viewLocked, own owner slot) and the game is paused (panel option). The gesture closes it again on any page, with
--     no gate (gestureCloses).
-- Panel section "VR Tutorial": show now, show at gameplay start, gesture on/off, pause on/off, show again next start.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local controllers = require('libs/controllers')
local tutorial = require('libs/tutorial')

local PLAYER_PAWN_CLASS = "CH_FirstPersonPlayable_C"

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 6.7, label = "VR Tutorial", layout = {
	{ widgetType = "button", id = "tut_show", label = "Show the VR tutorial", size = {220, 24} },
	{ widgetType = "checkbox", id = "tut_startup", label = "Show it when gameplay starts (until closed once)", initialValue = true },
	{ widgetType = "checkbox", id = "tut_gesture", label = "Open it with the left trigger at your eyes", initialValue = true },
	{ widgetType = "checkbox", id = "tut_pause", label = "Pause the game while it is open", initialValue = true },
	{ widgetType = "button", id = "tut_reset", label = "Show it again at the next start", size = {260, 24} },
	{ widgetType = "text", id = "tut_status", label = "" },
}})

local function enabled(id)
	return configui.getValue(id) ~= false -- nil until the panel exists: the initial value (true)
end

local function call(fn)
	if type(fn) ~= "function" then return false end
	local ok, result = pcall(fn)
	return ok and result == true
end

-- Rising edge of the left trigger, from the raw pad before the tutorial's gesture check (priority 100001) and every
-- other handler. gestures.lua's face detector uses the same threshold (bLeftTrigger > 128).
local TRIGGER_THRESHOLD = 128
local leftTriggerWasDown = false
local leftTriggerPulled = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, userIndex, state)
	if userIndex ~= nil and userIndex ~= 0 then return end
	local down = state.Gamepad.bLeftTrigger > TRIGGER_THRESHOLD
	leftTriggerPulled = down and not leftTriggerWasDown
	leftTriggerWasDown = down
end, 100002)

local function isPaused()
	local ok, result = pcall(function()
		local world = uevrUtils.get_world()
		return Statics ~= nil and world ~= nil and Statics:IsGamePaused(world)
	end)
	return ok and result == true
end

-- a cutscene, video, puzzle or other scripted state where the game owns the view / hands (not gameplay)
local function inScriptedState()
	if call(_G.hrIsVideoPlaying) or call(_G.hrIsCutscene) or _G.hrCutsceneActive == true then return true end
	if call(_G.hrIsInFocusPuzzle) or call(_G.hrIsSeated) or call(_G.hrIsOnLadder) or call(_G.hrIsStrangled) then return true end
	return false
end

-- false while the left trigger near the eyes belongs to something else (asked only once the gesture is detected, and
-- only to open: closing is never gated)
local function gestureAllowed()
	if not enabled("tut_gesture") then return false end
	if not leftTriggerPulled then return false end
	if call(_G.hrIsInMenu) or isPaused() or inScriptedState() then return false end
	if _G.isTwoHandingActive == true or call(_G.hrIsHoldingItem) or call(_G.hrIsCubeHeld) then return false end
	return true
end

-- true while the tutorial on screen is the automatic startup one: closing that one stops the startup show
local startupShow = false
-- true until the startup tutorial has been shown in gameplay this session (see inGameplay below)
local startupPending = false

local t = tutorial.new({
	imageSize = 1536,
	pauseGame = enabled("tut_pause"),
	disableControllerMouse = false, -- Hellraiser's ui.lua has no controllerMouse state
	buttons = { start = "A", next = "A", done = "A", back = "X", close = "B", skip = "B", hideAtStartup = "Y" },
	labels = { close = "Close (or gesture)" },
	openGestureCondition = gestureAllowed,
	gestureCloses = true, -- the open gesture is a toggle: it closes the tutorial on any page too
	onClose = function(self, reason)
		if reason == "level_change" then
			-- closed without the player choosing to: the startup tutorial comes back in the next gameplay
			if startupShow then startupPending = true end
			startupShow = false
			return
		end
		if startupShow and (reason == "closed" or reason == "skipped") then self:setCompleted(true) end
		startupShow = false
	end,
})

-- The startup tutorial waits for real gameplay:
--   * the pawn is the player character (CH_FirstPersonPlayable_C; the main menu has no such pawn)
--   * no menu (menus.lua: mouse cursor shown), not paused
--   * the VR controllers exist (libs/gestures reads the cached left controller and HMD for the gesture)
--   * no video, cutscene (incl. the in-world ones that put the pawn in Flying = hrIsSeated), puzzle, ladder, boss grab
-- and all of that has held for STARTUP_STABLE_S, so a short gap between two cutscene signals does not count.
local function inGameplay()
	local ok, result = pcall(function()
		local pawn = uevr.api:get_local_pawn(0)
		if pawn == nil or pawn:get_class():get_fname():to_string() ~= PLAYER_PAWN_CLASS then return false end
		if call(_G.hrIsInMenu) or isPaused() then return false end
		if not controllers.controllerExists(Handed.Left) or not controllers.hmdControllerExists() then return false end
		return not inScriptedState()
	end)
	return ok and result == true
end

startupPending = not t:isCompleted()
local STARTUP_POLL_S = 0.5
local STARTUP_STABLE_S = 2.0
local startupPollTimer = 0
local gameplaySince = nil
uevrUtils.registerPreEngineTickCallback(function(engine, delta)
	if not startupPending or t:isOpen() then return end
	startupPollTimer = startupPollTimer + (tonumber(delta) or 0)
	if startupPollTimer < STARTUP_POLL_S then return end
	local elapsed = startupPollTimer
	startupPollTimer = 0
	if t:isCompleted() then startupPending = false return end
	if not enabled("tut_startup") or not inGameplay() then -- option off: keep waiting in case it is turned back on
		gameplaySince = nil
		return
	end
	gameplaySince = (gameplaySince or 0) + elapsed
	if gameplaySince >= STARTUP_STABLE_S then
		startupPending = false
		gameplaySince = nil
		startupShow = t:showOnce()
	end
end)

uevrUtils.registerPreLevelChangeCallback(function()
	gameplaySince = nil
end)

local function updateStatus()
	configui.setLabel("tut_status", t:isCompleted() and "Shown at start: no (closed, finished or hidden)" or "Shown at start: yes")
end

-- Panel buttons run while UEVR draws its overlay: widgets are made on the next engine tick instead
local pending = nil
configui.onUpdate("tut_show", function() pending = "show" end)
configui.onUpdate("tut_reset", function() pending = "reset" end)
configui.onCreateOrUpdate("tut_pause", function(value) t.options.pauseGame = value ~= false end)

uevrUtils.registerPreEngineTickCallback(function()
	if pending == nil then return end
	local action = pending
	pending = nil
	if action == "show" then
		startupShow = false
		t:show(t:getSavedPage() or 1)
	elseif action == "reset" then
		startupShow = false
		t:resetCompleted()
		t:resetInteraction()
		t:resetSavedPage()
	end
	updateStatus()
end)

uevrUtils.setTimeout(1000, updateStatus)
