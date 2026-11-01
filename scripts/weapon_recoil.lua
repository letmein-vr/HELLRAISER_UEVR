-- Weapon kick for Hellraiser, driven by the game's own animation (2026-11-01, port of Borderlands 4's bl4_vr_recoil.lua).
--
-- The game hangs the held gun on the first-person body mesh (Pawn.Mesh socket weapon_jnt_r1Socket, zero offsets -
-- weaponhook.lua) and the shot kick lives in that mesh's animation; the VR gun no longer hangs there. Pawn.Mesh keeps
-- animating while hidden (render-pass flags only, VisibilityBasedAnimTickOption 0 = always tick pose - MCP 2026-11-01), so:
--
--   * every frame the socket is read in body-mesh COMPONENT space (immune to the mesh's own movement / view pitch);
--   * while the fire button is held, plus a short tail for the recovery, the socket's change since the last frame
--     before firing (baseline frozen at the trigger press) is taken in the socket's own frame = the gun's frame;
--   * that kick is applied to the VR gun so it moves together with the hand:
--       Hands mode  - the gun rides UObjectHook on the raw controller and is re-placed for EVERY stereo view (see
--                     two_handed.lua), so the kick is re-applied after each view's post-stereo (gun' = kick * gun); the
--                     right VR hand (a child of the controller) moves with it once per frame:
--                     hand' = G^-1 * kick * G * hand (G = the gun relative to the hand this frame);
--       IK mode     - the gun rides the rig's hand_r with a cached grip (weaponhook.lua), so the right-hand IK target
--                     is moved instead (runtime solver override, the saved values put back at the end):
--                     target' = rel^-1 * kick * rel * target (rel = the gun relative to the target);
--       two-handing - two_handed.lua rebuilds the gun / two-hand frame from its own base every view, so the kick is only
--                     published (_G.hrRecoilKick) and two_handed.lua adds it after its pivot (helpers below).
--
-- Ranged weapons only. Anything bigger than a kick (reload / melee / equip played while the trigger is held) is not
-- recoil: past the max distance / angle the kick is dropped until the trigger is released. HellraiserAimFix.dll fires
-- from the visible barrel, so the kick also climbs the shots during automatic fire.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local hands = require('libs/hands')
local attachments = require('libs/attachments')
local ik = require('libs/ik')

local SOCKET = "weapon_jnt_r1Socket"
local RTS_COMPONENT = 2
local TRIGGER_THRESHOLD = 64 -- of 255

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 5.9, label = "Recoil", layout = {
    { widgetType = "checkbox", id = "hr_recoil_enabled", label = "Weapon kick (from the game's arm animation)", initialValue = true },
    { widgetType = "slider_float", id = "hr_recoil_strength_loc", label = "Kick distance strength", initialValue = 1.0, range = { 0.0, 3.0 } },
    { widgetType = "slider_float", id = "hr_recoil_strength_rot", label = "Kick rotation strength", initialValue = 1.0, range = { 0.0, 3.0 } },
    { widgetType = "checkbox", id = "hr_recoil_two_handed", label = "Weapon kick while two-handing", initialValue = true },
    { widgetType = "slider_float", id = "hr_recoil_tail", label = "Recovery time after release (s)", initialValue = 0.35, range = { 0.05, 1.5 } },
    { widgetType = "slider_float", id = "hr_recoil_max_cm", label = "Ignore motions larger than (cm)", initialValue = 12.0, range = { 2.0, 40.0 } },
    { widgetType = "slider_float", id = "hr_recoil_max_deg", label = "Ignore rotations larger than (deg)", initialValue = 25.0, range = { 2.0, 90.0 } },
    { widgetType = "checkbox", id = "hr_recoil_block_low_ready", label = "Keep the gun raised (no Low Ready stance: clean first-shot kick)", initialValue = true },
    { widgetType = "text", id = "hr_recoil_status", label = "Last burst: -" },
}})

local function value(id, default)
    local v = configui.getValue(id)
    if v == nil then return default end
    return v
end

local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

local function isIKMode()
    return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end

-- fire button = right trigger (read after UEVR mapped the VR controller into the gamepad state)
local triggerHeld = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    triggerHeld = state.Gamepad.bRightTrigger >= TRIGGER_THRESHOLD
end)

