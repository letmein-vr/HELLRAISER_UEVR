-- Genesis Configuration (the puzzle cube) in the VR left hand.
--
-- Game facts (MCP, 2026-10-08):
--   * Equipping the cube makes Pawn.CurrentEquipment a BP_GenesisConfiguration_C (CoreEquipable). That actor has NO
--     visible mesh (FirstPersonEqupable / EquipableStatic are empty - weaponhook.lua waits on it forever, harmless).
--   * The visible cube is a separate actor, CurrentEquipment.ConfigurationActor = BP_GenesisConfigurationBox_C:
--     DefaultSceneRoot -> SkeletalMesh (SK_GenesisCubeSmallerFirstPerson, no anim BP) -> SM_BloodCover + puzzle glow
--     Niagara; plus an AkComponent + TelekinesisPullLocation on the root. The root sits on Pawn.Mesh bone
--     weapon_jnt_l (parent bone hand_l) with a zero relative transform.
--   * So the cube's "animation" is the pawn's anim moving weapon_jnt_l inside the left hand.
--
-- VR: the cube root goes through the attachments library (Attachments panel entry
-- "BP_GenesisConfigurationBox_C_DefaultSceneRoot": offsets + left grip animation) onto bone hand_l of the VR left hand
-- (Hands mode) or of the IK rig (IK modes) - both are copies of the Pawn.Mesh skeleton, so a zero offset puts the cube
-- exactly where the game holds it. Every tick the cube MESH gets weapon_jnt_l's transform relative to hand_l from the
-- (hidden, still animating) Pawn.Mesh, so the game's in-hand motion of the cube is kept, while whole-arm motion is
-- replaced by the real hand. On unequip, and during interactive cutscenes (_G.hrCutsceneActive, see weaponhook.lua),
-- the root goes back onto Pawn.Mesh weapon_jnt_l.

local uevrUtils = require('libs/uevr_utils')
local attachments = require('libs/attachments')
local hands = require('libs/hands')
local ik = require('libs/ik')

local HAND_BONE = "hand_l"
local CUBE_BONE = "weapon_jnt_l"
local REATTACH_RETRY_S = 0.25
local RTS_PARENT_BONE_SPACE = 3

local handBoneFName, cubeBoneFName = nil, nil
local held = nil            -- { box, root, mesh, target, pawnMesh }
local nextAttachTry = 0
local offsetSeedChecked = false

local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

local function isIKMode()
    return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end

-- the mesh whose hand_l bone carries the cube in the current hands mode
local function getTargetMesh()
    local mesh = nil
    if isIKMode() then
        mesh = ik.getCurrentMesh(1)
    else
        mesh = hands.getHandComponent(Handed.Left)
    end
    if alive(mesh) then return mesh end
    return nil
end

local function getCubeActor(pawn)
    local box = nil
    local equipment = nil
    pcall(function()
        equipment = pawn.CurrentEquipment
        if equipment ~= nil then box = equipment.ConfigurationActor end
    end)
    -- Genesis weapons held with the cube (2026-10-17, MCP: BP_GenesisRevolver_C in the right hand) have no
    -- ConfigurationActor property - only the cube's own equipment (BP_GenesisConfiguration_C) does. Every equipable
    -- answers CoreEquipable.GetGenesisConfigurationActor() with the cube actor, so that is the fallback.
    if box == nil and equipment ~= nil then
        pcall(function()
            if equipment.GetGenesisConfigurationActor ~= nil then box = equipment:GetGenesisConfigurationActor() end
        end)
    end
    if alive(box) then return box end
    return nil
end

-- New attachment IDs get the global default rotation (0,-90,0) meant for guns on the controller. On hand_l the cube
-- wants a zero offset - seeded once, only when the ID has no saved entry yet (never overwrites panel tuning).
local function seedZeroOffsetIfNew(root, hadEntry)
    if hadEntry then return end
    local id = attachments.getAttachmentIDFromAttachment(root)
    if id == nil then return end
    attachments.updateAttachmentTransform(uevrUtils.vector(0, 0, 0), uevrUtils.rotator(0, 0, 0), uevrUtils.vector(1, 1, 1), id, Handed.Left)
    print("[genesis_cube] seeded zero offset for new attachment " .. id)
end

local function attachmentEntryExists(id)
    local found = false
    pcall(function()
        local params = json.load_file("attachments_parameters.json")
        for _, entry in ipairs(params and params["attachmentOffsets"] or {}) do
            if entry["id"] == id then found = true end
        end
    end)
    return found
end

