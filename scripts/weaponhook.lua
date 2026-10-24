-- Weapon attachment + arms hiding for Hellraiser (structure ported from the Outer Worlds 2 profile).
--
-- Hellraiser facts (MCP, 2026-10-07, UE 5.6, game module /Script/Project):
--   * Player: CH_FirstPersonPlayable_C -> PlayerCharacter -> CoreCharacter. Pawn.Mesh (CharacterMesh0,
--     SK_AidanFP2) is the single first-person body mesh (arms + legs + camera_jnt).
--   * Held item: Pawn.CurrentEquipment (CoreEquipable actor, e.g. BP_Colt_1911_C -> BP_Ranged_Weapon_C ->
--     CoreRangedWeapon -> CoreWeapon -> CoreEquipable). Its RootComponent "FirstPersonEqupable" (sic) is a
--     SkeletalMeshComponent attached to Pawn.Mesh socket weapon_jnt_r1Socket; static-mesh items use the
--     "EquipableStatic" component instead. Melee weapons are CoreMeleeWeapon; the quick-melee knife is a
--     separate StaticMeshComponent on the pawn (Pawn.SM_Knife, socket on Pawn.Mesh), not equipment.
--   * The Colt's barrel runs along the mesh +Y axis (mesh right vector == camera forward), muzzle socket
--     MuzzleFlashSocket on Barrel_End_Jnt - hence the default attach rotation (0,-90,0).
--   * UE 5.6 first-person rendering: Pawn.Mesh and the weapon meshes have FirstPersonPrimitiveType = 1
--     (FirstPerson) and the player camera has bEnableFirstPersonScale = true, FirstPersonScale = 0.2. A
--     FirstPerson primitive is squashed toward the eye at render time, so a weapon left in that mode on the
--     VR controller renders at 1/5 of its distance from the eye. Everything we put on the hands (weapon tree,
--     glove copies, IK rig meshes) is switched to type 0 (None) here; camera_stabilize.lua additionally
--     turns the camera's first-person scale off (checkbox).

local api = uevr.api
local uevrUtils = require('libs/uevr_utils')
local attachments = require('libs/attachments')
local hands = require('libs/hands')

local FP_NONE = 0 -- EFirstPersonPrimitiveType::None

local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

local function forEachInTree(component, fn)
    if component == nil then return end
    pcall(fn, component)
    pcall(function()
        local children = component.AttachChildren
        if children ~= nil then
            for i = 1, #children do forEachInTree(children[i], fn) end
        end
    end)
end

-- Take a component (and optionally its attached children) out of the first-person render mode.
-- FirstPersonPrimitiveType is an EnumProperty, which UEVR Lua does not read (nil) - a "set only when it differs"
-- check never fired (MCP 2026-10-07: the held Colt still read 1). So the setter is called unconditionally,
-- at most once per component per FP_REAPPLY_S (the game re-flags its meshes on equip / visual changes).
local FP_REAPPLY_S = 1.0
local fpAppliedAt = {} -- component address -> os.clock() of the last SetFirstPersonPrimitiveType
local function clearFirstPerson(component, includeChildren)
    local now = os.clock()
    local function apply(c)
        if c.SetFirstPersonPrimitiveType == nil then return end
        local key = c:get_address()
        local last = fpAppliedAt[key]
        if last ~= nil and now - last < FP_REAPPLY_S then return end
        fpAppliedAt[key] = now
        c:SetFirstPersonPrimitiveType(FP_NONE)
    end
    if includeChildren then forEachInTree(component, apply) else pcall(apply, component) end
end
_G.hrClearFirstPerson = clearFirstPerson

-- ---------------------------------------------------------------------------------------------
-- Arms (Pawn.Mesh) hiding
-- ---------------------------------------------------------------------------------------------
-- The real body mesh is hidden while VR hands / the IK rig replace it. Hidden through the render-pass flags,
-- never bVisible / bHiddenInGame: an invisible skeletal mesh can stop ticking its pose (camera_jnt, sockets
-- the game reads) and on OW2 the game's melee damage window silently required the arms to pass IsVisible().
-- The weapon and knife are children; the render-pass flags do not propagate to them.
-- A montage rule (Montage Config: "Pawn Arms/Body Visibility" = Visible) can ask for the real mesh during that
-- montage (interactions, cinematics).
local function montageWantsArmsVisible()
    local arms = uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_pawn_arms_hidden")
    local body = uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_pawn_body_hidden")
    return arms == false or body == false
