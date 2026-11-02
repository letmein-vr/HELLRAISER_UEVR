-- Hellraiser VR bootstrap: requires + initialises the uevrlib modules (structure ported from the Outer Worlds 2
-- profile). Game scripts in this folder:
--   hr_hands.lua             Hands / IK Arms mode + level-load boot of the glove hands
--   weaponhook.lua           equipment -> right controller, body mesh hide, first-person render mode off
--   two_handed.lua           two-handed aiming (fore-grip grab with the left hand)
--   physical_melee.lua       swing-to-attack for melee weapons
--   camera_stabilize.lua     camera shake / camera anims / first-person scale off
--   zz_hellraiser_vr_panel.lua  builds the merged "Hellraiser VR" overlay panel (loads last)
-- Weapon aim (bullets leave the barrel, not the camera) is the native plugin plugins/HellraiserAimFix.dll.
local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require("libs/configui")
local reticule = require("libs/reticule")
local hands = require('libs/hands')
local attachments = require('libs/attachments')
local accessories = require('libs/accessories')
local input = require('libs/input')
local pawnModule = require('libs/pawn')
local animation = require('libs/animation')
local montage = require('libs/montage')
local interaction = require('libs/interaction')
local ui = require('libs/ui')
local remap = require('libs/remap')
local gestures = require('libs/gestures')