local function attachCube(box, root, mesh, target, pawnMesh)
    if handBoneFName == nil then handBoneFName = uevrUtils.fname_from_string(HAND_BONE) end
    local options = {
        detachFromOriginOnGrip = true,
        maintainWorldPositionOnDetachFromOrigin = false,
        detachFromParentOnRelease = true,
        maintainWorldPositionOnDetachFromParent = false,
        reattachToOriginOnRelease = false, -- restored to weapon_jnt_l here (the lib would reuse the hand_l socket name)
        restoreTransformToOriginOnReattach = false,
        -- the game drives the cube's visibility itself (HandleGenesisConfigurationVisibility)
        allowChildVisibilityHandling = false,
        allowChildHiddenInGameHandling = false,
        allowRenderInMainPassHandling = false,
        useCurrentAttachedSocketName = false,
    }
    local hadEntry = true
    if not offsetSeedChecked then
        hadEntry = attachmentEntryExists(attachments.getAttachmentIDFromAttachment(root))
    end
    local ok, success = pcall(attachments.attachToMesh, root, target, HAND_BONE, Handed.Left, options)
    if not (ok and success) then
        print("[genesis_cube] attach failed: " .. tostring(success))
        return false
    end
    if not offsetSeedChecked then
        offsetSeedChecked = true
        seedZeroOffsetIfNew(root, hadEntry)
    end
    held = { box = box, root = root, mesh = mesh, target = target, pawnMesh = pawnMesh,
        pawn = uevr.api:get_local_pawn(0), since = os.clock() }
    if _G.hrClearFirstPerson ~= nil then _G.hrClearFirstPerson(root, true) end
    print("[genesis_cube] cube attached to " .. HAND_BONE .. " of " .. target:get_full_name())
    return true
end

-- Loading a save replaces the pawn and the cube WITHOUT a level-change callback first (2026-10-08: the release then
-- called DetachFromParent / K2_AttachTo and the lib's grip-release hand pose on freed objects -> access violation in
-- game code, game froze). get_full_name() can still succeed on freed memory, so liveness of what we hold is
-- UEVR_UObjectHook.exists() (reliable for objects that have been around; freshly spawned ones can read false for a
-- moment, hence the age guard). A dead hold is only forgotten, never touched.
local HELD_EXISTS_MIN_AGE_S = 2.0
local function exists(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return UEVR_UObjectHook.exists(obj) end)
    return ok and r == true
end

-- Objects this script keeps between ticks carry their identity (2026-10-14). The level-change callback comes only
-- after the new level is current, so a save load can leave us holding addresses of freed objects whose memory the new
-- level has already reused. destroyCubeReticule() then ran destroyComponent(component, destroyOwner = true) on them -
-- i.e. it could destroy a component of the NEW level and its owner actor (the new pawn: no player, camera at the
-- world origin; or the controller's input). An object is only touched while the world and the pawn it was made under
-- are still current, it still has its name, and UEVR has not dropped it. exists() only counts once it has said yes:
-- components we create ourselves can read false until UEVR adopts them (OW2, 2026-10), and rejecting them on that
-- would re-create the reticule every frame.
local function remember(obj)
    if obj == nil then return nil end
    local ok, name = pcall(function() return obj:get_full_name() end)
    if not ok or name == nil then return nil end
    return { obj = obj, name = name, world = uevrUtils.get_world(), pawn = uevr.api:get_local_pawn(0), seenAlive = false }
end

local function stillSame(rec)
    if rec == nil or rec.obj == nil then return false end
    if uevrUtils.get_world() ~= rec.world then return false end
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil or pawn ~= rec.pawn then return false end
    if exists(rec.obj) then
        rec.seenAlive = true
    elseif rec.seenAlive then
        return false
    end
    local ok, name = pcall(function() return rec.obj:get_full_name() end)
    return ok and name == rec.name
end

local function heldIsDead(h, pawn)
    if pawn ~= h.pawn then return true end
    if os.clock() - h.since < HELD_EXISTS_MIN_AGE_S then return false end
    return not (exists(h.box) and exists(h.root) and exists(h.mesh) and exists(h.pawnMesh))
end

local function forgetCube()
    held = nil
    pcall(function() attachments.forgetGripAttachments(Handed.Left) end)
    print("[genesis_cube] held cube is gone (save load / respawn) - forgotten without touching it")
end

-- give the cube back to the game: root onto Pawn.Mesh weapon_jnt_l, mesh back to its zero relative transform
local function releaseCube()
    local h = held
    if h == nil then return end
    if not (exists(h.box) and exists(h.root)) then forgetCube() return end
    held = nil
    pcall(function() attachments.detachGripAttachments(Handed.Left) end)
    if alive(h.mesh) then
        pcall(function() uevrUtils.set_component_relative_transform(h.mesh, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }) end)
    end
    if alive(h.root) and alive(h.pawnMesh) then
        if cubeBoneFName == nil then cubeBoneFName = uevrUtils.fname_from_string(CUBE_BONE) end
        pcall(function()
            h.root:K2_AttachTo(h.pawnMesh, cubeBoneFName, 0, false)
            uevrUtils.set_component_relative_transform(h.root, { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 })
        end)
    end
    print("[genesis_cube] cube returned to the game")