end

local function montageWantsWeaponHidden()
    return uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_weapon_hidden") == true
end

-- Weapon hiding for montages ("Weapon Visibility" = Hide): render passes + shadow only; originals restored.
local weaponHiddenOriginals = {}   -- address -> { main, depth, shadow }
local weaponHidden = false
local function hideWeaponTree(mesh)
    forEachInTree(mesh, function(c)
        if c.SetRenderInMainPass == nil then return end
        local key = c:get_address()
        if weaponHiddenOriginals[key] == nil then
            weaponHiddenOriginals[key] = { main = c.bRenderInMainPass, depth = c.bRenderInDepthPass, shadow = c.CastShadow }
        end
        if c.bRenderInMainPass == true then c:SetRenderInMainPass(false) end
        if c.bRenderInDepthPass == true then c:SetRenderInDepthPass(false) end
        if c.CastShadow == true and c.SetCastShadow ~= nil then c:SetCastShadow(false) end
    end)
end
local function restoreWeaponTree(mesh)
    forEachInTree(mesh, function(c)
        if c.SetRenderInMainPass == nil then return end
        local key = c:get_address()
        local o = weaponHiddenOriginals[key]
        if o == nil then return end
        if o.main == true and c.bRenderInMainPass == false then c:SetRenderInMainPass(true) end
        if o.depth == true and c.bRenderInDepthPass == false then c:SetRenderInDepthPass(true) end
        if o.shadow == true and c.SetCastShadow ~= nil then c:SetCastShadow(true) end
        weaponHiddenOriginals[key] = nil
    end)
end

hands.onCreatedCallback(function(hand, component, componentName)
    clearFirstPerson(component, true)
end)

-- ---------------------------------------------------------------------------------------------
-- Weapon tracking + attach
-- ---------------------------------------------------------------------------------------------
local rangedClass, meleeClass = nil, nil
local function weaponKind(weapon)
    if rangedClass == nil then rangedClass = uevrUtils.get_class("Class /Script/Project.CoreRangedWeapon") end
    if meleeClass == nil then meleeClass = uevrUtils.get_class("Class /Script/Project.CoreMeleeWeapon") end
    local kind = "item"
    pcall(function()
        if meleeClass ~= nil and weapon:is_a(meleeClass) then kind = "melee"
        elseif rangedClass ~= nil and weapon:is_a(rangedClass) then kind = "ranged" end
    end)
    return kind
end
_G.hrWeaponKind = weaponKind

-- The component that carries the visible item: the skeletal root when it has a mesh, else the static one.
-- Melee weapons (CoreMeleeWeapon, e.g. BP_Sawblade_C) have an EMPTY skeletal root and the visible mesh in a
-- static child: property FirstPersonEqupableStatic (component name "EquipableStatic", SM_Saw for the sawblade).
-- Ranged weapons have the mesh on the skeletal root (Colt: SK_Colt_1911).
local STATIC_MESH_PROPS = { "FirstPersonEqupableStatic", "EquipableStatic" }
local function getEquipmentMesh(weapon)
    local mesh = nil
    pcall(function()
        local root = weapon.RootComponent
        if root ~= nil and (root.SkeletalMesh ~= nil or root.SkinnedAsset ~= nil) then mesh = root return end
    end)
    if mesh ~= nil then return mesh end
    for _, prop in ipairs(STATIC_MESH_PROPS) do
        pcall(function()
            local st = weapon[prop]
            if st ~= nil and st.StaticMesh ~= nil then mesh = st end
        end)
        if mesh ~= nil then return mesh end
    end
    return nil
end
_G.hrGetEquipmentMesh = getEquipmentMesh

