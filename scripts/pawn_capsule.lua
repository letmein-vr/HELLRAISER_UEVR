-- Player capsule radius (2026-10-09).
--
-- The player's collision capsule (Pawn.CapsuleComponent) has a 49 cm radius (MCP; half height 92), which keeps the VR
-- view about half a metre from walls, doors and desks. A smaller radius lets the player get closer to things. Applied
-- with SetCapsuleRadius every 0.5 s when it differs (new pawn after a level / save load, or the game changing it);
-- unticking the checkbox puts the game's own radius back.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 4.5, label = "Player Capsule", layout = {
    { widgetType = "checkbox", id = "cap_enabled", label = "Use a custom capsule radius (get closer to things)", initialValue = false },
    { widgetType = "slider_float", id = "cap_radius", label = "Capsule radius (cm, game 49)", initialValue = 30.0, range = {10.0, 49.0}, speed = 0.5 },
    { widgetType = "text", id = "cap_status", label = "Capsule: -" },
}})

local PLAYER_PAWN_CLASS = "CH_FirstPersonPlayable_C"
local state = { capsule = nil, gameRadius = nil, applied = nil }
local nextCheck = 0

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if os.clock() < nextCheck then return end
    nextCheck = os.clock() + 0.5
    local ok, err = pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        if pawn == nil or pawn:get_class():get_fname():to_string() ~= PLAYER_PAWN_CLASS then return end
        local capsule = pawn.CapsuleComponent
        if capsule == nil then return end
        if state.capsule ~= capsule then
            state.capsule = capsule
            state.gameRadius = capsule:GetUnscaledCapsuleRadius()
            state.applied = nil
        end
        local current = capsule:GetUnscaledCapsuleRadius()
        -- the game changed it itself (not our last write): take that as its new value
        if state.applied ~= nil and math.abs(current - state.applied) > 0.01 then
            state.gameRadius = current
            state.applied = nil
        end
        local wanted = state.gameRadius
        if configui.getValue("cap_enabled") == true then wanted = configui.getValue("cap_radius") or 30.0 end
        if wanted ~= nil and math.abs(current - wanted) > 0.01 then
            capsule:SetCapsuleRadius(wanted, true)
        end
        state.applied = (configui.getValue("cap_enabled") == true) and wanted or nil
        configui.setLabel("cap_status", string.format("Capsule: radius %.1f cm (game %.1f)", wanted or current, state.gameRadius or current))
    end)
    if not ok then print("[pawn_capsule] " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    state.capsule, state.gameRadius, state.applied = nil, nil, nil
end)

print("[pawn_capsule] loaded")