-- Release layout (2026-10-09): developer mode OFF - no Input/UI/Pawn/Reticule/Remap/Montage/Interaction dev panels
-- (their saved data/*.json settings still apply). Only the Hellraiser VR panel and the attachments panel remain
-- (weaponhook.lua initialises attachments with the developer flag explicitly). Set to true to tune them again.
uevrUtils.setDeveloperMode(false)

-- VR hands wizard ("Hand Config" panel): off for release - it wrote data/hands_parameters.json, which
-- scripts/hr_hands.lua builds the glove hands from (source mesh: Pawn.Mesh, cut bones hand_l / hand_r).
-- Do NOT use the wizard's "generate script" step if re-enabled (it writes scripts/hands.lua, a second hand builder).
-- hands.enableConfigurationTool() -- off for release (2026-10-19); uncomment to make / edit hand poses

-- Full-arm IK rig (libs/ik), used when the "Hands" section of the Hellraiser VR panel is set to "IK Arms".
-- Always loaded; whether a rig is auto-created follows the mode (hr_hands.lua drives _G.setIKEnabled /
-- _G.ikRebuild; it loads first so the mode getter already exists here). Rig source: data/ik_parameters.json
-- (Pawn.Mesh, mannequin bones). Rig meshes are copies of Pawn.Mesh and inherit its FirstPerson render mode,
-- which would squash them toward the eye - weaponhook.lua's helper switches them to None.
local ik = require('libs/ik')
ik.registerOnMeshCreatedCallback(function(meshList, rig)
    for _, mesh in ipairs(meshList or {}) do
        if mesh ~= nil and _G.hrClearFirstPerson ~= nil then pcall(_G.hrClearFirstPerson, mesh, true) end
        pcall(function() mesh:SetCastShadow(false) end)
    end
    -- a fresh rig starts in the open pose until an input edge; re-assert the current weapon grip/trigger state
    if _G.refreshWeaponPoses ~= nil then pcall(_G.refreshWeaponPoses) end
end)
ik.init(false, LogLevel.Warning) -- false = no IK dev panel (release); true re-opens it for tuning

local function ikWanted()
    return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end
_G.setIKEnabled = function(enabled)
    ik.setAutoCreateArms(enabled == true) -- the 1 s auto-create builds the rig from ik_parameters.json + hands_parameters.json
    if not enabled and ik.exists() then ik.destroyAll() end
end
_G.ikRebuild = function()
    if ik.exists() then ik.destroyAll() end
end
ik.setAutoCreateArms(ikWanted())

ui.init()
-- UI follows the view in normal gameplay (xaero 2026-10-08). ui_parameters.json holds no headLockedUI value, so
-- ui.lua's default (false) applied; menus.lua (viewLocked while a menu is open) and the seated code still override it.
ui.setIsHeadLocked(true)
-- Panel section "UI (gameplay)": the head-locked UI's distance / offsets / size / shape (ui.lua headLockedUIPosition
-- {X = UEVR UI_X_Offset, Y = UI_Y_Offset, Z = UI_Distance}, headLockedUISize = UI_Size, headLockedUIShape). Used while
-- the UI follows the view (gameplay, seated); menus keep their fixed UI. Applied on the game thread (configui callbacks
-- run on the draw thread).
_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 6.5, label = "UI (gameplay)", layout = {
    { widgetType = "slider_float", id = "hrui_distance", label = "UI distance (m)", range = {0.5, 6.0}, initialValue = 2.0, speed = 0.01 },
    { widgetType = "slider_float", id = "hrui_x", label = "UI left/right offset (m)", range = {-2.0, 2.0}, initialValue = 0.0, speed = 0.01 },
    { widgetType = "slider_float", id = "hrui_y", label = "UI down/up offset (m)", range = {-2.0, 2.0}, initialValue = 0.0, speed = 0.01 },
    { widgetType = "slider_float", id = "hrui_size", label = "UI size", range = {0.5, 6.0}, initialValue = 2.0, speed = 0.01 },
    { widgetType = "checkbox", id = "hrui_curved", label = "Curved UI", initialValue = false },
}})
local function applyGameplayUI()
    local function num(id, default)
        local v = configui.getValue(id)
        return type(v) == "number" and v or default
    end
    uevrUtils.setTimeout(1, function()
        pcall(function()
            ui.setHeadLockedUIPosition({ X = num("hrui_x", 0.0), Y = num("hrui_y", 0.0), Z = num("hrui_distance", 2.0) })
            ui.setHeadLockedUISize(num("hrui_size", 2.0))
            ui.setHeadLockedUIShape(configui.getValue("hrui_curved") == true and ui.ShapeEnum.Cylinder or ui.ShapeEnum.Flat)
        end)
    end)
end
for _, id in ipairs({ "hrui_distance", "hrui_x", "hrui_y", "hrui_size", "hrui_curved" }) do
    configui.onCreateOrUpdate(id, applyGameplayUI)
end
-- montage.lua polls pawn:GetCurrentMontage(), i.e. Pawn.Mesh - which on Hellraiser IS the first-person arms mesh
-- (attacks, reloads, interactions all play there), so no extra mesh monitor is needed. Per-montage rules
-- (hands hidden / pawn arms visible during interactions and cinematics) are set in the Montage Config dev panel.
montage.init()
-- Ladders: Pawn.LadderReference is set for the whole climb (GA_ClimbingLadder_C, MCP 2026-10-08). Seed = VR hands /
-- IK arms hidden, the game's arms visible on the rungs ("* Rule: Ladder" in the Montages panel). Input is NOT set
-- here: scripts/ladder.lua ticks input.lua's Disabled override instead (re-seeds the view from the pawn's new facing).
montage.addStateRule("rule_ladder", "* Rule: Ladder", function()
    return uevr.api:get_local_pawn(0).LadderReference ~= nil
end, { handsWhenActive = 2, pawnArmsWhenActive = 3 })
-- Generic runtime montages (short name "AnimMontage_<n>", e.g. AnimMontage_2147401545) are the game's interactive
-- in-world cutscenes. Seeded with exactly the AM_FP_SaveGame_Player_IN settings (hands hidden, input disabled, pawn
-- arms + arm bones visible, UEVR aim Game, weapon hidden). Applies only to montages without settings of their own;
-- seeded once, then edited in the panel as "* Rule: Cutscene (AnimMontage_*)".
montage.addPatternRule("rule_cutscene_animmontage", "* Rule: Cutscene (AnimMontage_*)", { namePrefixes = { "AnimMontage_" } }, {
    handsWhenActive = 2,               handsWhenActivePriority = "0",
    inputWhenActive = 3,               inputWhenActivePriority = "0",
    leftArmWhenActive = 1,             leftArmWhenActivePriority = "0",
    rightArmWhenActive = 1,            rightArmWhenActivePriority = "0",
    pawnBodyWhenActive = 1,            pawnBodyWhenActivePriority = "0",
    pawnArmsWhenActive = 3,            pawnArmsWhenActivePriority = "0",
    pawnArmBonesWhenActive = 3,        pawnArmBonesWhenActivePriority = "0",
    motionSicknessCompensationWhenActive = 1, motionSicknessCompensationWhenActivePriority = "0",
    leftAccessoryWhenActive = "",      leftAccessoryWhenActivePriority = "0",
    rightAccessoryWhenActive = "",     rightAccessoryWhenActivePriority = "0",
    aimMethodWhenActive = 2,           aimMethodWhenActivePriority = "0",
    weaponWhenActive = 2,              weaponWhenActivePriority = "0",
})
-- Tied to a chair / seated scripted interactions (EP_1 cell puzzle, 2026-10-08). The game runs the chair as an
-- interaction (BP_ChairTiedPlayer_C starts the pawn's GA_BaseInteract_C, tag Character.State.BaseInteract) and keeps
-- the pawn in MovementMode 5 (Flying) the whole time (MCP + probe). Lua cannot reach that ability (the ability
-- system's ActivatableAbilities.Items reads nil, find_all_of of GA_BaseInteract_C returns nothing - adoption), so
-- "seated" = Flying outside ladders (ladders have their own rule).
-- True-VR seated mode: input.lua stays ON, so the head drives the game camera exactly as in normal play and the
-- game's own interaction checks (InteractManager, from the pawn's FPCameraActor + on-screen test) follow the gaze.
-- What was wrong seated was the VR view POSITION: input.lua puts it at root + capsule half-height + head offset
-- (standing eye height); seated the game camera is lower / elsewhere. So while seated the view is placed at the
-- game camera (FPCameraActor) through input.setViewPositionOverride. The rule only swaps the VR hands for the game's
-- body / arms (they do not fit the seated pose). input.setBodyYawFrozenCallback keeps the pawn's facing (no body
-- follow from the head, no stick turn). Tunable in the panel as "* Rule: Tied to Chair / Flying".
local MOVE_FLYING = 5
-- Chair montages (e.g. AM_FP_Chiar_Free_PH_Pull_Spike - the game spells it "Chiar") count as seated too, whatever the
-- movement mode does meanwhile. Name from the pawn montage-change callback (no per-tick lookup).
local chairMontagePlaying = false
uevrUtils.registerMontageChangeCallback(function(montage, montageName)
    local name = string.lower(montageName or "")
    chairMontagePlaying = string.find(name, "chiar", 1, true) ~= nil or string.find(name, "chair", 1, true) ~= nil
end)
uevrUtils.registerPreLevelChangeCallback(function(level) chairMontagePlaying = false end)
-- The chair sequence also runs its own anim blueprint on Pawn.Mesh (ABP_ChairFree_C) for as long as the player is tied,
-- and the movement mode does not hold: after the first interaction (nail out of the hand) the game sets the pawn back
-- to Walking (1) while it is still tied (MCP 2026-11-01) - every seated rule then dropped (IK arms back and stretched,
-- body freeze and hand camera off). Collision (off while tied) is not used: video_cutscenes.lua takes it as its
-- scripted-sequence signal. Read once per tick; the class name only when the anim class changes.
local chairAnim = { class = nil, isChair = false, active = false }
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local active = false
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        local inst = pawn ~= nil and pawn.Mesh ~= nil and pawn.Mesh:GetAnimInstance() or nil
        if inst == nil then return end
        local cls = inst:get_class()
        if cls ~= chairAnim.class then
            chairAnim.class = cls
            chairAnim.isChair = string.find(string.lower(cls:get_fname():to_string()), "chair", 1, true) ~= nil
        end
        active = chairAnim.isChair
    end)
    chairAnim.active = active
end)
uevrUtils.registerPreLevelChangeCallback(function(level) chairAnim.class, chairAnim.isChair, chairAnim.active = nil, false, false end)
-- Tied to the chair itself (chair montage / anim). The chair-only handling below (body position freeze, camera pulled
-- back, right-hand pointer + game camera on the hand) keys on this, NOT on isSeated: in-world cutscenes put the pawn
-- in Flying too (EP_0 prologue, MCP 2026-11-02), and there the hand camera moved the view target (FPCameraActor) onto
-- the right controller.
local function isChairSeated()
    return chairMontagePlaying or chairAnim.active
end
local function isSeated()
    if isChairSeated() then return true end
    local pawn = uevr.api:get_local_pawn(0)
    return pawn ~= nil and pawn.MovementMode == MOVE_FLYING and pawn.LadderReference == nil
end
_G.hrIsSeated = isSeated
_G.hrIsChairSeated = isChairSeated
-- (the seated view position override is set further down, with the seated camera)
-- Focus puzzles (lockpicking, 2026-10-09): the game moves the view target to the puzzle's camera task
-- (PlayerController:GetViewTarget() = BP_TASK_FocusEnvPuzzle_C instead of the pawn; MCP, lockpick
-- BP_EnvPuzzleBaseActor_LockpickPuzzle_C with bPuzzleActive) and reads BOTH sticks for the puzzle. With input.lua on, its
-- stick turn spun the player on the right stick (freezing only the body yaw made the view rotate uncontrollably - the
-- game drives the camera here). So while one is up input.lua is OFF (game aim: the view follows the game's puzzle
-- camera, like the flat game), through libs/ui.lua's custom state inputEnabled = false - the same path menus.lua uses.
-- ui.lua has ONE slot per key, shared with menus.lua (which clears it when a menu closes), so it is re-asserted every
-- poll while the puzzle is up and no menu is open, and cleared on leaving only if this code set it.
local focusPuzzle = { active = false, owned = false, nextCheck = 0 }
local FOCUS_PUZZLE_PRIORITY = 90 -- below menus.lua (100)
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local now = os.clock()
    if now < focusPuzzle.nextCheck then return end
    focusPuzzle.nextCheck = now + 0.1
    local active = false
    pcall(function()
        local pc = uevr.api:get_player_controller(0)
        local target = pc ~= nil and pc:GetViewTarget() or nil
        if target ~= nil and target ~= uevr.api:get_local_pawn(0) then
            active = string.find(target:get_class():get_full_name(), "FocusEnvPuzzle", 1, true) ~= nil
        end
    end)
    -- Inspecting a picked-up item (2026-10-09, e.g. BP_ZO_StrangeSkull_C, a BP_ZoomObject_C): the item is held at the
    -- pawn's ZOInspectionPoint and turned with the right stick, interact points pressed with A. The view target stays the
    -- player camera; the signal is Pawn.InspectingObject (set while inspecting - MCP). Same treatment as focus puzzles.
    if not active then
        pcall(function()
            local pawn = uevr.api:get_local_pawn(0)
            active = pawn ~= nil and pawn.InspectingObject ~= nil
        end)
    end
    if active ~= focusPuzzle.active then print("[uevrmenus] focus puzzle / inspection " .. (active and "started" or "ended")) end
    focusPuzzle.active = active
    local inMenu = _G.hrIsInMenu ~= nil and _G.hrIsInMenu()
    if active and not inMenu then
        ui.setCustomState("inputEnabled", false, FOCUS_PUZZLE_PRIORITY)
        focusPuzzle.owned = true
    elseif focusPuzzle.owned and not inMenu then
        ui.setCustomState("inputEnabled", nil)
        focusPuzzle.owned = false
    elseif inMenu then
        focusPuzzle.owned = false -- menus.lua owns the slot now (and clears it when the menu closes)
    end
end)
uevrUtils.registerPreLevelChangeCallback(function(level)
    focusPuzzle.active = false
    if focusPuzzle.owned then pcall(function() ui.setCustomState("inputEnabled", nil) end) end
    focusPuzzle.owned = false
end)
_G.hrIsInFocusPuzzle = function() return focusPuzzle.active end
-- ... and during them the VR hands / IK rig (both obey is_hands_hidden), the game's body + arms and the held weapon are
-- hidden ("* Rule: Puzzle / Inspection" in the Montages panel). Body / arms at priority 100: ik_full_body.lua answers
-- "not hidden" at 100 in IK Arms + Body mode, and an equal-priority true wins (uevr_utils ORs equal priorities).
montage.addStateRule("rule_focus_puzzle", "* Rule: Puzzle / Inspection", function() return focusPuzzle.active end, {
    handsWhenActive = 2,               handsWhenActivePriority = "100",
    pawnBodyWhenActive = 2,            pawnBodyWhenActivePriority = "100",
    pawnArmsWhenActive = 2,            pawnArmsWhenActivePriority = "100",
    weaponWhenActive = 2,              weaponWhenActivePriority = "100",
})

-- seated: the body keeps the yaw the game gave it (input.lua LOCKED rotation mode would turn it with the head) and the
-- stick does not turn it; the head looks around freely on top
input.setBodyYawFrozenCallback(isSeated)
-- ... and stays where the game sat it (2026-11-01): seated the pawn is unattached (MovementMode 5, no attach parent -
-- MCP), so input.lua's roomscale (pawnPositionMode FOLLOWS) pushed the root by every HMD translation, including the
-- few cm the headset travels when the head only turns. Frozen, the HMD offset moves only the view (leaning still works).
-- (The seated anim also bends the body toward the control rotation - see the seated camera below.)
_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 6.65, label = "Seated (chair)", layout = { -- between "Interaction Pointer" (6.6) and "Inspected Items" (6.7)
    { widgetType = "checkbox", id = "seat_freeze_position", label = "Keep the body still while seated (real-world movement moves only the view)", initialValue = true },
    { widgetType = "slider_float", id = "seat_camera_back", label = "Seated camera pulled back (cm, 0 = game's)", range = {0.0, 60.0}, initialValue = 25.0, speed = 0.5 },
    -- read by interaction_pointer.lua (pointer look, range and selection angle come from the Interaction Pointer section)
    { widgetType = "checkbox", id = "seat_right_pointer", label = "Point with the right controller instead of looking (seated)", initialValue = true },
}})
input.setPawnPositionFrozenCallback(function()
    return configui.getValue("seat_freeze_position") ~= false and isChairSeated()
end)
-- Seated view + game camera (2026-11-01). The game camera = Pawn.FPCameraActor, a ChildActorComponent on Pawn.Mesh bone
-- camera_jnt (relative 0); its child actor's CineCamera (Pawn.PlayerCameraComponent) is the camera manager's view.
-- The VR view sits at a seated anchor: camera_jnt pulled back along the pawn's facing by "Seated camera pulled back" -
-- the chair puzzle's interact points (BP_TASK_Interaction_C_0..7, 18 deg focus cones) sit 42-49 cm under the bone,
-- three of them ~10 cm BEHIND it (MCP). The game camera is re-placed every tick (the anim moves the bone), by mode:
--   * gaze (seat_right_pointer off): on the anchor. The game's focus aims from it along the control rotation (= gaze),
--     so gaze and prompts stay matched.
--   * right hand (seat_right_pointer on): on the right-hand pointer ray (_G.hrSeatedPointerPose, interaction_pointer.lua).
--     The game's focus check (InteractManager) aims along FPCameraActor's own ComponentToWorld (pawn +0xC08 - MCP) and its
--     on-screen test projects through the CineCamera, which stops using the control rotation, so both follow the beam.
--     The aim is frozen at the pawn's facing (input.lua aim method UEVR + control rotation = pawn yaw): ABP_ChairFree_C
--     bends the body toward the control rotation (AimingAngle -> rotation-offset blendspaces), which moved camera_jnt -
--     and the view with it - whenever the head, a controller aim or the pointer turned it.
-- Leaving the seat or the mode (or a script reset) puts the game's values back (same live pawn only). FPCameraActor goes
-- back to identity on its bone - the game's own placement (MCP; the other community profile snaps it there every frame
-- too). A value captured on entering could be our own leftover (a reset mid-seat once left it at the hand's offset).
local seatedCamera = { comp = nil, socket = nil, handPlaced = false, aimOwned = false, cineCam = nil, cineSaved = nil }
local function cameraBack()
    local back = configui.getValue("seat_camera_back")
    return type(back) == "number" and back or 25.0
end
local function handCameraActive()
    return configui.getValue("seat_right_pointer") ~= false and _G.hrSeatedPointerPose ~= nil and isChairSeated()
end
_G.hrSeatedHandCamera = handCameraActive -- camera_stabilize.lua leaves the CineCamera's bUsePawnControlRotation alone meanwhile
local function seatedViewAnchor(pawn)
    if seatedCamera.socket == nil then seatedCamera.socket = uevrUtils.fname_from_string("camera_jnt") end
    local p = pawn.Mesh:GetSocketLocation(seatedCamera.socket)
    local f = pawn:GetActorForwardVector()
    local back = cameraBack()
    return p.X - f.X * back, p.Y - f.Y * back, p.Z
end
input.setViewPositionOverride(function()
    if not isSeated() then return nil end
    local pawn = uevr.api:get_local_pawn(0)
    if isChairSeated() then return seatedViewAnchor(pawn) end
    -- other Flying scenes (in-world cutscenes): the view at the game camera, as before the chair work
    local cam = pawn.FPCameraActor
    if cam == nil then return nil end
    local l = cam:K2_GetComponentLocation()
    return l.X, l.Y, l.Z
end)
local function restoreSeatedCamera()
    local s = seatedCamera
    local comp = s.comp
    s.comp, s.handPlaced = nil, false
    if comp == nil then return end
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        if pawn ~= nil and pawn.FPCameraActor == comp then
            comp:K2_SetRelativeLocationAndRotation(uevrUtils.vector(0, 0, 0), uevrUtils.rotator(0, 0, 0), false, reusable_hit_result, false)
        end
    end)
end
local function releaseHandAim()
    local s = seatedCamera
    if s.aimOwned then
        s.aimOwned = false
        pcall(function() input.setOverrideAimMethod(nil) end)
    end
    if s.cineCam ~= nil then
        local cc, saved = s.cineCam, s.cineSaved
        s.cineCam, s.cineSaved = nil, nil
        pcall(function()
            local pawn = uevr.api:get_local_pawn(0)
            if pawn ~= nil and pawn.PlayerCameraComponent == cc then cc.bUsePawnControlRotation = saved end
        end)
    end
end
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local seated = isChairSeated()
    local hand = seated and handCameraActive()
    if not hand then
        releaseHandAim()
        if seatedCamera.handPlaced then restoreSeatedCamera() end -- its rotation is the hand's: back to the bone first
    end
    if not seated or (not hand and cameraBack() <= 0) then
        if seatedCamera.comp ~= nil then restoreSeatedCamera() end
        return
    end
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        local cam = pawn.FPCameraActor
        if cam == nil or pawn.Mesh == nil then return end
        if seatedCamera.comp ~= cam then
            restoreSeatedCamera()
            seatedCamera.comp = cam
        end
        if hand then
            local origin, rot = _G.hrSeatedPointerPose()
            if origin == nil then return end
            seatedCamera.aimOwned = true
            input.setOverrideAimMethod(input.AimMethod.UEVR)
            local pc = uevr.api:get_player_controller(0)
            if pc ~= nil then pc:SetControlRotation(uevrUtils.rotator(0, pawn:K2_GetActorRotation().Yaw, 0)) end
            local cc = pawn.PlayerCameraComponent
            if cc ~= nil and cc.bUsePawnControlRotation == true then
                if seatedCamera.cineCam ~= cc then seatedCamera.cineCam, seatedCamera.cineSaved = cc, true end
                cc.bUsePawnControlRotation = false
            end
            cam:K2_SetWorldLocationAndRotation(origin, rot, false, reusable_hit_result, false)
            seatedCamera.handPlaced = true
        else
            local x, y, z = seatedViewAnchor(pawn)
            cam:K2_SetWorldLocation(uevrUtils.vector(x, y, z), false, reusable_hit_result, false)
        end
    end)
end)
uevrUtils.registerPreLevelChangeCallback(function(level)
    -- the level's pawn goes with it: forget everything without touching it (the aim method is input.lua's own state)
    if seatedCamera.aimOwned then pcall(function() input.setOverrideAimMethod(nil) end) end
    seatedCamera.comp, seatedCamera.handPlaced = nil, false
    seatedCamera.aimOwned, seatedCamera.cineCam, seatedCamera.cineSaved = false, nil, nil
end)
-- a script reset mid-seat drops this state: hand the game camera back first (the new instance starts clean)
uevr.params.sdk.callbacks.on_script_reset(function()
    releaseHandAim()
    restoreSeatedCamera()
end)
-- ... and the game itself turns the pawn toward the control rotation (which input.lua points at the gaze for aiming):
-- CharacterMovement.bUseControllerDesiredRotation = true with an instant RotationRate (MCP, seated). Off while
-- seated, the game's value restored afterwards.
local seatedDesiredRotation = { saved = nil, cmc = nil }
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    pcall(function()
        local seated = isSeated()
        if seated then
            local cmc = uevr.api:get_local_pawn(0).CharacterMovement
            if cmc == nil then return end
            if seatedDesiredRotation.cmc ~= cmc then
                seatedDesiredRotation.cmc = cmc
                seatedDesiredRotation.saved = cmc.bUseControllerDesiredRotation
            end
            if cmc.bUseControllerDesiredRotation == true then cmc.bUseControllerDesiredRotation = false end
        elseif seatedDesiredRotation.cmc ~= nil then
            local cmc = seatedDesiredRotation.cmc
            local saved = seatedDesiredRotation.saved
            seatedDesiredRotation.cmc, seatedDesiredRotation.saved = nil, nil
            if saved ~= nil and cmc.bUseControllerDesiredRotation ~= saved then cmc.bUseControllerDesiredRotation = saved end
        end
    end)
end)
uevrUtils.registerPreLevelChangeCallback(function(level)
    seatedDesiredRotation.cmc, seatedDesiredRotation.saved = nil, nil -- the level's pawn goes with it
end)
-- Seated, the UI (interaction prompts) follows the view: libs/ui.lua custom state viewLocked = false. ui.lua keeps ONE
-- custom slot per key and menus.lua uses the same key (viewLocked = true while a menu is open, cleared on leaving),
-- so it is only written while no menu is open (re-asserted each tick, which also restores it after a menu closes)
-- and cleared on leaving the seat only if this code set it.
local seatedUI = { owned = false }
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    pcall(function()
        local inMenu = _G.hrIsInMenu ~= nil and _G.hrIsInMenu()
        if isSeated() and not inMenu then
            ui.setCustomState("viewLocked", false, 50)
            seatedUI.owned = true
        elseif seatedUI.owned and not inMenu then
            ui.setCustomState("viewLocked", nil)
            seatedUI.owned = false
        elseif inMenu then
            seatedUI.owned = false -- menus.lua owns the slot now (and clears it when the menu closes)
        end
    end)
end)
montage.addStateRule("rule_chair_tied", "* Rule: Tied to Chair / Flying", isSeated, {
    handsWhenActive = 2,               handsWhenActivePriority = "0",
    pawnBodyWhenActive = 3,            pawnBodyWhenActivePriority = "0",
    pawnArmsWhenActive = 3,            pawnArmsWhenActivePriority = "0",
    pawnArmBonesWhenActive = 3,        pawnArmBonesWhenActivePriority = "0",
})
interaction.init()
reticule.init()
-- Only try to build the reticule while the gameplay pawn exists: its widget class (W_WeaponCrosshairs_C) is not loaded
-- at the main menu, and every failed attempt there cost a 100-160 ms class lookup = a hitch every second.
reticule.setAutoCreateGate(function()
    local p = uevr.api:get_local_pawn(0)
    return p ~= nil and p:get_class():get_fname():to_string() == "CH_FirstPersonPlayable_C"
end)
_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 6, label = "Weapon Reticule", layout = {
    { widgetType = "checkbox", id = "ret_enabled", label = "Enable VR weapon reticule (off = game's HUD crosshair)", initialValue = true },
    { widgetType = "slider_float", id = "ret_brightness", label = "Reticule brightness", range = {1.0, 20.0}, initialValue = 1.0, speed = 0.1 },
    -- reticule.lua draws the reticule at most this far along the aim line (it comes nearer when the muzzle trace hits
    -- something closer); the library default was 200 cm
    { widgetType = "slider_float", id = "ret_distance", label = "Reticule max distance (cm)", range = {100.0, 5000.0}, initialValue = 1000.0, speed = 10.0 },
    { widgetType = "checkbox", id = "ret_constant_size", label = "Keep the same apparent size at any distance", initialValue = true },
    { widgetType = "slider_float", id = "ret_size", label = "Reticule size", range = {0.2, 5.0}, initialValue = 1.0, speed = 0.01 },
}})
local RETICULE_SIZE_REFERENCE = 200 -- cm: with constant size on, "size 1" looks the way the reticule did at the old fixed 200 cm
configui.onCreateOrUpdate("ret_enabled", function(value)
    -- configui callbacks run on the draw thread; component destruction must happen on the game thread
    uevrUtils.setTimeout(1, function() reticule.setEnabled(value ~= false) end)
end)
-- While the Genesis cube's telekinesis countdown is the reticule (genesis_cube.lua _G.hrHoldReticuleActive), its own
-- "Genesis Cube" panel values (gc_ret_*) apply instead of the weapon reticule's.
local function applyReticuleSettings()
    -- the library reticule is the weapon's only now; the cube reticule applies its own gc_ret_* values (genesis_cube.lua)
    local prefix = "ret_"
    local function num(id, default)
        local v = configui.getValue(prefix .. id)
        return type(v) == "number" and v or default
    end
    pcall(function()
        -- distance / size: plain module setters, cheap to re-apply (also covers a dev-panel value overriding them)
        reticule.setDistance(num("distance", 1000.0))
        reticule.setScale(num("size", 1.0))
        reticule.setScaleWithDistance(configui.getValue("ret_constant_size") ~= false and RETICULE_SIZE_REFERENCE or nil)
    end)
    pcall(function()
        local c = reticule.getComponent()
        if c == nil or c.SetTintColorAndOpacity == nil then return end
        local b = num("brightness", 1.0)
        local t = c.TintColorAndOpacity
        if t == nil or math.abs(t.R - b) > 0.001 then
            c:SetTintColorAndOpacity(uevrUtils.color_from_rgba(b, b, b, 1.0))
        end
    end)
end
_G.hrApplyReticuleSettings = applyReticuleSettings
uevrUtils.setInterval(250, applyReticuleSettings)
-- Reticule target for the "Custom" target method (set reticuleTargetMethod = 6 in the Reticule dev panel): trace
-- from the held ranged weapon's muzzle along its barrel - the same muzzle + axis HellraiserAimFix fires along.
-- Hellraiser weapon meshes point the barrel along their +Y axis (Colt: mesh right vector == camera forward), so the
-- rotation is built from the right vector. No ranged weapon / no muzzle socket -> nil (reticule hidden).
-- The Genesis cube's aim has its own reticule in genesis_cube.lua (left controller + "Genesis Cube" panel trim).
local muzzleSocketName = nil
-- (2026-10-09) The cube now has its own reticule component (genesis_cube.lua), so this library reticule stays on the
-- ranged weapon even while the cube is in the left hand (dual wield showed only the cube reticule before).
reticule.registerCustomTargetCallback(function()
    local location, rotation = nil, nil
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        local weapon = pawn.CurrentEquipment
        if weapon == nil or (_G.hrWeaponKind ~= nil and _G.hrWeaponKind(weapon) ~= "ranged") then return end
        local mesh = weapon.RootComponent
        if muzzleSocketName == nil then muzzleSocketName = uevrUtils.fname_from_string("MuzzleFlashSocket") end
        if mesh:DoesSocketExist(muzzleSocketName) then
            location = mesh:GetSocketLocation(muzzleSocketName)
            rotation = kismet_math_library:MakeRotFromX(mesh:GetRightVector())
        end
    end)
    return location, rotation
end)
pawnModule.init()
remap.init()
input.init()
accessories.init()

-- Non-gameplay screens: input.lua pins the VR camera to the pawn root every frame, which is only right for the
-- real player character. Any other pawn (menus, cinematics) renders from the game camera instead.
local PLAYER_PAWN_CLASS = "CH_FirstPersonPlayable_C"
local menuPawnCheck = { pawn = nil, isMenu = false }
input.registerIsDisabledCallback(function()
    local p = uevr.api:get_local_pawn(0)
    if p ~= menuPawnCheck.pawn then
        menuPawnCheck.pawn = p
        menuPawnCheck.isMenu = false
        if p ~= nil then
            pcall(function()
                menuPawnCheck.isMenu = p:get_class():get_fname():to_string() ~= PLAYER_PAWN_CLASS
            end)
        end
    end
    if menuPawnCheck.isMenu then return true, 100 end
    return nil
end)