local current_weapon = nil       -- equipment actor currently handled
local attached_weapon_mesh = nil -- the component on the VR hand (kept while handed back for a cutscene: hide rules)
local weapon_origin = nil        -- { mesh, parent, socket, loc, rot }: where the game had it before it went on the hand
local next_attach_retry = 0
local next_attach_check = 0      -- watchdog: the game re-attaching the held item to its body socket (see the pre-tick)
local ATTACH_RETRY_S = 0.05
local ikTransferNotBefore = 0    -- IK modes: hand-over to the IK hand waits for UEVR to place a freshly attached gun
local last_pawn = nil
local armsShown = nil

-- In-world interactive cutscenes play generic runtime montages (short name "AnimMontage_<n>"; montage rule
-- "* Rule: Cutscene (AnimMontage_*)" in uevrmenus.lua shows the game's arms for them). While one plays, held items go
-- back to their original game parents so they follow the cutscene animation: the weapon here, the Genesis cube in
-- genesis_cube.lua (reads _G.hrCutsceneActive). They return to the hands when the montage ends.
local CUTSCENE_MONTAGE_PREFIX = "AnimMontage_"
_G.hrCutsceneActive = false
uevrUtils.registerMontageChangeCallback(function(montage, montageName)
    local active = montageName ~= nil and string.sub(montageName, 1, #CUTSCENE_MONTAGE_PREFIX) == CUTSCENE_MONTAGE_PREFIX
    if active ~= _G.hrCutsceneActive then
        _G.hrCutsceneActive = active
        print("[weaponhook] cutscene montage " .. (active and ("started: " .. montageName) or "ended"))
    end
end)
local cutsceneReleased = false   -- the weapon is currently handed back to the game for a cutscene

uevrUtils.registerPreLevelChangeCallback(function(level)
    current_weapon = nil
    attached_weapon_mesh = nil
    weapon_origin = nil
    cutsceneReleased = false
    _G.hrCutsceneActive = false
    weaponHidden = false
    weaponHiddenOriginals = {}
    fpAppliedAt = {} -- addresses get reused after a level change
    last_pawn = nil
    armsShown = nil
end)

local function getPlayerPawn()
    local pawn = api:get_local_pawn(0)
    if pawn == nil then return nil end
    local ok, isPlayer = pcall(function() return pawn.CurrentEquipment ~= nil or pawn.SM_Knife ~= nil end)
    if not (ok and isPlayer) then return nil end
    return pawn
end

local releaseWeaponForCutscene -- defined after the IK section (needs its state)

-- UEVR_UObjectHook.get_motion_controller_state THROWS ("caught (...) exception") on the current backend build, for a gun
-- that is attached (probe 2026-10-09: exists() true). Every attach then looked failed: the gun was re-attached every 50 ms
-- forever and never handed to the IK hand. Returns: the state, or nil when not attached, or `fallback` when the query
-- throws. Right after our own attach, get_or_add returns the existing state (nothing is added), so it is the fallback there.
local function getHookState(mesh, fallback)
    local ok, st = pcall(function() return UEVR_UObjectHook.get_motion_controller_state(mesh) end)
    if ok then return st end
    if fallback == "get_or_add" then
        local ok2, st2 = pcall(function() return UEVR_UObjectHook.get_or_add_motion_controller_state(mesh) end)
        return ok2 and st2 or nil
    end
    return fallback
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta_time)
    local pawn = getPlayerPawn()
    if pawn == nil then return end
    if pawn ~= last_pawn then
        last_pawn = pawn
        current_weapon = nil
        armsShown = nil
    end

    if _G.hrCutsceneActive then
        if not cutsceneReleased then
            cutsceneReleased = true
            pcall(releaseWeaponForCutscene)
        end
        return
    elseif cutsceneReleased then
        cutsceneReleased = false
        current_weapon = nil -- re-attach to the hand below
        next_attach_retry = 0
    end

    local weapon = nil
    pcall(function() weapon = pawn.CurrentEquipment end)
    if weapon == nil then
        if current_weapon ~= nil then
            current_weapon = nil
            print("[weaponhook] no equipment")
        end
        if attached_weapon_mesh ~= nil then
            pcall(releaseWeaponForCutscene) -- the held weapon goes back to the game (see the mesh-less case below)
            attached_weapon_mesh = nil
        end
        return
    end
    if weapon == current_weapon then
        -- Watchdog (2026-10-09): after some montages the game re-attaches the equipped item to its own body socket and
        -- the gun stayed off the hand until a weapon switch. In Hands mode (and in IK modes before the hand-over) the gun
        -- rides UObjectHook with NO game parent, so any parent means the game took it back -> attach again. IK modes
        -- with the gun on the rig are checked in ikHandTick (the parent there must stay the rig's hand_r).
        local mesh = attached_weapon_mesh
        if mesh ~= nil and os.clock() >= next_attach_check and not (_G.getHandsMode ~= nil and _G.getHandsMode() == 2) then
            next_attach_check = os.clock() + 0.25
            local parent = nil
            pcall(function() parent = mesh.AttachParent end)
            if alive(mesh) and (parent ~= nil or getHookState(mesh, true) == nil) then
                print("[weaponhook] weapon left the hand (parent " .. tostring(parent and parent:get_full_name()) .. "); re-attaching")
                current_weapon = nil
                next_attach_retry = 0
            end
        end
        return
    end
    if os.clock() < next_attach_retry then return end

    local mesh = getEquipmentMesh(weapon)
    if mesh == nil then
        -- The new item has no mesh: unarmed (BP_Unarmed_C - e.g. sections that take the weapon away, with weapon
        -- switching blocked), the Genesis cube, or a weapon whose mesh is not assigned yet. Either way the previously
        -- held weapon must leave the hand: the game hides it, but it stayed parented to the controller / IK hand and
        -- gripped in the attachments library (2026-10-09, machete stuck while unarmed).
        if attached_weapon_mesh ~= nil then
            print("[weaponhook] equipment without a mesh (" .. weapon:get_fname():to_string() .. "): releasing the held weapon")
            pcall(releaseWeaponForCutscene) -- back onto its recorded game parent, grip released
            attached_weapon_mesh = nil
        end
        local isUnarmed = false
        pcall(function() isUnarmed = string.find(weapon:get_class():get_fname():to_string(), "Unarmed", 1, true) ~= nil end)
        if isUnarmed then
            current_weapon = weapon -- nothing to attach; stop polling until the equipment changes
            return
        end
        -- mesh asset not assigned yet (first frames after equip / level load): the attachment ID would be
        -- derived from the component name (no saved offsets) - wait for it
        next_attach_retry = os.clock() + ATTACH_RETRY_S
        return
    end

    local kind = weaponKind(weapon)
    print("[weaponhook] equipment: " .. weapon:get_full_name() .. " (" .. kind .. ") mesh " .. mesh:get_full_name())

    local options = {
        detachFromOriginOnGrip = true,
        maintainWorldPositionOnDetachFromOrigin = false,
        detachFromParentOnRelease = true,
        maintainWorldPositionOnDetachFromParent = false,
        reattachToOriginOnRelease = false,
        -- permanent UObjectHook state: the hand transform stays applied on the game thread, so the game (and
        -- HellraiserAimFix) see the gun where it is drawn, not back on the body socket after each stereo pass
        restoreTransformToOriginOnReattach = true,
        allowChildVisibilityHandling = true,
        allowChildHiddenInGameHandling = true,
        allowRenderInMainPassHandling = true,
        melee = (kind == "melee"),
    }
    -- remember the game's parenting (guns: the root on Pawn.Mesh weapon_jnt_r1Socket; melee: the static child on the
    -- equipment root) for cutscenes; only while the item is still on it (not when re-attaching a held item)
    pcall(function()
        local parent = mesh.AttachParent
        if parent ~= nil and (parent == pawn.Mesh or parent == weapon.RootComponent) then
            local rl, rr = mesh.RelativeLocation, mesh.RelativeRotation
            weapon_origin = { mesh = mesh, parent = parent, socket = mesh.AttachSocketName,
                loc = { X = rl.X, Y = rl.Y, Z = rl.Z }, rot = { Pitch = rr.Pitch, Yaw = rr.Yaw, Roll = rr.Roll } }
        end
    end)
    attachments.attachToRawController(mesh, Handed.Right, options)
    if getHookState(mesh, "get_or_add") == nil then
        next_attach_retry = os.clock() + ATTACH_RETRY_S
        print("[weaponhook] attach did not take; retrying")
        return
    end
    -- Bottles (2026-10-10): the game has many bottle meshes (BP_ThrowableBottle_C + SM_*Bottle*). One whose entry is
    -- still untuned gets xaero's vodka bottle offsets and the "bottle" grip; tuned entries stay as they are.
    pcall(function()
        local id = attachments.getAttachmentIDFromAttachment(mesh)
        local asset = mesh.StaticMesh or mesh.SkeletalMesh
        if id == nil or asset == nil then return end
        -- Rocks (2026-10-12): same for meshes with "rock" in the name, with the SM_ThrowableRock values.
        local name = string.lower(asset:get_fname():to_string())
        local location, rotation = nil, nil
        if string.find(name, "bottle", 1, true) ~= nil then
            location, rotation = {-2.3, -1.4, 0.6}, {9.1, 0.2, -4.8}
        elseif string.find(name, "rock", 1, true) ~= nil then
            location, rotation = {-0.8, 0.2, 1.7}, {12.6, 0.1, 1.7}
        end
        if location == nil then return end
        if attachments.seedAttachmentDefaults(id, location, rotation, "bottle") then
            print("[weaponhook] throwable defaults applied to " .. id)
        end
    end)
    current_weapon = weapon
    attached_weapon_mesh = mesh
    ikTransferNotBefore = os.clock() + 0.3
    clearFirstPerson(mesh, true)
end)

