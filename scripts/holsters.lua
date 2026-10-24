-- Holsters / gesture zones (2026-10-16). Right grip pressed with the right hand in a zone = a game button tap:
--   front of the face (in front of the HMD) -> R3        flashlight on / off
--   left hip                                -> d-pad up    weapon slot 1 (melee)
--   right hip                               -> d-pad right weapon slot 2
--   right shoulder                          -> d-pad down  weapon slot 3
--   left shoulder                           -> d-pad left  weapon slot 4
--
-- Face: libs/gestures.lua's "eyes" gesture (hand within 15 cm in front of the HMD, grip edge - GLASSESGRAB).
-- Body zones: boxes around the head in the HMD's yaw-only frame - origin = HMD position, yaw = HMD yaw (pitch / roll
-- ignored, so looking down at a hip does not move the zones; turning the head does, like Stalker 2). X forward,
-- Y right, Z up, cm. (The pawn's yaw was used first, but with input.lua's pawnRotationMode 4 it follows the HMD yaw
-- within 0.05 s anyway, and while seated it is frozen - the HMD yaw is the same in play and predictable everywhere.) The libs have no body-zone gesture, so these are measured here with
-- libs/controllers.lua positions.
-- A zone press is a grip press that STARTS in the zone (holding the grip and moving into a zone does nothing). The
-- grip (RB) is kept from the game until it is released, so the game never sees that press. A short haptic pulse when
-- the hand enters a zone tells you where you are. Off in menus, cutscenes, videos, focus puzzles / inspection.

local uevrUtils   = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local gestures    = require('libs/gestures')
local configui    = require('libs/configui')

local vr = uevr.params.vr

local BTN_RB     = 0x0200 -- XINPUT_GAMEPAD_RIGHT_SHOULDER (the right grip)
local BTN_R3     = 0x0080 -- XINPUT_GAMEPAD_RIGHT_THUMB
local BTN_UP     = 0x0001
local BTN_DOWN   = 0x0002
local BTN_LEFT   = 0x0004
local BTN_RIGHT  = 0x0008
local TAP_POLLS  = 3
local TAP_MAX_S  = 0.25

-- body zones: id, label, button, default centre (cm, body frame)
local ZONES = {
    { id = "lhip",  label = "Left hip (slot 1 / melee)", button = BTN_UP,    x = 0.0,   y = -22.0, z = -65.0 },
    { id = "rhip",  label = "Right hip (slot 2)",        button = BTN_RIGHT, x = 0.0,   y = 22.0,  z = -65.0 },
    { id = "rsh",   label = "Right shoulder (slot 3)",   button = BTN_DOWN,  x = -12.0, y = 20.0,  z = -10.0 },
    { id = "lsh",   label = "Left shoulder (slot 4)",    button = BTN_LEFT,  x = -12.0, y = -20.0, z = -10.0 },
}

local layout = {
    { widgetType = "checkbox", id = "hz_enabled", label = "Holsters: right grip at hips / shoulders = weapon slots, at the face = flashlight", initialValue = true },
    { widgetType = "checkbox", id = "hz_face", label = "Flashlight (R3): right grip in front of the face", initialValue = true },
    { widgetType = "checkbox", id = "hz_haptic", label = "Haptic pulse when the hand enters a zone", initialValue = true },
    { widgetType = "slider_float", id = "hz_size", label = "Zone size (cm, half width of each box)", initialValue = 16.0, range = {6.0, 35.0}, speed = 0.5 },
    { widgetType = "text", id = "hz_status", label = "Hand: -" },
    { widgetType = "text", label = "Zone centres (cm from the HMD: forward / right / up, body facing)" },
}
for _, z in ipairs(ZONES) do
    table.insert(layout, { widgetType = "drag_float3", id = "hz_" .. z.id, label = z.label, initialValue = { z.x, z.y, z.z }, range = {-120, 120}, speed = 0.5 })
end
_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 2.5, label = "Holsters", layout = layout })

local function cfgNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end

-- configui drag_float3 values come back as vectors (X/Y/Z) or arrays
local function zoneCentre(z)
    local v = configui.getValue("hz_" .. z.id)
    if type(v) == "table" or type(v) == "userdata" then
        local ok, x, y, zz = pcall(function() return v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3] end)
        if ok and type(x) == "number" and type(y) == "number" and type(zz) == "number" then return x, y, zz end
    end
    return z.x, z.y, z.z
end

