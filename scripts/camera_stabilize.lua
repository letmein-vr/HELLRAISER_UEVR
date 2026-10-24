-- Camera stabilisation for Hellraiser (structure ported from the Outer Worlds 2 profile).
--
-- Live facts (MCP, 2026-10-07):
--   * Camera manager: CoreCameraManager, ModifierList = CameraAnimationCameraModifier (camera animation
--     sequences - melee swings, hits, finishers) + CameraModifier_CameraShake (every camera shake: gun
--     shots, melee impacts, explosions, damage).
--   * The pawn owns two CameraShakeSourceComponents: CameraShakeGunShot and CameraShakeComponent.
--   * The view comes from PlayerCameraComponent (CineCameraComponent inside the FPCameraActor child actor,
--     BP_PlayerCamera_C), which hangs from Pawn.Mesh bone camera_jnt. The ALS anim BP animates that bone
--     (walk bob, attack/recoil sway). bUsePawnControlRotation is already true (rotation = control rotation);
--     the POSITION is replaced by libs/input.lua (pawn root + capsule + headOffset), so the bone bob never
--     reaches the HMD view.
--   * UE 5.6 first-person rendering: the camera has bEnableFirstPersonScale = true (FirstPersonScale 0.2).
--     Any primitive left in FirstPerson mode is squashed toward the eye; weaponhook.lua already switches our
--     meshes to None, turning the camera feature off covers anything we missed (knife, effects).
-- Shake while meleeing / shooting is removed by disabling the two modifiers (nothing is applied to the
-- view at all) and, belt and braces, stopping the pawn's shake sources on every refresh. Each item has its
-- own checkbox; unticking re-enables it live.

local uevrUtils = require('libs/uevr_utils')
local configui  = require('libs/configui')

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 4, label = "Camera Stabilize", layout = {
            { widgetType = "checkbox", id = "cs_shake",       label = "Disable camera shakes (shooting, melee, hits)", initialValue = true },
            { widgetType = "checkbox", id = "cs_camera_anim", label = "Disable camera animations (melee etc.)", initialValue = true },
            { widgetType = "checkbox", id = "cs_fp_scale",    label = "Disable first-person scale (keeps weapons at real size)", initialValue = true },
            { widgetType = "checkbox", id = "cs_pawn_rot",    label = "Camera uses control rotation (kills anim sway)", initialValue = true },
            { widgetType = "checkbox", id = "cs_vignette",    label = "Remove the screen vignette (dark edges)", initialValue = true },
            { widgetType = "checkbox", id = "cs_blood_splash", label = "Remove the HUD blood splash (damage effect)", initialValue = true },
            { widgetType = "checkbox", id = "cs_hard_lock",   label = "Hard-lock VR camera yaw to control rotation (fallback)", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", id = "cs_status", label = "Status: waiting for camera manager" },
}})

local MODIFIERS = {
    { id = "cs_shake",       class = "CameraModifier_CameraShake" },
    { id = "cs_camera_anim", class = "CameraAnimationCameraModifier" },
}

local lastManager = nil
local lastApplied = {}
local nextRefresh = 0

local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

local function want(id)
    return configui.getValue(id) ~= false -- nil (panel not built yet) = initial value true
end

local function getCameraManager()
    local pc = uevr.api:get_player_controller(0)
    if pc == nil then return nil end
    local ok, cm = pcall(function() return pc.PlayerCameraManager end)
    if ok and alive(cm) then return cm end
    return nil
end

local function applyModifiers(cm, force)
    local applied = {}
    local ok, list = pcall(function() return cm.ModifierList end)
    if not ok or list == nil then return applied end
    for i = 1, #list do
        local mod = list[i]
        if alive(mod) then
            local cls = uevrUtils.getShortName(mod:get_class())
            for _, def in ipairs(MODIFIERS) do
                if cls == def.class then
                    local wantDisabled = want(def.id)
                    if force or lastApplied[def.id] ~= wantDisabled then
                        pcall(function()
                            if wantDisabled then
                                mod:DisableModifier(true)
                                if def.class == "CameraModifier_CameraShake" and cm.StopAllCameraShakes ~= nil then
                                    cm:StopAllCameraShakes(true)
                                end
                            else
                                mod:EnableModifier()
                            end
                        end)
                    elseif wantDisabled then
                        -- the game can re-enable a modifier on its own events; keep it down
                        pcall(function()
                            if mod.IsDisabled ~= nil and mod:IsDisabled() == false then mod:DisableModifier(true) end
                        end)
                    end
                    applied[def.id] = wantDisabled
                end
            end
        end
    end
    return applied
end

local function getPlayerCamera(pawn)
    local cam = nil
    pcall(function() cam = pawn.PlayerCameraComponent end)
    return alive(cam) and cam or nil
end