-- Release layout keeps the attachments panel (per-weapon offsets / grip animation / melee / two-handed flags).
-- Default rotation (0,-90,0): Hellraiser weapon meshes point their barrel along +Y.
attachments.init(true, nil, {0,0,0}, {0,-90,0})

-- Weapon scopes (2026-10-19). A weapon whose attachment entry is ticked "Is Scoped" (Attachments panel) gets the
-- libs/scope.lua picture-in-picture scope (lens placement / zoom / HMD distance in that entry's Scope Settings, saved
-- in data/scope_parameters.json). Scopes are weapon UPGRADES here: the revolver's scope is a separate
-- StaticMeshComponent (SM_RevolverScope, MCP) attached to the gun's root, present only when the upgrade is fitted. So
-- the PiP scope is only created when the held weapon mesh has a visible child static mesh with "Scope" in its name.
attachments.registerOnScopeUpdateCallback(function(attachment)
    local hasScope = false
    pcall(function()
        for _, child in ipairs(attachment.AttachChildren or {}) do
            local mesh = child.StaticMesh
            if mesh ~= nil and string.find(mesh:get_fname():to_string(), "Scope", 1, true) ~= nil
                and child.bVisible ~= false then
                hasScope = true
                break
            end
        end
    end)
    return hasScope
end)