local socketFName = nil
local function readSocket(mesh)
    if socketFName == nil then socketFName = uevrUtils.fname_from_string(SOCKET) end
    local t = mesh:GetSocketTransform(socketFName, RTS_COMPONENT)
    local l, r = t.Translation, kismet_math_library:Quat_Rotator(t.Rotation)
    return { loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
end

local function makeT(p)
    return kismet_math_library:MakeTransform(uevrUtils.vector(p.loc.X, p.loc.Y, p.loc.Z), uevrUtils.rotator(p.rot.Pitch, p.rot.Yaw, p.rot.Roll), uevrUtils.vector(1, 1, 1))
end

local function splitT(t)
    local l, r = t.Translation, kismet_math_library:Quat_Rotator(t.Rotation)
    return { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
end

-- the held item is a ranged weapon (cached per equipment object)
local kindCache = { weapon = nil, ranged = false }
local function holdingRanged(pawn)
    local weapon = nil
    pcall(function() weapon = pawn.CurrentEquipment end)
    if weapon ~= kindCache.weapon then
        kindCache.weapon = weapon
        kindCache.ranged = weapon ~= nil and _G.hrWeaponKind ~= nil and _G.hrWeaponKind(weapon) == "ranged"
    end
    return kindCache.ranged
end

-- kick state
local active = false
local suppressedUntilRelease = false
local baseline = nil      -- socket pose (mesh space) the last frame before firing
local lastPose = nil      -- socket pose of the previous frame
local releasedAt = nil
local kick = nil          -- this frame's kick (gun frame) while active
local mode = nil          -- "hands" / "ik" / "two" - how this frame's kick is applied
local handRest = nil      -- Hands mode: { hand, loc, rot, scale } of the right hand before the kick
local ikRest = nil        -- IK mode: { solverId, offset, rotation, rel } (the saved solver values)
local peakCm, peakDeg = 0, 0
-- Low Ready handling (see below the tick): raisedAt = when the gun was last raised out of Low Ready
local lowReady = { pawn = nil, owned = false, nextCheck = 0, nextRemove = 0, raisedAt = -1 }
local RAISE_SETTLE_S = 0.25 -- the raise blend took ~0.1 s (trace); no kick starts before it is done

local function restoreHand()
    if handRest == nil then return end
    if alive(handRest.hand) then
        pcall(uevrUtils.set_component_relative_transform, handRest.hand, handRest.loc, handRest.rot, handRest.scale)
    end
    handRest = nil
end

local function restoreIK()
    if ikRest == nil then return end
    local r = ikRest
    ikRest = nil
    pcall(function()
        ik.setSolverRuntimeParameter(r.solverId, "end_bone_offset", r.offset)
        ik.setSolverRuntimeParameter(r.solverId, "end_bone_rotation", r.rotation)
    end)
end

-- Two-handing (two_handed.lua) rebuilds the gun / two-hand frame from its own base every view, so a kick applied here
-- would be overwritten. While two-handing the kick is only published (_G.hrRecoilKick, gun frame) and two_handed.lua
-- adds it after its pivot with these helpers.
_G.hrRecoilKick = nil
_G.hrRecoilRestoreHand = function() restoreHand() end -- two-handing captures the hand's rest: never a kicked one

-- world pose (loc table, rotator) of a gun-frame thing -> kicked: kick * T
_G.hrKickWorld = function(loc, rot)
    local k = _G.hrRecoilKick
    if k == nil then return loc, rot end
    local t = kismet_math_library:ComposeTransforms(makeT(k), kismet_math_library:MakeTransform(uevrUtils.vector(loc.X, loc.Y, loc.Z), rot, uevrUtils.vector(1, 1, 1)))
    local l = t.Translation
    return { X = l.X, Y = l.Y, Z = l.Z }, kismet_math_library:Quat_Rotator(t.Rotation)
end

local function kickComponentWorld(component, k)
    local t = kismet_math_library:ComposeTransforms(makeT(k), kismet_math_library:MakeTransform(component:K2_GetComponentLocation(), component:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1)))
    local l, r = splitT(t)
    component:K2_SetWorldLocationAndRotation(uevrUtils.vector(l.X, l.Y, l.Z), uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), false, reusable_hit_result, false)
end

-- a component placed in world space with the gun's frame (the two-handed gun after its pivot): kick it in place
_G.hrKickComponentWorld = function(component)
    if _G.hrRecoilKick == nil or not alive(component) then return end
    kickComponentWorld(component, _G.hrRecoilKick)
end

local function endKick(reason)
    _G.hrRecoilKick = nil
    kick, mode = nil, nil
    if not active then return end
    active = false
    baseline, releasedAt = nil, nil
    restoreHand()
    restoreIK()
    configui.setLabel("hr_recoil_status", string.format("Last burst: peak %.1f cm, %.1f deg%s", peakCm, peakDeg, reason and (" (" .. reason .. ")") or ""))
end