end

-- the game's animated cube transform inside the left hand, copied onto the cube mesh under the VR hand_l
local function applyInHandAnimation(h)
    if cubeBoneFName == nil then cubeBoneFName = uevrUtils.fname_from_string(CUBE_BONE) end
    local t = h.pawnMesh:GetSocketTransform(cubeBoneFName, RTS_PARENT_BONE_SPACE)
    if t == nil then return end
    local loc = t.Translation
    local rot = kismet_math_library:Quat_Rotator(t.Rotation)
    uevrUtils.set_component_relative_transform(h.mesh, { X = loc.X, Y = loc.Y, Z = loc.Z }, { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll }, { X = 1, Y = 1, Z = 1 })
end

local function isOnTarget(h, target)
    local ok, r = pcall(function()
        return h.root.AttachParent == target and h.root.AttachSocketName:to_string() == HAND_BONE
    end)
    return ok and r
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    local pawn = uevr.api:get_local_pawn(0)
    if held ~= nil and heldIsDead(held, pawn) then forgetCube() end
    local box = pawn ~= nil and getCubeActor(pawn) or nil

    -- interactive cutscene (generic AnimMontage_ montage, flag set in weaponhook.lua): the game holds the cube on
    -- weapon_jnt_l so it follows the cutscene animation; it comes back to the VR hand when the montage ends
    if _G.hrCutsceneActive == true then
        if held ~= nil then releaseCube() end
        return
    end

    if box == nil or (held ~= nil and held.box ~= box) then
        if held ~= nil then releaseCube() end
        if box == nil then return end
    end

    local root, mesh, pawnMesh = nil, nil, nil
    pcall(function()
        root = box.RootComponent
        mesh = box.SkeletalMesh
        pawnMesh = pawn.Mesh
    end)
    if not (alive(root) and alive(mesh) and alive(pawnMesh)) then return end

    local target = getTargetMesh()
    if target == nil then return end -- hands / IK rig (re)building: the cube keeps its last parent for a moment

    if held == nil or held.target ~= target or not isOnTarget(held, target) then
        if os.clock() < nextAttachTry then return end
        nextAttachTry = os.clock() + REATTACH_RETRY_S
        if not attachCube(box, root, mesh, target, pawnMesh) then return end
    end

    local ok, err = pcall(applyInHandAnimation, held)
    if not ok then print("[genesis_cube] in-hand animation: " .. tostring(err)) end
    if _G.hrClearFirstPerson ~= nil then _G.hrClearFirstPerson(root, true) end -- throttled; the game re-flags its meshes
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    held = nil
    nextAttachTry = 0
end)

-- Telekinesis aim from the left hand (2026-10-08): the cube's abilities pick their target natively
-- (COMP_TelekinesisTargeting, aims from the camera). HellraiserAimFix.dll swaps the camera transform it reads for
-- this pose while the targeting runs; it ignores poses older than 0.25 s, so stopping the sends (no cube in hand,
-- cutscene, menu) gives the game's camera aim back. Sent before the world tick so the targeting gets this frame's
-- pose.
-- The pose carries the "Grab / target aim" panel trim.
local controllers = require('libs/controllers')
local leftHandAimRay -- (kind) -> location, rotation, direction; defined below with the panel trims
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if held == nil or _G.hrCutsceneActive == true then return end
    if _G.hrIsInMenu ~= nil and _G.hrIsInMenu() then return end
    pcall(function()
        local l, r = leftHandAimRay("target")
        if l == nil then return end
        uevr.api:dispatch_custom_event("HellraiserLeftAim",
            string.format("%.3f,%.3f,%.3f,%.4f,%.4f,%.4f", l.X, l.Y, l.Z, r.Pitch, r.Yaw, r.Roll))
    end)
end)