-- ---------------------------------------------------------------------------------------------
-- IK modes: the held weapon rides on the IK hand, not on the controller (2026-10-08)
-- ---------------------------------------------------------------------------------------------
-- With the weapon on the controller (UObjectHook) and the IK hand only solved toward the controller, the two came
-- apart: (a) beyond arm reach (allow_stretch off) the hand stops while the gun keeps following the controller, and
-- (b) the rig solves in the pre-engine tick from the previous frame's controller pose while UEVR places the gun with
-- the current one, so the hand trails the gun whenever it moves or turns. Atomic Heart's profile solves this by
-- attaching weapons to the IK mesh's hand_r socket (attachments.registerOnGripUpdateCallback); here the same parenting
-- is done WITHOUT new per-weapon offsets: the attachments library first places the gun at its controller-tuned grip
-- (as in Hands mode), then the gun's transform relative to the right-hand IK TARGET is computed - the target is
-- exactly what libs/ik.lua solves the hand to: controller loc + rotate(end_bone_offset, controller rot), rotation
-- ComposeRotators(end_bone_rotation, controller rot) - and the gun is moved off UObjectHook and parented to the rig's
-- hand_r bone with that relative transform. Melee / two-handed flags and all Hands-mode offsets stay as they are.
-- Done in the post-stereo callback, where the controller component and UEVR's gun placement are from the same frame.
-- The relative transform is re-asserted every tick (two_handed.lua rotates the gun in world space while two-handing)
-- and cached per weapon mesh so a rig rebuild re-parents without recomputing. Leaving IK hands the gun back to the
-- attachments library (re-attached to the raw controller by the pre-tick below).
local ik = require('libs/ik')
local controllers = require('libs/controllers')