-- Hands mode, once per frame: move the right VR hand (a child of the controller) so that it keeps its grip on the
-- kicked gun. G (gun relative to the hand) is taken from the hand's REST pose = rest relative x its parent now - not
-- read off the hand: set_component_relative_transform writes the fields only, so the hand's world pose still holds
-- last frame's kick until the parent next moves.
local function applyToHand(gun, kickT)
    local hand = hands.getHandComponent(Handed.Right)
    if not alive(hand) then return end
    if handRest == nil or handRest.hand ~= hand then
        restoreHand()
        local l, r, s = hand.RelativeLocation, hand.RelativeRotation, hand.RelativeScale3D
        handRest = { hand = hand, loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, scale = { X = s.X, Y = s.Y, Z = s.Z } }
    end
    local parent = hand.AttachParent
    if parent == nil then return end
    local parentW = parent:GetSocketTransform(hand.AttachSocketName, 0) -- RTS_World; no socket = the component itself
    local handW = kismet_math_library:ComposeTransforms(makeT(handRest), parentW)
    local gunW = kismet_math_library:MakeTransform(gun:K2_GetComponentLocation(), gun:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1))
    local G = kismet_math_library:MakeRelativeTransform(gunW, handW)
    local t = kismet_math_library:ComposeTransforms(kismet_math_library:ComposeTransforms(
        kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(G), kickT), G), makeT(handRest))
    local l, r = splitT(t)
    uevrUtils.set_component_relative_transform(hand, l, r, handRest.scale)
end

-- IK mode, once per frame: the right-hand target (controller space) moved so the gun on hand_r gets the kick
local function applyToIK(gun, kickT)
    if ikRest == nil then
        local info = _G.hrIKKickInfo ~= nil and _G.hrIKKickInfo(gun) or nil
        if info == nil then return end -- gun not handed to the IK hand yet
        ikRest = info
    end
    local o, ro = ikRest.offset, ikRest.rotation
    local targetT = kismet_math_library:MakeTransform(uevrUtils.vector(o[1], o[2], o[3]), uevrUtils.rotator(ro[1], ro[2], ro[3]), uevrUtils.vector(1, 1, 1))
    local relT = makeT(ikRest.rel)
    local t = kismet_math_library:ComposeTransforms(kismet_math_library:ComposeTransforms(
        kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(relT), kickT), relT), targetT)
    local l, r = splitT(t)
    ik.setSolverRuntimeParameter(ikRest.solverId, "end_bone_offset", { l.X, l.Y, l.Z })
    ik.setSolverRuntimeParameter(ikRest.solverId, "end_bone_rotation", { r.Pitch, r.Yaw, r.Roll })
end

