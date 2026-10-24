-- Quick turn (2026-10-12).
--
-- The game's own quick turn does nothing in VR: libs/input.lua owns the pawn / view yaw (decoupled yaw), so whatever
-- the game turns is overwritten. This does the turn through input.lua instead (input.addTurn, applied like a snap
-- turn): hold the LEFT stick down (toward you) and click the RIGHT stick (R3). While the left stick is held down the R3 click is kept
-- from the game, so it does not also trigger the game's R3 action.

local uevrUtils = require('libs/uevr_utils')
local input     = require('libs/input')
local configui  = require('libs/configui')

local XINPUT_RIGHT_THUMB = 0x0080
local COOLDOWN_S = 0.4

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 5.1, label = "Quick Turn", layout = {
    { widgetType = "checkbox", id = "qt_enabled", label = "Quick turn: hold the left stick down + click the right stick (R3)", initialValue = true },
    { widgetType = "slider_float", id = "qt_angle", label = "Turn angle (deg)", initialValue = 180.0, range = {90.0, 180.0}, speed = 1.0 },
    { widgetType = "slider_float", id = "qt_stick", label = "How far down the stick must be (0-1)", initialValue = 0.6, range = {0.3, 0.95}, speed = 0.01 },
}})

local function cfgNum(id, default)
    local v = configui.getValue(id)
    if type(v) ~= "number" then return default end
    return v
end

local clickWasDown = false
local nextTurnAt = 0

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    local click = (state.Gamepad.wButtons & XINPUT_RIGHT_THUMB) ~= 0
    local pressed = click and not clickWasDown
    clickWasDown = click
    if configui.getValue("qt_enabled") == false then return end
    if state.Gamepad.sThumbLY > -cfgNum("qt_stick", 0.6) * 32767 then return end
    if not click then return end
    state.Gamepad.wButtons = state.Gamepad.wButtons & ~XINPUT_RIGHT_THUMB
    if not pressed or os.clock() < nextTurnAt then return end
    if _G.hrCutsceneActive == true or (_G.hrIsInMenu ~= nil and _G.hrIsInMenu()) then return end
    nextTurnAt = os.clock() + COOLDOWN_S
    input.addTurn(cfgNum("qt_angle", 180.0))
end, 20)

print("[quick_turn] loaded")