local IK_HAND_BONE = "hand_r"
local ikHeld = nil          -- { mesh = weapon component, rig = rig mesh it is parented to }
local ikRelative = {}       -- weapon component address -> { loc = {X,Y,Z}, rot = {Pitch,Yaw,Roll} }
local ikHandBoneFName = nil
local ikRanThisTick = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ikRanThisTick = false end)

local function isIKMode()
    return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end

-- right-hand solver's end_bone_offset / end_bone_rotation from data/ik_parameters.json (re-read per hand-over so
-- IK panel tuning is picked up on the next weapon / mode change)
local function rightHandOffsets()
    local offset, rotation = {0, 0, 0}, {0, 0, 0}
    pcall(function()
        local params = json.load_file("ik_parameters.json")
        local profileName = params and params["_profileState"] and params["_profileState"]["currentEditingProfile"] or "default"
        local profile = params and (params[profileName] or params["default"])
        for _, solver in pairs(profile and profile["solvers"] or {}) do
            if solver["end_control_type"] == 1 then -- ik.ControllerType.RIGHT_CONTROLLER
                offset = solver["end_bone_offset"] or offset
                rotation = solver["end_bone_rotation"] or rotation
            end
        end
    end)
    return offset, rotation
end

-- the right-hand IK target from this frame's controller pose (what libs/ik.lua solves hand_r to):
-- loc = controller + rotate(end_bone_offset, controller rot), rot = ComposeRotators(end_bone_rotation, controller rot)
local function rightHandTargetTransform(off, rotOff)
    local ctrl = controllers.getController(Handed.Right, true)
    if not alive(ctrl) then return nil end
    local cl, cr = ctrl:K2_GetComponentLocation(), ctrl:K2_GetComponentRotation()
    local offWS = kismet_math_library:GreaterGreater_VectorRotator(uevrUtils.vector(off[1], off[2], off[3]), cr)
    local handLoc = uevrUtils.vector(cl.X + offWS.X, cl.Y + offWS.Y, cl.Z + offWS.Z)
    local handRot = kismet_math_library:ComposeRotators(uevrUtils.rotator(rotOff[1], rotOff[2], rotOff[3]), cr)
    return kismet_math_library:MakeTransform(handLoc, handRot, uevrUtils.vector(1, 1, 1)), { X = handLoc.X, Y = handLoc.Y, Z = handLoc.Z }
end