-- Telekinesis THROWS from the left hand (2026-10-08). The grab already follows the hand (plugin), but the throw is
-- aimed inside the thrown object's Blueprint (BP_TelekinesisBase_C) from the camera. MCP watch of a throw
-- (BP_Telekinesis_HellfireLabyrinth_C): on the release frame the Blueprint sets InitialVelocity = ProjectileMovement
-- .Velocity (camera aim) and StartLocation (the object, floating in front of the camera); two frames later
-- StartingDirection = the same direction; then the speed ramps up along it (no homing). So the launch is corrected
-- here: on the release frame the velocity is turned toward the point the left controller points at (trace along
-- its ray), keeping the game's speed; while the Blueprint keeps re-applying its camera direction (speed ramp) the
-- velocity is turned again; any other change (a hit / bounce) ends the correction.
local THROW_TRACK_AFTER_RELEASE_S = 3.0  -- keep watching a released object this long for its launch
local THROW_CORRECT_S = 2.0              -- re-aim window after the launch
local THROW_TRACE_DISTANCE = 20000.0     -- cm
local THROW_SAME_DIR_DOT = 0.9986        -- ~3 deg

local throw = { obj = nil, lastSeen = 0, launched = nil }

local function vlen(v) return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
local function vnorm(v)
    local l = vlen(v)
    if l < 1e-6 then return nil end
    return { X = v.X / l, Y = v.Y / l, Z = v.Z / l }
end
local function vdot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end

local function setVec(struct, v)
    struct.X, struct.Y, struct.Z = v.X, v.Y, v.Z
end

-- Panel: aim trims, relative to the controller (+yaw = right, +pitch = up) - one pair for grabbing / targeting (the
-- pose sent to HellraiserAimFix), one for throws
local configui = require('libs/configui')
_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 5.5, label = "Genesis Cube", layout = {
    { widgetType = "slider_float", id = "gc_target_yaw", label = "Grab/target aim left/right (deg, + = right)", initialValue = 0.0, range = {-30.0, 30.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "gc_target_pitch", label = "Grab/target aim down/up (deg, + = up)", initialValue = 0.0, range = {-30.0, 30.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "gc_throw_yaw", label = "Throw aim left/right (deg, + = right)", initialValue = 0.0, range = {-30.0, 30.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "gc_throw_pitch", label = "Throw aim down/up (deg, + = up)", initialValue = 0.0, range = {-30.0, 30.0}, speed = 0.1 },
    -- where objects held by telekinesis float (see "Held object position" below), in the left controller's frame
    { widgetType = "text", label = "Held object position (relative to the cube, left controller frame)" },
    { widgetType = "checkbox", id = "gc_pull_override", label = "Place held objects relative to the left hand", initialValue = true },
    { widgetType = "slider_float", id = "gc_pull_up", label = "Held object up (cm)", initialValue = 20.0, range = {-40.0, 60.0}, speed = 0.5 },
    { widgetType = "slider_float", id = "gc_pull_forward", label = "Held object forward (cm)", initialValue = 0.0, range = {-40.0, 60.0}, speed = 0.5 },
    { widgetType = "slider_float", id = "gc_pull_right", label = "Held object right (cm)", initialValue = 0.0, range = {-40.0, 40.0}, speed = 0.5 },
    -- the cube's own reticule (see "Genesis cube reticule" below): idle crosshair size relative to the weapon
    -- reticule's size; the hold countdown has its own values ("keep the same apparent size" stays shared)
    { widgetType = "text", label = "Cube reticule" },
    { widgetType = "slider_float", id = "gc_idle_ret_scale", label = "Cube crosshair size (x weapon reticule size)", range = {0.1, 2.0}, initialValue = 0.5, speed = 0.01 },
    { widgetType = "text", label = "Hold countdown reticule" },
    { widgetType = "slider_float", id = "gc_ret_size", label = "Countdown size", range = {0.2, 5.0}, initialValue = 1.0, speed = 0.01 },
    { widgetType = "slider_float", id = "gc_ret_distance", label = "Countdown max distance (cm)", range = {100.0, 5000.0}, initialValue = 1000.0, speed = 10.0 },
    { widgetType = "slider_float", id = "gc_ret_brightness", label = "Countdown brightness", range = {1.0, 20.0}, initialValue = 1.0, speed = 0.1 },
}})
local function sliderValue(id)
    local v = configui.getValue(id)
    return type(v) == "number" and v or 0.0
end

-- the cube's aim ray: left controller + the panel trim for `kind` ("target" or "throw"), applied in the controller's
-- own frame (ComposeRotators(A, B) = A, then B). Returns location, rotation, direction or nil.
leftHandAimRay = function(kind)
    local ctrl = controllers.getController(Handed.Left, true)
    if not alive(ctrl) then return nil end
    local loc, rot = ctrl:K2_GetComponentLocation(), ctrl:K2_GetComponentRotation()
    local prefix = kind == "target" and "gc_target_" or "gc_throw_"
    local yaw, pitch = sliderValue(prefix .. "yaw"), sliderValue(prefix .. "pitch")
    if yaw ~= 0 or pitch ~= 0 then
        rot = kismet_math_library:ComposeRotators(uevrUtils.rotator(pitch, yaw, 0), rot)
    end
    return loc, rot, kismet_math_library:GetForwardVector(rot)
end

-- Held object position (2026-10-09). Objects held by telekinesis (e.g. BP_Telekinesis_Sawblade_C) are attached to the
-- cube's TelekinesisPullLocation, a SceneComponent at (-10.4, 20, 19.3) in the cube root's frame (MCP) - "above" the cube
-- in the game's own hand pose, but to the LEFT of it with the cube in the VR hand. While the cube is in the VR hand the
-- pull location is placed every tick at the cube mesh + the panel's up / forward / right offsets in the LEFT
-- CONTROLLER's frame (the held object follows, being its child); the game's relative offset is restored when the
-- cube goes back to the game (cutscene / unequip) or the override is switched off.
local pull = { rec = nil, orig = nil }
local function restorePull()
    -- only the same live component gets its game offset back; after a save load it is simply forgotten
    if pull.rec ~= nil and pull.orig ~= nil and stillSame(pull.rec) then
        local comp, orig = pull.rec.obj, pull.orig
        pcall(function() uevrUtils.set_component_relative_location(comp, orig) end)
    end
    pull.rec, pull.orig = nil, nil
end
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    local h = held
    if h == nil or configui.getValue("gc_pull_override") == false then restorePull() return end
    local ok, err = pcall(function()
        local comp = h.box.TelekinesisPullLocation
        if comp == nil then return end
        if pull.rec == nil or pull.rec.obj ~= comp then
            restorePull()
            local r = comp.RelativeLocation
            pull.rec, pull.orig = remember(comp), { X = r.X, Y = r.Y, Z = r.Z }
        end
        local ctrl = controllers.getController(Handed.Left, true)
        if ctrl == nil then return end
        local rot = ctrl:K2_GetComponentRotation()
        local f = kismet_math_library:GetForwardVector(rot)
        local rt = kismet_math_library:GetRightVector(rot)
        local up = kismet_math_library:GetUpVector(rot)
        local c = h.mesh:K2_GetComponentLocation()
        local u, fw, rr = sliderValue("gc_pull_up"), sliderValue("gc_pull_forward"), sliderValue("gc_pull_right")
        local p = uevrUtils.vector(c.X + up.X * u + f.X * fw + rt.X * rr, c.Y + up.Y * u + f.Y * fw + rt.Y * rr, c.Z + up.Z * u + f.Z * fw + rt.Z * rr)
        comp:K2_SetWorldLocation(p, false, reusable_hit_result, false)
    end)
    if not ok then print("[genesis_cube] held object position: " .. tostring(err)) end
end)
uevrUtils.registerPreLevelChangeCallback(function(level) pull.rec, pull.orig = nil, nil end)