local function blocked()
    if _G.hrCutsceneActive == true then return true end
    if _G.hrIsInMenu ~= nil and _G.hrIsInMenu() then return true end
    if _G.hrIsVideoPlaying ~= nil and _G.hrIsVideoPlaying() then return true end
    if _G.hrIsInFocusPuzzle ~= nil and _G.hrIsInFocusPuzzle() then return true end
    return false
end

local function zoneYaw(hmdRot)
    return (hmdRot and hmdRot.Yaw) or 0
end

-- right hand in the zone frame: returns local x, y, z (cm) or nil
local function handLocal()
    local hand = controllers.getControllerLocation(Handed.Right)
    local head = controllers.getControllerLocation(2)
    if hand == nil or head == nil then return nil end
    local yaw = math.rad(zoneYaw(controllers.getControllerRotation(2)))
    local dx, dy, dz = hand.X - head.X, hand.Y - head.Y, hand.Z - head.Z
    local c, s = math.cos(yaw), math.sin(yaw)
    return dx * c + dy * s, -dx * s + dy * c, dz
end

local function zoneAt(x, y, z)
    local h = cfgNum("hz_size", 16.0)
    for _, zone in ipairs(ZONES) do
        local cx, cy, cz = zoneCentre(zone)
        if math.abs(x - cx) <= h and math.abs(y - cy) <= h and math.abs(z - cz) <= h then return zone end
    end
    return nil
end

local current = nil       -- zone the hand is in (from the last input poll)
local nextStatusAt = 0    -- panel status line throttle
local gripWasDown = false
local swallowGrip = false -- the current grip press started a zone action: keep RB from the game until released
local tap = { button = 0, polls = 0, deadline = 0 }

local function startTap(button, what)
    tap.button, tap.polls, tap.deadline = button, TAP_POLLS, os.clock() + TAP_MAX_S
    pcall(function() vr.trigger_haptic_vibration(0, 0.08, 1.0, 1.0, vr.get_right_joystick_source()) end)
    print("[holsters] " .. what)
end

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    local grip = uevrUtils.isButtonPressed(state, BTN_RB)
    local pressed = grip and not gripWasDown
    gripWasDown = grip

    if swallowGrip then
        if grip then state.Gamepad.wButtons = state.Gamepad.wButtons & ~BTN_RB else swallowGrip = false end
    end

    if configui.getValue("hz_enabled") ~= false and not blocked() then
        local ok, err = pcall(function()
            local x, y, z = handLocal()
            local zone = x ~= nil and zoneAt(x, y, z) or nil
            if zone ~= current then
                current = zone
                if zone ~= nil and configui.getValue("hz_haptic") ~= false then
                    pcall(function() vr.trigger_haptic_vibration(0, 0.03, 1.0, 0.4, vr.get_right_joystick_source()) end)
                end
            end
            -- status line at most 5x a second (perf pass 2026-10-17: it ran on every input poll)
            if x ~= nil and os.clock() >= nextStatusAt then
                nextStatusAt = os.clock() + 0.2
                configui.setLabel("hz_status", string.format("Hand: %.0f / %.0f / %.0f cm - %s", x, y, z, zone and zone.label or "no zone"))
            end
            -- face: the gestures lib edge-detects its own grip press (call once per poll)
            local faceGrip = false
            if configui.getValue("hz_face") ~= false then
                local _, gripEyes = gestures.getHeadGestures(state, Handed.Right, false)
                faceGrip = gripEyes == true
            end
            if pressed and tap.polls <= 0 then
                if faceGrip then
                    swallowGrip = true
                    startTap(BTN_R3, "flashlight (R3)")
                elseif zone ~= nil then
                    swallowGrip = true
                    startTap(zone.button, zone.label)
                end
            end
        end)
        if not ok then print("[holsters] " .. tostring(err)) end
    elseif current ~= nil then
        current = nil
    end

    if swallowGrip and grip then state.Gamepad.wButtons = state.Gamepad.wButtons & ~BTN_RB end
    if tap.polls > 0 then
        if os.clock() > tap.deadline then
            tap.polls = 0
        else
            state.Gamepad.wButtons = state.Gamepad.wButtons | tap.button
            tap.polls = tap.polls - 1
        end
    end
end, 25) -- before physical_melee / throwables (20) and the hands grip pose (10)

uevrUtils.registerPreLevelChangeCallback(function(level)
    current, swallowGrip, tap.polls = nil, false, 0
end)

print("[holsters] loaded")