-- weapon transform relative to the right-hand IK target, both taken from this frame's controller pose
local function computeIKRelative(mesh)
    local result = nil
    pcall(function()
        local off, rotOff = rightHandOffsets()
        local handT = rightHandTargetTransform(off, rotOff)
        if handT == nil then return end
        local weaponT = kismet_math_library:MakeTransform(mesh:K2_GetComponentLocation(), mesh:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1))
        local rel = kismet_math_library:MakeRelativeTransform(weaponT, handT)
        local t = rel.Translation
        local r = kismet_math_library:Quat_Rotator(rel.Rotation)
        result = { loc = { X = t.X, Y = t.Y, Z = t.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
    end)
    return result
end

local function applyIKRelative(mesh, rel)
    uevrUtils.set_component_relative_transform(mesh, rel.loc, rel.rot, { X = 1, Y = 1, Z = 1 })
end

local function parentToIKHand(mesh, rig, rel)
    if ikHandBoneFName == nil then ikHandBoneFName = uevrUtils.fname_from_string(IK_HAND_BONE) end
    pcall(function() UEVR_UObjectHook.remove_motion_controller_state(mesh) end)
    local ok = pcall(function() mesh:K2_AttachTo(rig, ikHandBoneFName, 0, false) end) -- 0 = KeepRelative
    if ok then
        applyIKRelative(mesh, rel)
        ikHeld = { mesh = mesh, rig = rig }
        print("[weaponhook] weapon parented to the IK hand: " .. mesh:get_full_name())
    end
    return ok
end

-- leaving IK (or the weapon went away): give the gun back to the attachments library / controller
local function releaseFromIKHand(reattach)
    local held = ikHeld
    ikHeld = nil
    if held == nil then return end
    if reattach and alive(held.mesh) then
        pcall(function() held.mesh:DetachFromParent(false, false) end)
        pcall(function() attachments.detachGripAttachments(Handed.Right) end)
        current_weapon = nil -- the pre-tick re-attaches it to the raw controller
        next_attach_retry = 0
        print("[weaponhook] weapon returned to the controller")
    end
end

-- cutscene: weapon back onto its original game parent (see hrCutsceneActive above); the pre-tick re-attaches it to
-- the hand when the montage ends
releaseWeaponForCutscene = function()
    ikHeld = nil -- re-parented below, not handed back to the controller
    pcall(function() attachments.detachGripAttachments(Handed.Right) end)
    local o = weapon_origin
    if o == nil or not alive(o.mesh) or not alive(o.parent) or o.mesh ~= attached_weapon_mesh then
        -- nothing recorded (e.g. the gun was already on the hand when scripts were reset): the game's layout -
        -- skeletal root on Pawn.Mesh weapon_jnt_r1Socket, static melee mesh on the equipment root, zero offsets
        o = nil
        pcall(function()
            local mesh, weapon, pawn = attached_weapon_mesh, current_weapon, getPlayerPawn()
            if not (alive(mesh) and alive(weapon) and pawn ~= nil) then return end
            local root = weapon.RootComponent
            local zero = { loc = { X = 0, Y = 0, Z = 0 }, rot = { Pitch = 0, Yaw = 0, Roll = 0 } }
            if mesh == root then
                o = { mesh = mesh, parent = pawn.Mesh, socket = uevrUtils.fname_from_string("weapon_jnt_r1Socket"), loc = zero.loc, rot = zero.rot }
            else
                o = { mesh = mesh, parent = root, socket = uevrUtils.fname_from_string(""), loc = zero.loc, rot = zero.rot }
            end
        end)
        if o == nil then
            print("[weaponhook] cutscene: no held weapon to return")
            return
        end
    end
    pcall(function() o.mesh:DetachFromParent(false, false) end)
    local ok = pcall(function()
        o.mesh:K2_AttachTo(o.parent, o.socket, 0, false) -- 0 = KeepRelative
        uevrUtils.set_component_relative_transform(o.mesh, o.loc, o.rot, { X = 1, Y = 1, Z = 1 })
    end)
    print("[weaponhook] cutscene: weapon " .. (ok and "returned to " or "FAILED to return to ") .. o.parent:get_full_name())
end

local function ikHandTick()
    if _G.hrCutsceneActive then return end -- the weapon is on its game parent for the cutscene
    local mesh = attached_weapon_mesh
    if not isIKMode() then
        if ikHeld ~= nil then releaseFromIKHand(true) end
        return
    end
    if mesh == nil or not alive(mesh) then ikHeld = nil return end
    local rig = ik.getCurrentMesh(1)
    if rig == nil or not alive(rig) then return end -- rig rebuilding: the gun keeps its last pose for a moment

    local key = mesh:get_address()
    if ikHeld ~= nil and ikHeld.mesh == mesh and ikHeld.rig == rig then
        -- watchdog: the game re-attached the gun to its body socket after a montage -> back onto the IK hand
        local parent = nil
        pcall(function() parent = mesh.AttachParent end)
        local onRig = false
        pcall(function() onRig = parent ~= nil and parent:get_address() == rig:get_address() end)
        if not onRig and ikRelative[key] ~= nil then
            print("[weaponhook] weapon left the IK hand (parent " .. tostring(parent and parent:get_full_name()) .. "); re-parenting")
            parentToIKHand(mesh, rig, ikRelative[key])
            return
        end
        -- keep the grip exact (two-handing rotates the gun in world space; it restores on release)
        if _G.isTwoHandingActive ~= true and ikRelative[key] ~= nil then applyIKRelative(mesh, ikRelative[key]) end
        return
    end

    local rel = ikRelative[key]
    if rel == nil then
        -- first hand-over of this weapon: needs UEVR's controller placement to be live (attached a moment ago)
        if os.clock() < ikTransferNotBefore then return end
        -- query throws -> trust the pre-tick (it only sets attached_weapon_mesh after a successful attach); never
        -- get_or_add here, that would put a gun that is not on UObjectHook back onto it with zero offsets
        if getHookState(mesh, true) == nil then return end
        rel = computeIKRelative(mesh)
        if rel == nil then return end
        ikRelative[key] = rel
    end
    parentToIKHand(mesh, rig, rel)
end

-- two_handed.lua (IK modes): the held gun's UN-PIVOTED pose this frame = the cached grip-relative transform on the
-- right-hand IK TARGET (controller + solver offsets). Deliberately not the hand_r bone: while two-handing, the right IK
-- hand is itself turned with the gun (two_handed.lua attaches its target to the gun), so a bone-based base would turn
-- twice. Returns baseTransform (world), pivot (hand target location, world), rightControllerTransform (world) - or nil
-- when the gun is not on the IK hand. refreshOffsets re-reads the solver offsets from ik_parameters.json (on grab).
local twoHandOffsets = nil
_G.hrIKWeaponBase = function(mesh, refreshOffsets)
    if ikHeld == nil or ikHeld.mesh ~= mesh or not alive(mesh) then return nil end
    local rel = ikRelative[mesh:get_address()]
    if rel == nil then return nil end
    if refreshOffsets or twoHandOffsets == nil then
        local off, rotOff = rightHandOffsets()
        twoHandOffsets = { off = off, rot = rotOff }
    end
    local handT, pivot = rightHandTargetTransform(twoHandOffsets.off, twoHandOffsets.rot)
    if handT == nil then return nil end
    local ctrl = controllers.getController(Handed.Right, true)
    local ctrlT = kismet_math_library:MakeTransform(ctrl:K2_GetComponentLocation(), ctrl:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1))
    local relT = kismet_math_library:MakeTransform(uevrUtils.vector(rel.loc.X, rel.loc.Y, rel.loc.Z),
        uevrUtils.rotator(rel.rot.Pitch, rel.rot.Yaw, rel.rot.Roll), uevrUtils.vector(1, 1, 1))
    return kismet_math_library:ComposeTransforms(relT, handT), pivot, ctrlT
