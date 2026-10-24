-- Keypad puzzles in VR (2026-10-09).
--
-- Keypads are BP_EnvPuzzleNumpad_C (focus puzzles: the view target is the BP_TASK_FocusEnvPuzzle_C camera task, which is
-- the numpad's ParentTaskActor). The selected key is shown by an OVERLAY material on that key's mesh
-- (CurrentOverlayedComponent.OverlayMaterial = OverlayMatRef, a MID of MI_PuzzleNumpad: masked, unlit Fresnel rim with
-- scalar "Exponent" = 1.0). The rim is so thin that in VR it only shows when leaning right up to the keypad. A lower
-- Fresnel exponent widens it, so the active keypad's MID gets the panel's exponent (polled every 0.5 s while a focus
-- puzzle is up - each keypad has its own MID; the game's value is put back when the puzzle ends).

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 6.8, label = "Keypads", layout = {
    { widgetType = "checkbox", id = "kp_wide_highlight", label = "Make the selected-key highlight easier to see", initialValue = true },
    { widgetType = "slider_float", id = "kp_exponent", label = "Highlight rim exponent (lower = wider, game 1.0)", initialValue = 0.25, range = {0.02, 1.0}, speed = 0.01 },
    { widgetType = "slider_float", id = "kp_view_forward", label = "Move the view closer during keypads / lockpicks (cm)", initialValue = 15.0, range = {0.0, 60.0}, speed = 0.5 },
}})

-- Focus puzzles (keypads, lockpicks) put the view at the game's puzzle camera, which in VR felt too far to read the keys.
-- While one is up, UEVR's camera forward offset (VR_CameraForwardOffset) is raised by the panel value and put back to the
-- user's own value afterwards. Only for view-target focus puzzles, not item inspection (that item is already placed).
local vr = uevr.params.vr
local viewOffset = { applied = nil, orig = nil }
local function isViewTargetPuzzle()
    local isPuzzle = false
    pcall(function()
        local pc = uevr.api:get_player_controller(0)
        local t = pc ~= nil and pc:GetViewTarget() or nil
        isPuzzle = t ~= nil and string.find(t:get_class():get_full_name(), "FocusEnvPuzzle", 1, true) ~= nil
    end)
    return isPuzzle
end
local function applyViewOffset(wanted)
    if wanted ~= nil and wanted > 0 then
        if viewOffset.orig == nil then viewOffset.orig = tonumber(vr:get_mod_value("VR_CameraForwardOffset")) or 0 end
        local v = viewOffset.orig + wanted
        if viewOffset.applied ~= v then
            vr.set_mod_value("VR_CameraForwardOffset", tostring(v))
            viewOffset.applied = v
        end
    elseif viewOffset.orig ~= nil then
        vr.set_mod_value("VR_CameraForwardOffset", tostring(viewOffset.orig))
        viewOffset.orig, viewOffset.applied = nil, nil
    end
end

local childActorClass = nil
local active = nil -- { mid, orig, applied }
local nextCheck = 0

local function findNumpad(task)
    if childActorClass == nil then childActorClass = uevrUtils.get_class("Class /Script/Engine.ChildActorComponent") end
    local numpad = nil
    pcall(function()
        for _, c in ipairs(task:K2_GetComponentsByClass(childActorClass) or {}) do
            local a = c.ChildActor
            if a ~= nil and string.find(a:get_class():get_full_name(), "Numpad", 1, true) ~= nil then numpad = a return end
        end
    end)
    return numpad
end

local function restore()
    if active == nil then return end
    local a = active
    active = nil
    if a.orig ~= nil then pcall(function() a.mid:SetScalarParameterValue(uevrUtils.fname_from_string("Exponent"), a.orig) end) end
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if os.clock() < nextCheck then return end
    nextCheck = os.clock() + 0.5
    pcall(function()
        local inMenu = _G.hrIsInMenu ~= nil and _G.hrIsInMenu()
        applyViewOffset((not inMenu and isViewTargetPuzzle()) and (configui.getValue("kp_view_forward") or 15.0) or nil)
    end)
    local ok, err = pcall(function()
        if configui.getValue("kp_wide_highlight") == false or not (_G.hrIsInFocusPuzzle ~= nil and _G.hrIsInFocusPuzzle()) then
            restore()
            return
        end
        local pc = uevr.api:get_player_controller(0)
        local task = pc ~= nil and pc:GetViewTarget() or nil
        if task == nil or string.find(task:get_class():get_full_name(), "FocusEnvPuzzle", 1, true) == nil then restore() return end
        local numpad = findNumpad(task)
        local mid = numpad ~= nil and numpad.OverlayMatRef or nil
        if mid == nil then restore() return end
        if active == nil or active.mid ~= mid then
            restore()
            local orig = nil
            pcall(function() orig = mid:K2_GetScalarParameterValue(uevrUtils.fname_from_string("Exponent")) end)
            active = { mid = mid, orig = orig }
        end
        local want = configui.getValue("kp_exponent") or 0.25
        if active.applied ~= want then
            mid:SetScalarParameterValue(uevrUtils.fname_from_string("Exponent"), want)
            active.applied = want
        end
    end)
    if not ok then print("[keypad_vr] " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    active = nil
    pcall(applyViewOffset, nil) -- never leave the puzzle offset behind
end)

print("[keypad_vr] loaded")