-- once per frame (first post-stereo view): measure the kick and apply the per-frame parts
local function tick()
    local twoHanding = _G.isTwoHandingActive == true
    if value("hr_recoil_enabled", true) == false or _G.hrCutsceneActive == true or (twoHanding and value("hr_recoil_two_handed", true) == false) then
        endKick() lastPose = nil return
    end
    local pawn = uevr.api:get_local_pawn(0)
    local mesh = nil
    pcall(function() mesh = pawn.Mesh end)
    local gun = nil
    pcall(function() gun = attachments.getCurrentGrippedAttachment(Handed.Right) end)
    if pawn == nil or not alive(mesh) or not alive(gun) or not holdingRanged(pawn) then endKick() lastPose = nil return end

    local ok, pose = pcall(readSocket, mesh)
    if not ok or pose == nil then endKick() lastPose = nil return end

    if not triggerHeld then suppressedUntilRelease = false end
    if not active then
        local raising = os.clock() - lowReady.raisedAt < RAISE_SETTLE_S
        if triggerHeld and not suppressedUntilRelease and lastPose ~= nil and not raising then
            active, baseline, releasedAt = true, lastPose, nil
            peakCm, peakDeg = 0, 0
        else
            lastPose = pose
            return
        end
    end
    lastPose = pose

    local now = os.clock()
    if triggerHeld then releasedAt = nil elseif releasedAt == nil then releasedAt = now end
    local weight = 1.0
    if releasedAt ~= nil then
        local f = (now - releasedAt) / math.max(0.05, value("hr_recoil_tail", 0.35))
        if f >= 1.0 then endKick() return end
        if f > 0.7 then weight = (1.0 - f) / 0.3 end
    end

    -- the socket's change since the trigger press, in the socket's (= gun's) own frame
    local d = kismet_math_library:MakeRelativeTransform(makeT(pose), makeT(baseline))
    local t, r = d.Translation, kismet_math_library:Quat_Rotator(d.Rotation)
    local cm = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
    local deg = math.max(math.abs(r.Pitch), math.abs(r.Yaw), math.abs(r.Roll))
    if cm > value("hr_recoil_max_cm", 12.0) or deg > value("hr_recoil_max_deg", 25.0) then
        suppressedUntilRelease = true
        endKick("larger motion ignored")
        return
    end
    if cm > peakCm then peakCm = cm end
    if deg > peakDeg then peakDeg = deg end

    local sl, sr = value("hr_recoil_strength_loc", 1.0) * weight, value("hr_recoil_strength_rot", 1.0) * weight
    kick = { loc = { X = t.X * sl, Y = t.Y * sl, Z = t.Z * sl }, rot = { Pitch = r.Pitch * sr, Yaw = r.Yaw * sr, Roll = r.Roll * sr } }

    if twoHanding then
        -- two_handed.lua adds it after its pivot (see _G.hrRecoilKick above)
        restoreHand()
        restoreIK()
        mode = "two"
        _G.hrRecoilKick = kick
    elseif isIKMode() then
        _G.hrRecoilKick = nil
        restoreHand()
        mode = "ik"
        applyToIK(gun, makeT(kick))
    else
        _G.hrRecoilKick = nil
        restoreIK()
        mode = "hands"
        applyToHand(gun, makeT(kick))
        kickComponentWorld(gun, kick)
    end
end

-- Low Ready (trace 2026-11-01): the game lowers the gun into its "Low Ready" stance after a few seconds without firing
-- and after every reload (Pawn GetPlayerAnimOverlayAction() = 9, anim PlayerAnimOverlayActionBools.bLowReady), and the
-- next shot first RAISES it - the socket swung ~30 deg yaw / ~33 deg roll and ~6 cm in 90 ms, read as a sideways kick
-- (then cut off by the 25 deg limit). Shots from the raised pose kick cleanly (~1.3 cm, up to 11 deg muzzle flip). The
-- arms are hidden in VR (only the kick reads them), so while a ranged weapon is held with the kick on:
--   * Pawn.bBlockLowReady (the game's own switch) is held true - it stops the idle lowering but NOT the one after a
--     reload (MCP: still 9 with the block set), and is set back only if this script set it (same live pawn);
--   * whenever the stance is Low Ready anyway, the game's own PlayerCharacter::RemoveLowReadyState(false) raises it on
--     the next frame (MCP: 9 -> 0), at most every 0.5 s; a kick does not start within RAISE_SETTLE_S of that raise.
local LOW_READY = 9 -- EPlayerAnimOverlayAction
local function isLowReady(pawn)
    local action = nil
    pcall(function() action = tonumber(pawn:GetPlayerAnimOverlayAction()) end)
    if action ~= nil then return action == LOW_READY end
    local lowered = false
    pcall(function() lowered = pawn.Mesh:GetAnimInstance().PlayerAnimOverlayActionBools.bLowReady == true end)
    return lowered
end
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local now = os.clock()
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        if lowReady.owned and lowReady.pawn ~= pawn then lowReady.owned, lowReady.pawn = false, nil end -- not ours any more
        if pawn == nil then return end
        local want = value("hr_recoil_enabled", true) ~= false and value("hr_recoil_block_low_ready", true) ~= false
            and _G.hrCutsceneActive ~= true and holdingRanged(pawn)
        if want then
            if now >= lowReady.nextCheck then
                lowReady.nextCheck = now + 0.25
                if pawn.bBlockLowReady == false then
                    pawn.bBlockLowReady = true
                    lowReady.owned, lowReady.pawn = true, pawn
                end
            end
            if now >= lowReady.nextRemove and isLowReady(pawn) then
                pawn:RemoveLowReadyState(false)
                lowReady.raisedAt, lowReady.nextRemove = now, now + 0.5
            end
        elseif lowReady.owned then
            pawn.bBlockLowReady = false
            lowReady.owned, lowReady.pawn = false, nil
        end
    end)
end)

-- First post-stereo view of a frame: after the world tick (this frame's body-mesh pose) and after UObjectHook placed
-- the gun for that view. Hands mode: every later view re-applies the gun kick (UObjectHook re-placed the gun).
local ranThisFrame = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisFrame = false end)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if ranThisFrame then
        if mode == "hands" and kick ~= nil then
            pcall(function()
                local gun = attachments.getCurrentGrippedAttachment(Handed.Right)
                if alive(gun) then kickComponentWorld(gun, kick) end
            end)
        end
        return
    end
    ranThisFrame = true
    local ok, err = pcall(tick)
    if not ok then
        print("[weapon_recoil] tick: " .. tostring(err))
        pcall(endKick, "error")
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    -- the hand / rig go with the level: forget them without touching them
    active, baseline, lastPose, releasedAt, handRest, ikRest, kick, mode = false, nil, nil, nil, nil, nil, nil, nil
    kindCache.weapon, kindCache.ranged = nil, false
    lowReady.owned, lowReady.pawn = false, nil
    _G.hrRecoilKick = nil
end)

uevr.params.sdk.callbacks.on_script_reset(function()
    pcall(restoreHand)
    pcall(restoreIK)
    if lowReady.owned then
        pcall(function()
            local pawn = uevr.api:get_local_pawn(0)
            if pawn ~= nil and pawn == lowReady.pawn then pawn.bBlockLowReady = false end
        end)
    end
end)

print("[weapon_recoil] loaded")