-- For the VR reticule (uevrmenus.lua custom target): where the cube aims while it is in the left hand - the
-- grab/target aim, or the throw aim while something is held
_G.hrCubeAim = function()
    if held == nil or _G.hrCutsceneActive == true then return nil end
    local holding = false
    pcall(function() holding = uevr.api:get_local_pawn(0).CurrentTelekinesisObject ~= nil end)
    local ok, loc, rot = pcall(leftHandAimRay, holding and "throw" or "target")
    if not ok then return nil end
    return loc, rot
end

-- where the cube aims: trace hit, else far along the ray
local function leftHandAimPoint(ignore)
    local loc, _, dir = leftHandAimRay("throw")
    if loc == nil then return nil end
    local point = nil
    pcall(function()
        point = uevrUtils.getTargetLocation(loc, dir, 0, ignore, false, 10, THROW_TRACE_DISTANCE)
    end)
    if point == nil then
        point = { X = loc.X + dir.X * THROW_TRACE_DISTANCE, Y = loc.Y + dir.Y * THROW_TRACE_DISTANCE, Z = loc.Z + dir.Z * THROW_TRACE_DISTANCE }
    end
    return point
end

local function reaimThrow(obj, pmc, launched)
    local v = pmc.Velocity
    local speed = vlen(v)
    if speed < 1 then return end
    local nv = { X = launched.dir.X * speed, Y = launched.dir.Y * speed, Z = launched.dir.Z * speed }
    setVec(pmc.Velocity, nv)
    pcall(function() setVec(obj.InitialVelocity, nv) end)
    pcall(function() setVec(obj.StartingDirection, launched.dir) end)
end