end

uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if ikRanThisTick then return end
    ikRanThisTick = true
    local ok, err = pcall(ikHandTick)
    if not ok then print("[weaponhook] IK hand: " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    ikHeld = nil
    ikRelative = {}
end)

-- ---------------------------------------------------------------------------------------------
-- POST-TICK: arms hide, weapon visibility, first-person mode
-- ---------------------------------------------------------------------------------------------
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta_time)
    local pawn = getPlayerPawn()
    if pawn == nil then return end

    -- body mesh: out of the render passes unless a montage rule wants it visible
    local arms = nil
    pcall(function() arms = pawn.Mesh end)
    if arms ~= nil then
        local show = montageWantsArmsVisible()
        pcall(function()
            if show then
                if arms.bRenderInMainPass == false then arms:SetRenderInMainPass(true) end
                if arms.bRenderInDepthPass == false then arms:SetRenderInDepthPass(true) end
            else
                if arms.bRenderInMainPass == true then arms:SetRenderInMainPass(false) end
                if arms.bRenderInDepthPass == true then arms:SetRenderInDepthPass(false) end
            end
        end)
        if show ~= armsShown then
            armsShown = show
            print("[weaponhook] pawn arms " .. (show and "shown (montage rule)" or "hidden"))
        end
    end

    -- weapon on the hand
    local held = attached_weapon_mesh
    if held ~= nil and not alive(held) then held = nil attached_weapon_mesh = nil end
    if held ~= nil then
        local hideWeapon = montageWantsWeaponHidden()
        if hideWeapon then
            hideWeaponTree(held)
        elseif weaponHidden then
            restoreWeaponTree(held)
        end
        weaponHidden = hideWeapon
        clearFirstPerson(held, true) -- the game re-flags its meshes on equip / visual changes
    end

    -- VR hands: keep them out of first-person mode (cheap reads)
    clearFirstPerson(hands.getHandComponent(Handed.Left), true)
    clearFirstPerson(hands.getHandComponent(Handed.Right), true)
end)

print("[weaponhook] loaded")
