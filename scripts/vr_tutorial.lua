-- VR tutorial (2026-11-12): image pages explaining the VR controls, ported from the Atomic Heart profile's
-- libs/tutorial.lua (jbusfield's uevrlib). Pages: data/tutorial/intro.png + 1.png .. N.png (counted at runtime), icons
-- data/tutorial/buttons/. Pages are rendered from the launcher art by UnrealVRMod\0. Hellraiser Tutorial\make_pages.ps1.
--
--   * First start: shown once at the first level (the main menu), and the intro waits until the player has done the
--     open gesture once (forceInteractionAtStartup). Finishing it ("Done" on the last page) or "Hide at startup" stops
--     the automatic show; data/tutorial_state.json remembers that, the gesture and the last page.
--   * Any time: left controller up to the eyes + left trigger opens it again at the saved page (libs/gestures EYESCRATCH:
--     within 15 cm in front of the HMD). Not while that trigger belongs to something else: menus, cutscenes, videos,
--     puzzles / inspection, the chair, ladders, the boss grab, two-handing, an LT-grabbed item, the cube in the left
--     hand - the gate is asked only once the gesture is detected, and a refused pull reaches the game unchanged.
--   * While open: every button is kept from the game and the other scripts (A next / start / done, X back, B close,
--     Y hide at startup - physical buttons, read before buttonswitch.lua's X/B swap), the UI stays in place (ui.lua
--     viewLocked, own owner slot) and the game is paused when opened in gameplay (panel option).
-- Panel section "VR Tutorial": show now, gesture on/off, pause on/off, show again at the next start.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local tutorial = require('libs/tutorial')

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 6.7, label = "VR Tutorial", layout = {
	{ widgetType = "button", id = "tut_show", label = "Show the VR tutorial", size = {220, 24} },
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

-- false while the left trigger near the eyes belongs to something else
local function gestureAllowed()
	if not enabled("tut_gesture") then return false end
	if call(_G.hrIsInMenu) or call(_G.hrIsVideoPlaying) or call(_G.hrIsCutscene) or _G.hrCutsceneActive == true then return false end
	if call(_G.hrIsInFocusPuzzle) or call(_G.hrIsSeated) or call(_G.hrIsOnLadder) or call(_G.hrIsStrangled) then return false end
	if _G.isTwoHandingActive == true or call(_G.hrIsHoldingItem) or call(_G.hrIsCubeHeld) then return false end
	return true
end

local t = tutorial.new({
	imageSize = 1536,
	pauseGame = enabled("tut_pause"),
	disableControllerMouse = false, -- Hellraiser's ui.lua has no controllerMouse state
	buttons = { start = "A", next = "A", done = "A", back = "X", close = "B", skip = "B", hideAtStartup = "Y" },
	openGestureCondition = gestureAllowed,
})
t:forceInteractionAtStartup(true)
t:showOnce()

local function updateStatus()
	configui.setLabel("tut_status", t:isCompleted() and "Shown at start: no (finished or hidden)" or "Shown at start: yes")
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
		t:show(t:getSavedPage() or 1)
	elseif action == "reset" then
		t:resetCompleted()
		t:resetInteraction()
		t:resetSavedPage()
	end
	updateStatus()
end)

uevrUtils.setTimeout(1000, updateStatus)