local function throwTick()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return end

    -- the object being held (or just released)
    local current = nil
    pcall(function() current = pawn.CurrentTelekinesisObject end)
    if current ~= nil and alive(current) then
        if current ~= throw.obj then
            throw.obj, throw.launched = current, nil
            -- a reused object can still carry the last throw's InitialVelocity: the launch is a CHANGE from this
            throw.baseIV = nil
            pcall(function() local iv = current.InitialVelocity throw.baseIV = { X = iv.X, Y = iv.Y, Z = iv.Z } end)
        end
        throw.lastSeen = os.clock()
    end
    local obj = throw.obj
    if obj == nil then return end
    if not exists(obj) or (throw.launched == nil and os.clock() - throw.lastSeen > THROW_TRACK_AFTER_RELEASE_S) then
        throw.obj, throw.launched = nil, nil
        return
    end
    local pmc = nil
    pcall(function() pmc = obj.ProjectileMovement end)
    if pmc == nil then return end

    if throw.launched == nil then
        -- release frame: the Blueprint has just written InitialVelocity
        local iv = nil
        pcall(function() iv = obj.InitialVelocity end)
        if iv == nil or vlen(iv) < 1 then return end
        local b = throw.baseIV
        if b ~= nil and vlen({ X = iv.X - b.X, Y = iv.Y - b.Y, Z = iv.Z - b.Z }) < 1 then return end
        if held == nil or _G.hrCutsceneActive == true then throw.obj = nil return end -- not a cube throw from the VR hand
        local gameDir = vnorm(iv)
        local start = obj:K2_GetActorLocation()
        local target = leftHandAimPoint({ pawn, obj })
        if gameDir == nil or target == nil then throw.obj = nil return end
        local dir = vnorm({ X = target.X - start.X, Y = target.Y - start.Y, Z = target.Z - start.Z })
        if dir == nil then throw.obj = nil return end
        throw.launched = { gameDir = gameDir, dir = dir, at = os.clock() }
        reaimThrow(obj, pmc, throw.launched)
        print(string.format("[genesis_cube] throw re-aimed to the left hand: game (%.2f %.2f %.2f) -> hand (%.2f %.2f %.2f)",
            gameDir.X, gameDir.Y, gameDir.Z, dir.X, dir.Y, dir.Z))
        return
    end

    -- after the launch: follow the Blueprint's speed ramp, stop at anything else
    local launched = throw.launched
    if os.clock() - launched.at > THROW_CORRECT_S then throw.obj, throw.launched = nil, nil return end
    local vdir = vnorm(pmc.Velocity)
    if vdir == nil then return end
    if vdot(vdir, launched.dir) >= THROW_SAME_DIR_DOT then return end -- still on our line
    if vdot(vdir, launched.gameDir) >= THROW_SAME_DIR_DOT then
        reaimThrow(obj, pmc, launched)                                -- Blueprint re-applied its camera aim
    else
        throw.obj, throw.launched = nil, nil                          -- hit / bounce: hands off
    end
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    local ok, err = pcall(throwTick)
    if not ok then
        throw.obj, throw.launched = nil, nil
        print("[genesis_cube] throw: " .. tostring(err))
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    throw.obj, throw.launched = nil, nil
end)

-- Genesis cube reticule (2026-10-09; replaces the 2026-10-08 version that borrowed libs/reticule.lua's single
-- reticule). libs/reticule.lua drives ONE reticule (the game's W_WeaponCrosshairs_C), so while the cube aimed with it,
-- a ranged weapon in the right hand had no reticule at all. The library reticule is now the gun's only (uevrmenus.lua
-- custom target = muzzle), and the cube has its own WidgetComponent, drawn where the cube aims (_G.hrCubeAim; trace
-- hit, at most the distance slider), facing the HMD, kept the same apparent size:
--   * idle: a small unlit sphere (2026-10-14; was an own instance of the game's W_Crosshair_Cube_C, which broke save
--     loads - see ensureCrosshairComponent), "Weapon Reticule" panel values (ret_*);
--   * holding an object: the telekinesis countdown ring Pawn.CurrentTelekinesisObject.HoldingWidget
--     (W_TelekinesisHoldingTemp_C, new instance per grab) taken out of the flat HUD, "Genesis Cube" values (gc_ret_*).
--     Before switching away its widget is cleared from the component (never re-added to the viewport).
local CROSSHAIR_MESH = "StaticMesh /Engine/EngineMeshes/Sphere.Sphere"
local CROSSHAIR_MATERIAL = "Material /Engine/EngineMaterials/Widget3DPassThrough.Widget3DPassThrough"
local CROSSHAIR_MESH_SCALE = 0.008 -- libs/reticule.lua default mesh reticule size
local RETICULE_SIZE_REFERENCE = 200 -- cm, same reference as the weapon reticule (uevrmenus.lua)
local WIDGET_BASE_SCALE = { X = -0.1, Y = -0.1, Z = 0.1 } -- libs/reticule.lua widget default (faces the viewer)
-- Two components (CTD fix 2026-10-09): the idle crosshair is OUR widget instance and nothing else references it. With
-- one component swapping widgets (crosshair <-> countdown), the crosshair was unreferenced while the countdown showed,
-- the GC freed it, and SetWidget(<freed crosshair>) after the release crashed the game (log: Lua call_function into
-- game code on a freed object during the engine tick; get_full_name() still "works" on freed memory, so alive() could
-- not catch it). Now the crosshair lives in its own component for its whole life (the component's Widget reference
-- keeps it alive), the countdown gets a second component, and when the components go the crosshair is forgotten
-- (a fresh one is created with the next component).
-- crossComp / holdComp are remember() records ({ obj = component, ... }), see stillSame()
local cubeRet = { crossComp = nil, crosshair = nil, holdComp = nil, holdWidget = nil, holding = false }
_G.hrHoldReticuleActive = function() return cubeRet.holding end