-- pawn-side settings, re-checked every refresh (the game re-creates the pawn / camera actor on respawn)
local function applyPawnSide()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return end
    local cam = getPlayerCamera(pawn)
    if cam ~= nil then
        pcall(function()
            local rot = want("cs_pawn_rot")
            if cam.bUsePawnControlRotation ~= nil and cam.bUsePawnControlRotation ~= rot then cam.bUsePawnControlRotation = rot end
        end)
        pcall(function()
            local fpOn = not want("cs_fp_scale")
            if cam.bEnableFirstPersonScale ~= nil and cam.bEnableFirstPersonScale ~= fpOn then
                if cam.SetEnableFirstPersonScale ~= nil then cam:SetEnableFirstPersonScale(fpOn) else cam.bEnableFirstPersonScale = fpOn end
            end
        end)
    end
    if want("cs_shake") then
        for _, name in ipairs({ "CameraShakeGunShot", "CameraShakeComponent" }) do
            pcall(function()
                local src = pawn[name]
                if alive(src) and src.StopAllCameraShakes ~= nil then src:StopAllCameraShakes(true) end
            end)
        end
    end
end

-- Vignette (2026-10-16, idea from another Hellraiser profile): the camera actor (Pawn.FPCameraActor.ChildActor,
-- BP_PlayerCamera_C) carries PostProcessSettings with a VignetteIntensity that darkens the screen edges - in a headset
-- it reads as a dark ring around the view. Set to 0 on every refresh while ticked; the game value comes back when
-- unticked (kept per camera actor).
local vignette = { actor = nil, orig = nil }
local function applyVignette()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return end
    local actor = nil
    pcall(function() actor = pawn.FPCameraActor.ChildActor end)
    if not alive(actor) then return end
    local pp = actor.PostProcessSettings
    if pp == nil or pp.VignetteIntensity == nil then return end
    if vignette.actor ~= actor then vignette.actor, vignette.orig = actor, nil end
    if want("cs_vignette") then
        if vignette.orig == nil then vignette.orig = pp.VignetteIntensity end
        if pp.VignetteIntensity ~= 0 then pp.VignetteIntensity = 0 end
    elseif vignette.orig ~= nil then
        pp.VignetteIntensity = vignette.orig
        vignette.orig = nil
    end
end

-- HUD blood splash (2026-10-16): the damage effect is a HUD widget, PlayerController.MyHUD.BloodSplashWidget. Made
-- fully transparent (SetRenderOpacity 0) on every refresh while ticked - the widget stays and keeps working, it is just
-- invisible; its own opacity comes back when unticked (kept per widget).
local blood = { widget = nil, orig = nil }
local function applyBloodSplash()
    local pc = uevr.api:get_player_controller(0)
    if pc == nil then return end
    local widget = nil
    pcall(function() widget = pc.MyHUD.BloodSplashWidget end)
    if not alive(widget) then return end
    if blood.widget ~= widget then blood.widget, blood.orig = widget, nil end
    local current = widget:GetRenderOpacity()
    if want("cs_blood_splash") then
        if blood.orig == nil then blood.orig = current end
        if current ~= 0 then widget:SetRenderOpacity(0) end
    elseif blood.orig ~= nil then
        widget:SetRenderOpacity(blood.orig)
        blood.orig = nil
    end
end

local function refresh(force)
    applyPawnSide()
    pcall(applyVignette)
    pcall(applyBloodSplash)
    local cm = getCameraManager()
    if cm == nil then return end
    if cm ~= lastManager then
        lastManager = cm
        force = true
        lastApplied = {}
    end
    local applied = applyModifiers(cm, force)
    for k, v in pairs(applied) do lastApplied[k] = v end
    local parts = {}
    for _, def in ipairs(MODIFIERS) do
        table.insert(parts, def.class:gsub("CameraModifier_", ""):gsub("CameraModifier", "") .. "=" .. (lastApplied[def.id] == true and "off" or (lastApplied[def.id] == false and "on" or "?")))
    end
    configui.setLabel("cs_status", "Status: " .. table.concat(parts, " "))
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local now = os.clock()
    if now < nextRefresh then return end
    nextRefresh = now + 1.0
    local ok, err = pcall(refresh, false)
    if not ok then print("[camera_stabilize] " .. tostring(err)) end
end)

for _, id in ipairs({ "cs_shake", "cs_camera_anim", "cs_fp_scale", "cs_pawn_rot", "cs_vignette", "cs_blood_splash" }) do
    configui.onUpdate(id, function(value) nextRefresh = 0 end)
end

-- Physical melee / two-handing call this right after they inject an attack, so a shake that was queued in the
-- same tick is dropped before the next refresh (the disabled modifier already keeps it off the view).
_G.hrStopCameraShakes = function()
    if not want("cs_shake") then return end
    pcall(function()
        local cm = getCameraManager()
        if cm ~= nil and cm.StopAllCameraShakes ~= nil then cm:StopAllCameraShakes(true) end
    end)
end

-- Fallback hard lock: replaces the view rotation with the control rotation yaw (pitch/roll 0).
local function getControlYaw()
    local yaw = nil
    pcall(function()
        local pc = uevr.api:get_player_controller(0)
        if pc == nil or pc.GetControlRotation == nil then return end
        local r = pc:GetControlRotation()
        if r ~= nil then yaw = r.Yaw end
    end)
    return yaw
end

uevrUtils.registerPreCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if configui.getValue("cs_hard_lock") ~= true or rotation == nil then return end
    local yaw = getControlYaw()
    if yaw == nil then return end
    rotation.Pitch = 0
    rotation.Yaw = yaw
    rotation.Roll = 0
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    lastManager = nil
    lastApplied = {}
    vignette.actor, vignette.orig = nil, nil
    blood.widget, blood.orig = nil, nil
end)

print("[camera_stabilize] loaded")
