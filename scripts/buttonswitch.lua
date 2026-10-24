-- Swaps the gamepad X and B buttons the game sees (port of the OW2 profile's buttonswitch.lua), as an option in the
-- "Hellraiser VR" panel (section "Controls"). The OW2 version remapped one at a time with block flags; this is a
-- plain bit swap, so holding both buttons keeps both pressed.

local configui = require('libs/configui')

local XINPUT_X = 0x4000
local XINPUT_B = 0x2000

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 5, label = "Controls", layout = {
	{ widgetType = "checkbox", id = "ctl_swap_xb", label = "Swap X and B buttons", initialValue = true },
}})

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
	if state == nil then return end
	if configui.getValue("ctl_swap_xb") == false then return end -- nil until the panel exists: treat as the default (on)
	local buttons = state.Gamepad.wButtons
	local x = (buttons & XINPUT_X) ~= 0
	local b = (buttons & XINPUT_B) ~= 0
	if x == b then return end -- neither or both pressed: nothing to swap
	buttons = buttons & ~(XINPUT_X | XINPUT_B)
	if x then buttons = buttons | XINPUT_B end
	if b then buttons = buttons | XINPUT_X end
	state.Gamepad.wButtons = buttons
end)