-- destroys a component this script made (and the helper actor create_component_of_class spawned for it) - only if
-- it is provably still that component; otherwise the record is just dropped (it died with its level)
local function destroyComp(rec)
    if rec == nil or not stillSame(rec) then return end
    local c = rec.obj
    pcall(function() c:SetWidget(nil) end)
    pcall(function() uevrUtils.destroyComponent(c, true, true) end)
end

local function destroyHoldComponent()
    local rec = cubeRet.holdComp
    cubeRet.holdComp, cubeRet.holdWidget, cubeRet.holding = nil, nil, false
    destroyComp(rec)
end

local function destroyCubeReticule()
    destroyHoldComponent()
    local rec = cubeRet.crossComp
    cubeRet.crossComp, cubeRet.crosshair = nil, nil -- the crosshair is only kept alive by this component
    destroyComp(rec)
end

-- after a save load the records point at the old level: forget them without touching anything
local function forgetStaleReticule()
    if cubeRet.crossComp ~= nil and not stillSame(cubeRet.crossComp) then
        cubeRet.crossComp, cubeRet.crosshair = nil, nil
    end
    if cubeRet.holdComp ~= nil and not stillSame(cubeRet.holdComp) then
        cubeRet.holdComp, cubeRet.holdWidget, cubeRet.holding = nil, nil, false
    end
end

local function newWidgetComponent()
    local rec = nil
    pcall(function()
        local c = uevrUtils.create_component_of_class("Class /Script/UMG.WidgetComponent")
        if c == nil then return end
        if c.SetTwoSided ~= nil then c:SetTwoSided(true) end
        c.BoundsScale = 10 -- small components can be culled otherwise
        if _G.hrClearFirstPerson ~= nil then _G.hrClearFirstPerson(c, false) end
        rec = remember(c)
    end)
    return rec
end

-- Idle crosshair = an engine sphere with the unlit Widget3DPassThrough material (the reticule library's default mesh
-- reticule), NOT an instance of the game's W_Crosshair_Cube_C. Save-load bug 2026-10-14: our own instance of that
-- Blueprint widget (WidgetBlueprintLibrary:Create(world, class, player controller), shown on our component) was the
-- trigger of "no input after a save load, then no player spawned on the next load" - bisected down to this one
-- feature (on: bug within ~6 loads, off: 11+ clean). Nothing here creates game widgets any more.
local function ensureCrosshairComponent()
    if cubeRet.crossComp ~= nil and stillSame(cubeRet.crossComp) then return cubeRet.crossComp.obj end
    cubeRet.crossComp, cubeRet.crosshair = nil, nil
    local rec = nil
    pcall(function()
        local c = uevrUtils.createStaticMeshComponent(CROSSHAIR_MESH, { visible = true, collisionEnabled = false, tag = "hr_cube_crosshair" })
        if c == nil then return end
        local material = uevrUtils.getLoadedAsset(CROSSHAIR_MATERIAL)
        if uevrUtils.getValid(material) ~= nil then c:SetMaterial(0, material) end
        c.BoundsScale = 10 -- small components can be culled otherwise
        if c.SetCastShadow ~= nil then c:SetCastShadow(false) end
        if _G.hrClearFirstPerson ~= nil then _G.hrClearFirstPerson(c, false) end
        rec = remember(c)
    end)
    if rec == nil then return nil end
    cubeRet.crossComp = rec
    return rec.obj
end

-- countdown component: shows the game's HoldingWidget (game-owned, a new one per grab)
local function ensureHoldComponent(holdingWidget)
    if cubeRet.holdComp == nil or not stillSame(cubeRet.holdComp) then
        cubeRet.holdComp, cubeRet.holdWidget = newWidgetComponent(), nil
        if cubeRet.holdComp == nil then return nil end
    end
    local c = cubeRet.holdComp.obj
    if cubeRet.holdWidget ~= holdingWidget then
        pcall(function()
            if holdingWidget.RemoveFromViewport ~= nil and holdingWidget:IsInViewport() then holdingWidget:RemoveFromViewport() end
            c:SetWidget(holdingWidget)
        end)
        cubeRet.holdWidget = holdingWidget
    end
    return c
