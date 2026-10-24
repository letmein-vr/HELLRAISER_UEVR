-- Menus (2026-10-08): in the main menu, pause menu and inventory screens, aim like the flat game (input.lua off ->
-- UEVR "Game" aim) and keep the UI fixed in place (UEVR "UI follows view" off).
--
-- Detection (MCP watch 2026-10-08): the player controller's bShowMouseCursor is true in every menu screen (main
-- menu, pause, inventory) and false in gameplay; the main menu also has no player pawn (HUD_MainMenu_C). Pause and
-- inventory keep the CH_FirstPersonPlayable_C pawn, so the cursor is the signal for those.
--
-- Applied through libs/ui.lua's custom states, so ui.lua stays the one owner of these settings:
--   viewLocked = true    -> ui.lua sets UI_FollowView off (and recenters the view onto the locked UI)
--   inputEnabled = false -> ui.lua's is_input_disabled callback disables input.lua (game aim)
-- Leaving the menu clears both states and ui.lua's normal values (your UI-follows-view setting) come back. The
-- callback path is used on purpose instead of input.setDisabled(): that re-seeds the view from the pawn's facing on
-- re-enable (right for ladders, but it would snap the view after every pause).

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local ui = require('libs/ui')

local PLAYER_PAWN_CLASS = "CH_FirstPersonPlayable_C"
local PRIORITY = 100

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 7, label = "Menus", layout = {
	{ widgetType = "checkbox", id = "menu_game_aim", label = "In menus: game aim + UI fixed in place (no UI follows view)", initialValue = true },
	{ widgetType = "text", id = "menu_status", label = "Menu: -" },
}})

local inMenuApplied = nil -- last state written to ui.lua

local function isInMenu()
	local inMenu = false
	pcall(function()
		local pawn = uevr.api:get_local_pawn(0)
		if pawn == nil or pawn:get_class():get_fname():to_string() ~= PLAYER_PAWN_CLASS then
			inMenu = true
			return
		end
		local pc = uevr.api:get_player_controller(0)
		inMenu = pc ~= nil and pc.bShowMouseCursor == true
	end)
	return inMenu
end
_G.hrIsInMenu = isInMenu

local function apply(inMenu)
	if inMenu then
		ui.setCustomState("viewLocked", true, PRIORITY)
		ui.setCustomState("inputEnabled", false, PRIORITY)
	else
		ui.setCustomState("viewLocked", nil)
		ui.setCustomState("inputEnabled", nil)
	end
	inMenuApplied = inMenu
	configui.setLabel("menu_status", inMenu and "Menu: open (game aim, UI fixed)" or "Menu: none")
end

uevrUtils.setInterval(100, function()
	local wanted = configui.getValue("menu_game_aim") ~= false and isInMenu()
	if wanted ~= inMenuApplied then apply(wanted) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
	-- a level change goes through the loading screen; re-evaluate on the next poll
	inMenuApplied = nil
end)