end

local function cubeReticuleTick()
    forgetStaleReticule()
    local loc, rot = nil, nil
    if configui.getValue("ret_enabled") ~= false and _G.hrCubeAim ~= nil then loc, rot = _G.hrCubeAim() end
    if loc == nil then
        if cubeRet.crossComp ~= nil or cubeRet.holdComp ~= nil then destroyCubeReticule() end
        return
    end
    local holdingWidget = nil
    pcall(function()
        local obj = uevr.api:get_local_pawn(0).CurrentTelekinesisObject
        if obj ~= nil and alive(obj.HoldingWidget) then holdingWidget = obj.HoldingWidget end
    end)

    local comp = nil
    if holdingWidget ~= nil then
        comp = ensureHoldComponent(holdingWidget)
        cubeRet.holding = comp ~= nil
        if cubeRet.crossComp ~= nil then local cross = cubeRet.crossComp.obj pcall(function() cross:SetVisibility(false) end) end
    else
        if cubeRet.holdComp ~= nil then destroyHoldComponent() end -- the countdown widget is the game's; let it go
        cubeRet.holding = false
        comp = ensureCrosshairComponent()
    end
    if comp == nil then return end

    local prefix = cubeRet.holding and "gc_ret_" or "ret_"
    local function num(id, default)
        local v = configui.getValue(prefix .. id)
        return type(v) == "number" and v or default
    end
    -- where the cube ray hits (or far along it), seen from the HMD
    local dir = kismet_math_library:GetForwardVector(rot)
    local target = nil
    pcall(function() target = uevrUtils.getTargetLocation(loc, dir, 0, { uevr.api:get_local_pawn(0) }, false, 10, THROW_TRACE_DISTANCE) end)
    if target == nil then target = { X = loc.X + dir.X * THROW_TRACE_DISTANCE, Y = loc.Y + dir.Y * THROW_TRACE_DISTANCE, Z = loc.Z + dir.Z * THROW_TRACE_DISTANCE } end
    local origin = controllers.getControllerLocation(2)
    if origin == nil then comp:SetVisibility(false) return end
    local toT = { X = target.X - origin.X, Y = target.Y - origin.Y, Z = target.Z - origin.Z }
    local dist = vlen(toT)
    if dist < 1 then comp:SetVisibility(false) return end
    local n = { X = toT.X / dist, Y = toT.Y / dist, Z = toT.Z / dist }
    local draw = math.min(num("distance", 1000.0), dist - 5.0)
    if draw < 5 then draw = 5 end
    local p = uevrUtils.vector(origin.X + n.X * draw, origin.Y + n.Y * draw, origin.Z + n.Z * draw)
    local r = kismet_math_library:Conv_VectorToRotator(uevrUtils.vector(n.X, n.Y, n.Z))
    comp:K2_SetWorldLocationAndRotation(p, r, false, reusable_hit_result, false)
    local s = num("size", 1.0)
    if not cubeRet.holding then
        local k = configui.getValue("gc_idle_ret_scale")
        s = s * (type(k) == "number" and k or 0.5)
    end
    if configui.getValue("ret_constant_size") ~= false then s = s * draw / RETICULE_SIZE_REFERENCE end
    if cubeRet.holding then
        comp:SetWorldScale3D(uevrUtils.vector(WIDGET_BASE_SCALE.X * s, WIDGET_BASE_SCALE.Y * s, WIDGET_BASE_SCALE.Z * s))
    else
        local m = CROSSHAIR_MESH_SCALE * s
        comp:SetWorldScale3D(uevrUtils.vector(m, m, m))
    end
    if cubeRet.holding then -- brightness is a widget tint; the idle crosshair is an unlit mesh
        local b = num("brightness", 1.0)
        pcall(function()
            local t = comp.TintColorAndOpacity
            if t == nil or math.abs(t.R - b) > 0.001 then comp:SetTintColorAndOpacity(uevrUtils.color_from_rgba(b, b, b, 1.0)) end
        end)
    end
    comp:SetVisibility(true)
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    local ok, err = pcall(cubeReticuleTick)
    if not ok then print("[genesis_cube] cube reticule: " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    -- components and widgets go with the level; never touch them again
    cubeRet.crossComp, cubeRet.crosshair, cubeRet.holdComp, cubeRet.holdWidget, cubeRet.holding = nil, nil, nil, nil, false
end)

print("[genesis_cube] loaded")
