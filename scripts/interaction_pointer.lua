-- Left-hand interaction pointer for Hellraiser (2026-10-19; ported from the Outer Worlds 2 profile's
-- interaction_pointer.lua and adapted).
--
-- Hellraiser picks its interaction target natively (InteractManager): the interactable whose COMP_Interact point is
-- within an angle cone of the player camera (Pawn.FPCameraActor, follows the control rotation) and on screen. The
-- pointer is a beam / reticule from the left controller; while it points at an interactable, the control rotation is
-- aimed from the game camera at that interactable's COMP_Interact point, so the game's own focus + prompt select it
-- and A picks it up / uses it as normal. On anything else the camera is left alone (it also drives HUD markers and the
-- walking direction).
--
-- Target selection is by ANGLE, not by a hit trace (MCP 2026-10-19): pickups (CorePickable, e.g. BP_HerbsItem_C) have
-- an overlap-only root sphere (OverlapAllDynamic, radius 32) and a NoCollision mesh, so no trace can hit them. The
-- COMP_Interact components near the player are collected once a second (and shortly after A is pressed); every tick
-- the one closest to the beam within "Selection angle" and range wins, if a Visibility line trace from the pointer
-- does not hit a wall first. Only cached positions are used between scans (no access to possibly picked-up objects).
--
-- input.lua normally writes the control rotation from the HMD every tick (aim method HEAD); while steering it is told
-- to stand down with setOverrideAimMethod(UEVR), the same mechanism montage.lua uses. Weapon aim is unaffected
-- (HellraiserAimFix aims from the barrel).
--
-- The beam is a thin CapsuleComponent owned by this script (direct reference, never exists()-gated: freshly created
-- components can fail exists() for a while - the OW2 leak trap), the reticule a wire SphereComponent.

local uevrUtils   = require('libs/uevr_utils')
local configui    = require('libs/configui')
local controllers = require('libs/controllers')
local input       = require('libs/input')

local POINTER_COLORS = {
    { label = "Blue",   hex = "#30A0FFFF" },
    { label = "Red",    hex = "#FF3030FF" },
    { label = "White",  hex = "#FFFFFFFF" },
    { label = "Green",  hex = "#30FF50FF" },
    { label = "Yellow", hex = "#FFE030FF" },
    { label = "Orange", hex = "#FF8C20FF" },
    { label = "Purple", hex = "#B050FFFF" },
    { label = "Cyan",   hex = "#30FFFFFF" },
}
local colorLabels = {}
for i, c in ipairs(POINTER_COLORS) do colorLabels[i] = c.label end

-- Hand pose while holding a grabbed item (2026-10-19): any grip pose from data/hands_parameters.json (the attachment
-- animation ids the hands wizard made: bottle, knife, ...; each has a left-hand "grip_left_weapon_<id>" pose). Make a
-- dedicated one in the wizard (e.g. "grab_item") and pick it here. Read once at load; new poses appear after a reset.
local GRAB_POSE_IDS = { "" }
local grabPoseLabels = { "None (normal grip / trigger)" }
pcall(function()
    local params = json.load_file("hands_parameters.json")
    local ids = {}
    for id, _ in pairs((params and params["attachments"]) or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        GRAB_POSE_IDS[#GRAB_POSE_IDS + 1] = id
        local label = params["attachments"][id]["label"]
        grabPoseLabels[#grabPoseLabels + 1] = (type(label) == "string" and label ~= "") and label or id
    end
end)
local defaultGrabPose = 1
for i, id in ipairs(GRAB_POSE_IDS) do
    if id == "grab_item" or id == "grab" then defaultGrabPose = i break end
    if id == "bottle" then defaultGrabPose = i end
end

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 6.6, label = "Interaction Pointer", layout = { -- own section below "UI (gameplay)" (6.5)
    { widgetType = "checkbox", id = "ip_enabled", label = "Left-hand pointer: point at items / doors and press A", initialValue = true },
    { widgetType = "combo", id = "ip_visibility", label = "Show pointer", initialValue = 1, selections = { "Always", "Only when on an item", "Never (targeting still works)" } },
    { widgetType = "combo", id = "ip_style", label = "Pointer style", initialValue = 3, selections = { "Beam", "Reticule", "Beam + reticule" } },
    { widgetType = "combo", id = "ip_color", label = "Pointer colour", initialValue = 1, selections = colorLabels },
    { widgetType = "combo", id = "ip_target_color", label = "Colour when on an item", initialValue = 4, selections = colorLabels },
    { widgetType = "slider_float", id = "ip_line_thickness", label = "Line thickness (brighter)", initialValue = 0.0, range = {0.0, 5.0} },
    { widgetType = "slider_float", id = "ip_reticle_size", label = "Reticule size", initialValue = 0.5, range = {0.1, 2.0} },
    { widgetType = "slider_float", id = "ip_range", label = "Pointer range (cm)", initialValue = 400.0, range = {100.0, 1500.0} },
    { widgetType = "slider_float", id = "ip_angle", label = "Selection angle (deg, how close to the beam an item must be)", initialValue = 6.0, range = {1.0, 20.0} },
    { widgetType = "checkbox", id = "ip_items_only", label = "Only target pickups (not doors / other interactables)", initialValue = false },
    { widgetType = "text", id = "ip_status", label = "Status: off" },
    { widgetType = "spacing" },
    { widgetType = "text", label = "-- Pointer angle / position (relative to the left controller; beam and targeting both follow)" },
    { widgetType = "slider_float", id = "ip_rot_pitch", label = "Pitch (up/down)", initialValue = 0.0, range = {-90.0, 90.0} },
    { widgetType = "slider_float", id = "ip_rot_yaw", label = "Yaw (left/right)", initialValue = 0.0, range = {-90.0, 90.0} },
    { widgetType = "slider_float", id = "ip_rot_roll", label = "Roll", initialValue = 0.0, range = {-180.0, 180.0} },
    { widgetType = "slider_float", id = "ip_off_x", label = "Offset forward (cm)", initialValue = 0.0, range = {-20.0, 20.0} },
    { widgetType = "slider_float", id = "ip_off_y", label = "Offset right (cm)", initialValue = 0.0, range = {-20.0, 20.0} },
    { widgetType = "slider_float", id = "ip_off_z", label = "Offset up (cm)", initialValue = 0.0, range = {-20.0, 20.0} },
    { widgetType = "spacing" },
    { widgetType = "text", label = "-- Grab pickups with the left trigger (reach for them, or point and pull), then A to take" },
    { widgetType = "checkbox", id = "ip_grab_enabled", label = "Grab pickups with the left trigger", initialValue = true },
    { widgetType = "slider_float", id = "ip_grab_reach", label = "Reach grab: hand within (cm)", initialValue = 25.0, range = {5.0, 60.0} },
    { widgetType = "slider_float", id = "ip_grab_point_dist", label = "Point grab: up to (cm, 0 = off)", initialValue = 300.0, range = {0.0, 800.0} },
    { widgetType = "slider_float", id = "ip_grab_fly_time", label = "Fly-to-hand time (s)", initialValue = 0.25, range = {0.05, 1.0} },
    { widgetType = "combo", id = "ip_grab_release", label = "On release", initialValue = 1, selections = { "Drop to the floor", "Put back where it was" } },
    { widgetType = "slider_float", id = "ip_grab_throw", label = "Release keeps the hand's motion (0 = straight down, 1 = full throw)", initialValue = 1.0, range = {0.0, 2.0} },
    { widgetType = "combo", id = "ip_grab_pose", label = "Left hand pose while holding an item (overrides grip / trigger)", initialValue = defaultGrabPose, selections = grabPoseLabels },
    { widgetType = "slider_float", id = "ip_grab_fwd", label = "Held item forward (cm)", initialValue = 6.0, range = {-20.0, 30.0} },
    { widgetType = "slider_float", id = "ip_grab_right", label = "Held item right (cm)", initialValue = 0.0, range = {-20.0, 20.0} },
    { widgetType = "slider_float", id = "ip_grab_up", label = "Held item up (cm)", initialValue = 0.0, range = {-20.0, 20.0} },
}})

local INTERACT_CLASS = "Class /Script/Project.COMP_Interact"
local PICKABLE_CLASS = "Class /Script/Project.CorePickable"
local SCAN_INTERVAL = 1.0       -- s between interactable scans
local SCAN_AFTER_PRESS = 0.3    -- s after A: rescan (the picked-up item is gone)
local LOS_INTERVAL = 0.2        -- s between line-of-sight re-checks of the current target
local MAX_BEAM = 3000.0         -- cm, beam length with nothing hit
local LENGTH_EPSILON = 0.5      -- cm of half-length change before the capsule is resized (rebuilds its render state)
local AIM_METHOD_POLL_INTERVAL = 0.25
local BTN_A = 0x1000

local function cfgNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end

local function addressOf(obj)
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or nil
end

-- ---------------------------------------------------------------------------------------------
-- Beam + reticule components
-- ---------------------------------------------------------------------------------------------
local capsule, capsuleParent = nil, nil
local appliedHalf, appliedOffsetKey, appliedVisible = nil, nil, nil
local reticle, reticleVisible, reticleRadius = nil, nil, nil
local appliedColorHex, appliedThickness = nil, nil
local lastStatus = nil

local function status(text)
    if text ~= lastStatus then
        lastStatus = text
        pcall(function() configui.setLabel("ip_status", "Status: " .. text) end)
    end
end

local function applyLook(component, hex)
    pcall(function() component.ShapeColor = uevrUtils.hexToColor(hex) end)
    pcall(function() component:SetLineThickness(cfgNum("ip_line_thickness", 0.0)) end)
end

local function destroyReticle()
    if reticle ~= nil then
        local r = reticle
        pcall(function() uevrUtils.destroyComponent(r, true, false) end)
    end
    reticle, reticleVisible, reticleRadius = nil, nil, nil
end

local function destroyPointer()
    if capsule ~= nil then
        local c = capsule
        pcall(function() c:DetachFromParent(false, false) end)
        pcall(function() uevrUtils.destroyComponent(c, true, false) end) -- destroys the owner actor too
    end
    capsule, capsuleParent = nil, nil
    appliedHalf, appliedOffsetKey, appliedVisible = nil, nil, nil
    destroyReticle()
    appliedColorHex = nil
end

local function ensureReticle(hex)
    if reticle ~= nil then return reticle end
    local ok, r = pcall(function() return uevrUtils.create_component_of_class("Class /Script/Engine.SphereComponent") end)
    if not ok or r == nil then return nil end
    pcall(function()
        r:SetGenerateOverlapEvents(false)
        r:SetCollisionEnabled(0)
        r:SetCastShadow(false)
        r:SetRenderInMainPass(true)
        r.bRenderInDepthPass = true
        r:SetSphereRadius(1.0, false)
        r:SetVisibility(false, false)
        r:SetHiddenInGame(false, false)
    end)
    applyLook(r, hex)
    reticle, reticleVisible, reticleRadius = r, false, 1.0
    return reticle
end

local function setReticleVisible(visible)
    if reticle == nil or reticleVisible == visible then return end
    pcall(function() reticle:SetVisibility(visible, false) end)
    reticleVisible = visible
end

-- reticule 1 cm in front of the target point (towards the pointer), radius scaled with distance (same apparent size)
local function updateReticle(origin, target, hex)
    local r = ensureReticle(hex)
    if r == nil then return end
    local dist = uevrUtils.vectorDistance(origin, target)
    if dist < 1.0 then return end
    local back = 1.0 / dist
    local pos = uevrUtils.vector(target.X + (origin.X - target.X) * back, target.Y + (origin.Y - target.Y) * back, target.Z + (origin.Z - target.Z) * back)
    pcall(function() r:K2_SetWorldLocation(pos, false, reusable_hit_result, true) end)
    local radius = math.max(0.3, dist * cfgNum("ip_reticle_size", 0.5) * 0.01)
    if reticleRadius == nil or math.abs(radius - reticleRadius) > reticleRadius * 0.05 then
        pcall(function() r:SetSphereRadius(radius, false) end)
        reticleRadius = radius
    end
    setReticleVisible(true)
end

local function ensurePointer(controller, hex)
    local parentAddress = addressOf(controller)
    if capsule ~= nil and parentAddress ~= nil and capsuleParent == parentAddress then return capsule end
    destroyPointer()
    local ok, c = pcall(function() return uevrUtils.create_component_of_class("Class /Script/Engine.CapsuleComponent") end)
    if not ok or c == nil then return nil end
    pcall(function()
        c:SetCapsuleSize(0.1, 0, true)
        c:SetGenerateOverlapEvents(false)
        c:SetCollisionEnabled(0)
        c:SetCastShadow(false)
        c:SetRenderInMainPass(true)
        c.bRenderInDepthPass = true
        c:SetCapsuleHalfHeight(25, false)
        c:K2_AttachTo(controller, uevrUtils.fname_from_string(""), 0, false)
        c.RelativeRotation = uevrUtils.rotator(90, 0, 0) -- capsule axis (Z) along the controller's forward (X)
        c.RelativeLocation = uevrUtils.vector(25, 0, 0)
        c:SetVisibility(true, false)
        c:SetHiddenInGame(false, false)
    end)
    applyLook(c, hex)
    capsule, capsuleParent = c, parentAddress
    appliedColorHex = hex
    return capsule
end

local function getPointerOffset()
    local rot = uevrUtils.rotator(cfgNum("ip_rot_pitch", 0), cfgNum("ip_rot_yaw", 0), cfgNum("ip_rot_roll", 0))
    local loc = uevrUtils.vector(cfgNum("ip_off_x", 0), cfgNum("ip_off_y", 0), cfgNum("ip_off_z", 0))
    return loc, rot
end

-- world-space pointer origin / direction: the controller transform with the slider offset applied (controller space)
local function getPointerRay(controllerLocation, controllerRotation)
    local offsetLoc, offsetRot = getPointerOffset()
    local f = kismet_math_library:GetForwardVector(controllerRotation)
    local r = kismet_math_library:GetRightVector(controllerRotation)
    local u = kismet_math_library:GetUpVector(controllerRotation)
    local ox, oy, oz = offsetLoc.X, offsetLoc.Y, offsetLoc.Z
    local origin = uevrUtils.vector(
        controllerLocation.X + f.X * ox + r.X * oy + u.X * oz,
        controllerLocation.Y + f.Y * ox + r.Y * oy + u.Y * oz,
        controllerLocation.Z + f.Z * ox + r.Z * oy + u.Z * oz)
    local worldRot = kismet_math_library:ComposeRotators(offsetRot, controllerRotation)
    return origin, kismet_math_library:GetForwardVector(worldRot)
end

-- capsule axis = local Z: (90,0,0) turns it onto X, then the slider rotation; centred half its length along it.
-- Resize / re-transform only on change (a resize rebuilds the render state).
local function setPointerLength(c, length)
    local half = math.max(length * 0.5, 1.0)
    local offsetLoc, offsetRot = getPointerOffset()
    local offsetKey = string.format("%.2f,%.2f,%.2f,%.2f,%.2f,%.2f", offsetLoc.X, offsetLoc.Y, offsetLoc.Z, offsetRot.Pitch, offsetRot.Yaw, offsetRot.Roll)
    local lengthChanged = appliedHalf == nil or math.abs(half - appliedHalf) >= LENGTH_EPSILON
    if not lengthChanged and offsetKey == appliedOffsetKey then return end
    pcall(function()
        if lengthChanged then
            c:SetCapsuleHalfHeight(half, false)
            appliedHalf = half
        end
        local h = appliedHalf
        local f = kismet_math_library:GetForwardVector(offsetRot)
        local relLoc = uevrUtils.vector(offsetLoc.X + f.X * h, offsetLoc.Y + f.Y * h, offsetLoc.Z + f.Z * h)
        local relRot = kismet_math_library:ComposeRotators(uevrUtils.rotator(90, 0, 0), offsetRot)
        c:K2_SetRelativeLocationAndRotation(relLoc, relRot, false, reusable_hit_result, false)
        appliedOffsetKey = offsetKey
    end)
end

-- On an item the beam snaps onto it (2026-10-19): the item is chosen by angle, so it can be a few degrees off the
-- controller's ray - a straight beam then ended beside the item while the reticule sat on it. The capsule is placed
-- in world space from the pointer origin to the target; the relative transform is re-applied when it leaves.
local function setPointerToTarget(c, origin, target)
    local dx, dy, dz = target.X - origin.X, target.Y - origin.Y, target.Z - origin.Z
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    if length < 1.0 then return end
    local half = math.max(length * 0.5, 1.0)
    pcall(function()
        if appliedHalf == nil or math.abs(half - appliedHalf) >= LENGTH_EPSILON then
            c:SetCapsuleHalfHeight(half, false)
            appliedHalf = half
        end
        local mid = uevrUtils.vector(origin.X + dx * 0.5, origin.Y + dy * 0.5, origin.Z + dz * 0.5)
        local rot = kismet_math_library:MakeRotFromZ(uevrUtils.vector(dx / length, dy / length, dz / length))
        c:K2_SetWorldLocationAndRotation(mid, rot, false, reusable_hit_result, false)
    end)
    appliedOffsetKey = nil -- back on the controller ray: setPointerLength re-applies the relative transform
end

local function setPointerVisible(c, visible)
    if appliedVisible == visible then return end
    pcall(function() c:SetVisibility(visible, false) end)
    appliedVisible = visible
end

-- colour / thickness: a colour change rebuilds both components (ShapeColor only reaches the renderer on a render-state
-- rebuild); thickness applies live
local function updateLook(hex)
    if appliedColorHex ~= nil and appliedColorHex ~= hex then destroyPointer() end
    local thickness = cfgNum("ip_line_thickness", 0.0)
    if thickness ~= appliedThickness then
        appliedThickness = thickness
        if capsule ~= nil then pcall(function() capsule:SetLineThickness(thickness) end) end
        if reticle ~= nil then pcall(function() reticle:SetLineThickness(thickness) end) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Interactable candidates (COMP_Interact points near the player)
-- ---------------------------------------------------------------------------------------------
local candidates = {}   -- { X, Y, Z, name, pickup }
local nextScan = 0
local interactClass, pickableClass = nil, nil

-- Locked / closed cabinets (2026-10-19, MCP): loot cabinets (BP_ShelfLootContainer_C, C++ ShelfLootContainer - the
-- lockpick puzzles sit in them) keep their items behind glass doors; the items themselves stay normally interactable
-- (COMP_Interact TaskState 1, visibility conditions true), the cabinet holds the state: bDoorLocked, bDoorLLOpened /
-- bDoorLROpened (doors), bLeftDrawerOpened / bRightDrawerOpened + LeftDrawerItems / RightDrawerItems (drawers). A
-- pickup inside a cabinet's bounds is skipped by the pointer and the grab unless its compartment is open: listed in a
-- drawer -> that drawer open; otherwise -> a door open. The cabinet's own doors / drawers stay targetable.
local CONTAINER_CLASS = "Class /Script/Project.ShelfLootContainer"
local BOUNDS_PAD = 2.0

local function addressSet(list)
    local set = {}
    pcall(function()
        for _, a in ipairs(list or {}) do
            local addr = addressOf(a)
            if addr ~= nil then set[addr] = true end
        end
    end)
    return set
end

local function scanContainers(ploc, reach2)
    local out = {}
    for _, c in ipairs(uevrUtils.find_all_of(CONTAINER_CLASS, false) or {}) do
        pcall(function()
            local l = c:K2_GetActorLocation()
            local dx, dy, dz = l.X - ploc.X, l.Y - ploc.Y, l.Z - ploc.Z
            if dx * dx + dy * dy + dz * dz > reach2 then return end
            local origin, extent = uevrUtils.vector(0, 0, 0), uevrUtils.vector(0, 0, 0)
            c:GetActorBounds(false, origin, extent, false)
            out[#out + 1] = {
                ox = origin.X, oy = origin.Y, oz = origin.Z, ex = extent.X + BOUNDS_PAD, ey = extent.Y + BOUNDS_PAD, ez = extent.Z + BOUNDS_PAD,
                doorsOpen = c.bDoorLLOpened == true or c.bDoorLROpened == true,
                leftOpen = c.bLeftDrawerOpened == true, rightOpen = c.bRightDrawerOpened == true,
                left = addressSet(c.LeftDrawerItems), right = addressSet(c.RightDrawerItems),
            }
        end)
    end
    return out
end

-- true if the pickup (actor location + address) sits in a closed compartment of one of the cabinets
local function inClosedContainer(containers, x, y, z, ownerAddress)
    for _, k in ipairs(containers) do
        if ownerAddress ~= nil and k.left[ownerAddress] then return not k.leftOpen end
        if ownerAddress ~= nil and k.right[ownerAddress] then return not k.rightOpen end
        if math.abs(x - k.ox) <= k.ex and math.abs(y - k.oy) <= k.ey and math.abs(z - k.oz) <= k.ez then
            return not k.doorsOpen
        end
    end
    return false
end

local function scanCandidates(pawn)
    local out = {}
    local ok, ploc = pcall(function() return pawn:K2_GetActorLocation() end)
    if not ok or ploc == nil then candidates = out return end
    local reach = cfgNum("ip_range", 400.0) + 200.0
    local reach2 = reach * reach
    if pickableClass == nil then pickableClass = uevrUtils.get_class(PICKABLE_CLASS) end
    local containers = {}
    pcall(function() containers = scanContainers(ploc, (reach + 300.0) * (reach + 300.0)) end)
    for _, comp in ipairs(uevrUtils.find_all_of(INTERACT_CLASS, false) or {}) do
        pcall(function()
            local owner = comp:GetOwner()
            if owner == nil or owner == pawn then return end
            local loc = comp:K2_GetComponentLocation()
            if loc == nil then return end
            local dx, dy, dz = loc.X - ploc.X, loc.Y - ploc.Y, loc.Z - ploc.Z
            if dx * dx + dy * dy + dz * dz > reach2 then return end
            if owner.bHidden == true then return end
            local pickup = pickableClass ~= nil and owner:is_a(pickableClass) == true
            local name = owner:get_fname():to_string():gsub("_C_%d+$", ""):gsub("^BP_", "")
            local rl = owner:K2_GetActorLocation()
            if pickup and #containers > 0 and inClosedContainer(containers, rl.X, rl.Y, rl.Z, addressOf(owner)) then return end
            out[#out + 1] = { X = loc.X, Y = loc.Y, Z = loc.Z, name = name, pickup = pickup, owner = owner, comp = comp,
                RX = rl.X, RY = rl.Y, RZ = rl.Z }
        end)
    end
    candidates = out
end

-- candidate closest to the beam within the selection angle and range (pure Lua on cached positions)
local function pickCandidate(origin, dir)
    local range = cfgNum("ip_range", 400.0)
    local minCos = math.cos(math.rad(cfgNum("ip_angle", 6.0)))
    local itemsOnly = configui.getValue("ip_items_only") == true
    local best, bestCos, bestDist = nil, minCos, nil
    for _, c in ipairs(candidates) do
        if not itemsOnly or c.pickup then
            local dx, dy, dz = c.X - origin.X, c.Y - origin.Y, c.Z - origin.Z
            local d = math.sqrt(dx * dx + dy * dy + dz * dz)
            if d > 1 and d <= range then
                local cosA = (dx * dir.X + dy * dir.Y + dz * dir.Z) / d
                if cosA >= bestCos then best, bestCos, bestDist = c, cosA, d end
            end
        end
    end
    return best, bestDist
end

-- Visibility line trace between two points (plain Lua coordinates). uevrUtils.getTargetLocation is NOT used: it
-- adds / multiplies its vector arguments with + and *, which uevrUtils.vector structs do not support - every call
-- errored inside the pcalls (2026-10-19: line of sight never checked, beam never stopped at walls, drops never found
-- the floor). Returns the hit location { X, Y, Z } or nil.
local function traceLine(from, to, ignore)
    local world = uevrUtils.get_world()
    if world == nil then return nil end
    local hit = kismet_system_library:LineTraceSingle(world, uevrUtils.vector(from.X, from.Y, from.Z), uevrUtils.vector(to.X, to.Y, to.Z),
        0, false, ignore or {}, 0, reusable_hit_result, true, zero_color, zero_color, 0.0)
    if hit then
        local l = reusable_hit_result.Location
        return { X = l.X, Y = l.Y, Z = l.Z }
    end
    return nil
end

-- line of sight from the pointer to the item (its actor location, the middle of the pickup sphere - the COMP_Interact
-- point can sit below a table top): blocked if something is hit more than 30 cm before it
local los = { target = nil, clear = false, nextCheck = 0 }
local function lineOfSightClear(origin, target, dist, pawn, now)
    if los.target == target and now < los.nextCheck then return los.clear end
    local clear = true
    pcall(function()
        local to = target.RX ~= nil and { X = target.RX, Y = target.RY, Z = target.RZ } or target
        local d = uevrUtils.vectorDistance(origin, uevrUtils.vector(to.X, to.Y, to.Z))
        local hit = traceLine(origin, to, { pawn })
        if hit ~= nil and uevrUtils.vectorDistance(origin, uevrUtils.vector(hit.X, hit.Y, hit.Z)) < d - 30.0 then clear = false end
    end)
    los.target, los.clear, los.nextCheck = target, clear, now + LOS_INTERVAL
    return clear
end

-- beam end with no target: first Visibility hit along the ray, else MAX_BEAM
local function beamEnd(origin, dir, pawn)
    local far = { X = origin.X + dir.X * MAX_BEAM, Y = origin.Y + dir.Y * MAX_BEAM, Z = origin.Z + dir.Z * MAX_BEAM }
    local hit = nil
    pcall(function() hit = traceLine(origin, far, { pawn }) end)
    if hit ~= nil then return uevrUtils.vector(hit.X, hit.Y, hit.Z), true end
    return uevrUtils.vector(far.X, far.Y, far.Z), false
end

-- ---------------------------------------------------------------------------------------------
-- Steering
-- ---------------------------------------------------------------------------------------------
local steering = false
local nextAimMethodPoll, aimMethodOverridden = 0, false

local function stopSteering()
    if steering then
        steering = false
        pcall(function() input.setOverrideAimMethod(nil) end)
    end
end

local function hideAll()
    if capsule ~= nil then setPointerVisible(capsule, false) end
    setReticleVisible(false)
end

local function blockedReason()
    if _G.hrIsInMenu ~= nil and _G.hrIsInMenu() then return "menu" end
    if _G.hrCutsceneActive == true then return "cutscene" end
    if _G.hrIsVideoPlaying ~= nil and _G.hrIsVideoPlaying() then return "video" end
    if _G.hrIsInFocusPuzzle ~= nil and _G.hrIsInFocusPuzzle() then return "puzzle / inspection" end
    if _G.hrIsSeated ~= nil and _G.hrIsSeated() then return "seated" end
    if _G.isTwoHandingActive == true then return "two-handing" end
    if _G.hrCubeAim ~= nil and _G.hrCubeAim() ~= nil then return "cube in the left hand" end
    return nil
end

-- A pressed: the picked-up item disappears - rescan soon so it is not targeted any more
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil or not steering then return end
    if (state.Gamepad.wButtons & BTN_A) ~= 0 then
        local soon = os.clock() + SCAN_AFTER_PRESS
        if nextScan > soon then nextScan = soon end
    end
end, 15)

-- ---------------------------------------------------------------------------------------------
-- Grabbing pickups with the left trigger (2026-10-19)
--
-- Pickups (CorePickable: crafting items, ammo, herbs, world weapons...) are movable actors without physics (MCP:
-- root SphereCollision overlap-only, mesh NoCollision, Mobility Movable). Pull the left trigger with the hand near one
-- (reach) or with the pointer on one (point, within ip_grab_point_dist): the item flies into the left hand (eased over
-- ip_grab_fly_time, keeping its rotation relative to the hand at the moment of the grab, its mesh centre at the hold
-- offset) and is then attached to the left controller. While it is held the game camera is steered at its
-- COMP_Interact point (pickups interact from 200 cm), so the game focuses it and A takes it as normal. Releasing the
-- trigger drops it to the floor below (upright as it was placed) or puts it back (panel). The item disappearing
-- (taken, destroyed) ends the hold without touching it.
-- The trigger press that starts a grab is kept from the game and from two-handing (which also grabs with the left
-- trigger by default) until it is released; the hand's own trigger pose still sees it (hands_animation runs first).
-- ---------------------------------------------------------------------------------------------
local LT_THRESHOLD = 100
local held = nil              -- the item in the hand (see startHold)
local grabCandidate = nil     -- what a trigger pull would grab now (set by the tick, read by the input callback)
local triggerDown, triggerPressed, triggerReleased, swallowTrigger = false, false, false, false

local function exists(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return UEVR_UObjectHook.exists(obj) end)
    return ok and r == true
end

local function v3(t) return uevrUtils.vector(t.X, t.Y, t.Z) end
local function copyV(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function copyR(r) return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end

local function findMesh(root)
    local mesh = nil
    pcall(function()
        for _, child in ipairs(root.AttachChildren or {}) do
            if child.StaticMesh ~= nil or child.SkeletalMesh ~= nil then mesh = child break end
        end
    end)
    return mesh
end

-- world centre of the mesh's bounding box + the lowest world Z of its corners
local function meshCenterAndBottom(mesh)
    local mn, mx = uevrUtils.vector(0, 0, 0), uevrUtils.vector(0, 0, 0)
    mesh:GetLocalBounds(mn, mx)
    local T = mesh:K2_GetComponentToWorld()
    local c = kismet_math_library:TransformLocation(T, uevrUtils.vector((mn.X + mx.X) * 0.5, (mn.Y + mx.Y) * 0.5, (mn.Z + mx.Z) * 0.5))
    local minZ = math.huge
    for _, x in ipairs({ mn.X, mx.X }) do
        for _, y in ipairs({ mn.Y, mx.Y }) do
            for _, z in ipairs({ mn.Z, mx.Z }) do
                local p = kismet_math_library:TransformLocation(T, uevrUtils.vector(x, y, z))
                if p.Z < minZ then minZ = p.Z end
            end
        end
    end
    return copyV(c), minZ
end

-- root transform that puts the item's mesh centre at the hold point with its grab-time rotation relative to the hand
local function holdTarget(controller, h)
    local T = controller:K2_GetComponentToWorld()
    local cl = controller:K2_GetComponentLocation()
    local cr = controller:K2_GetComponentRotation()
    local f = kismet_math_library:GetForwardVector(cr)
    local r = kismet_math_library:GetRightVector(cr)
    local u = kismet_math_library:GetUpVector(cr)
    local fw, rt, up = cfgNum("ip_grab_fwd", 6.0), cfgNum("ip_grab_right", 0.0), cfgNum("ip_grab_up", 0.0)
    local hand = { X = cl.X + f.X * fw + r.X * rt + u.X * up, Y = cl.Y + f.Y * fw + r.Y * rt + u.Y * up, Z = cl.Z + f.Z * fw + r.Z * rt + u.Z * up }
    local rootRot = kismet_math_library:TransformRotation(T, uevrUtils.rotator(h.relRot.Pitch, h.relRot.Yaw, h.relRot.Roll))
    local R = kismet_math_library:MakeTransform(uevrUtils.vector(0, 0, 0), rootRot, v3(h.rootScale))
    local off = kismet_math_library:TransformDirection(R, v3(h.meshLocal))
    return uevrUtils.vector(hand.X - off.X, hand.Y - off.Y, hand.Z - off.Z), rootRot
end

-- While an item is held the left hand shows the chosen pose and its grip / trigger / thumb input is locked
-- (libs/hands_animation: setHoldingAttachment = the attachment-style "grip_left_weapon_<id>" pose, setInputLocked =
-- the same per-hand lock two_handed.lua uses). Cleared when the hold ends: the hand returns to its normal state.
local handsAnimation = nil
pcall(function() handsAnimation = require('libs/hands_animation') end)
local grabPoseActive = false

local function applyGrabPose()
    local id = GRAB_POSE_IDS[configui.getValue("ip_grab_pose") or defaultGrabPose]
    if handsAnimation == nil or id == nil or id == "" then return end
    pcall(function()
        handsAnimation.setInputLocked(Handed.Left, true)
        handsAnimation.setHoldingAttachment(Handed.Left, id)
    end)
    grabPoseActive = true
end

local function clearGrabPose()
    if not grabPoseActive or handsAnimation == nil then return end
    grabPoseActive = false
    pcall(function()
        handsAnimation.setInputLocked(Handed.Left, false)
        handsAnimation.setHoldingAttachment(Handed.Left, nil)
    end)
end

local function startHold(entry, controller, flyTime)
    if entry == nil or not exists(entry.owner) then return false end
    local ok, err = pcall(function()
        local owner, comp = entry.owner, entry.comp
        if owner.bHidden == true then return end
        local root = owner.RootComponent
        if root == nil then return end
        local origLoc, origRot = owner:K2_GetActorLocation(), owner:K2_GetActorRotation()
        local mesh = findMesh(root)
        local center, minZ = copyV(origLoc), origLoc.Z
        if mesh ~= nil then center, minZ = meshCenterAndBottom(mesh) end
        local meshLocal = kismet_math_library:InverseTransformLocation(root:K2_GetComponentToWorld(), v3(center))
        local relRot = kismet_math_library:InverseTransformRotation(controller:K2_GetComponentToWorld(), origRot)
        held = {
            owner = owner, root = root, comp = comp, name = entry.name,
            relRot = copyR(relRot), meshLocal = copyV(meshLocal), rootScale = copyV(root:K2_GetComponentScale()),
            origLoc = copyV(origLoc), origRot = copyR(origRot),
            rootFromBottom = { X = origLoc.X - center.X, Y = origLoc.Y - center.Y, Z = origLoc.Z - minZ },
            flyStart = os.clock(), flyTime = flyTime, startLoc = copyV(origLoc), startRot = copyR(origRot), attached = false,
        }
    end)
    if not ok then print("[interaction_pointer] grab: " .. tostring(err)) held = nil end
    if held ~= nil then applyGrabPose() end
    return held ~= nil
end

local function heldGone(h)
    if not exists(h.owner) then return true end
    local gone = true
    pcall(function() gone = h.owner.bActorIsBeingDestroyed == true or h.owner.bHidden == true end)
    return gone
end

local function updateHeld(controller)
    local h = held
    if h.attached then return end
    local loc, rot = holdTarget(controller, h)
    local a = h.flyTime > 0 and math.min(1.0, (os.clock() - h.flyStart) / h.flyTime) or 1.0
    if a < 1.0 then
        local e = a * a * (3 - 2 * a)
        local sl = h.startLoc
        local p = uevrUtils.vector(sl.X + (loc.X - sl.X) * e, sl.Y + (loc.Y - sl.Y) * e, sl.Z + (loc.Z - sl.Z) * e)
        local rr = kismet_math_library:RLerp(uevrUtils.rotator(h.startRot.Pitch, h.startRot.Yaw, h.startRot.Roll), rot, e, true)
        h.owner:K2_SetActorLocationAndRotation(p, rr, false, reusable_hit_result, true)
    else
        h.owner:K2_SetActorLocationAndRotation(loc, rot, false, reusable_hit_result, true)
        -- on the controller from now on (KeepWorld): follows the hand smoothly, no per-tick moves
        h.root:K2_AttachToComponent(controller, uevrUtils.fname_from_string(""), 1, 1, 1, false)
        h.attached = true
    end
end

-- ---------------------------------------------------------------------------------------------
-- Falling items (2026-10-19): a dropped item leaves the hand with the hand's velocity (x ip_grab_throw), falls with
-- gravity, turns back upright (the rotation it was placed with) over FALL_UPRIGHT_S, and lands where the path of its
-- bottom point first meets a surface (Visibility trace per step). The VR hands / controllers / IK rig and the player
-- are ignored by those traces. No landing within FALL_MAX_S (fell out of the world): put back where it was picked up.
-- ---------------------------------------------------------------------------------------------
local GRAVITY = 980.0
local FALL_UPRIGHT_S = 0.35
local FALL_MAX_S = 4.0
local fallers = {}
local handVel = { X = 0, Y = 0, Z = 0 }
local handPrev = nil  -- { X, Y, Z, t }

local function trackHandVelocity(controller)
    local now = os.clock()
    local ok, l = pcall(function() return controller:K2_GetComponentLocation() end)
    if not ok or l == nil then return end
    if handPrev ~= nil then
        local dt = now - handPrev.t
        if dt > 0.001 and dt < 0.1 then
            local k = 0.5 -- smoothing
            handVel.X = handVel.X + ((l.X - handPrev.X) / dt - handVel.X) * k
            handVel.Y = handVel.Y + ((l.Y - handPrev.Y) / dt - handVel.Y) * k
            handVel.Z = handVel.Z + ((l.Z - handPrev.Z) / dt - handVel.Z) * k
        end
    end
    handPrev = { X = l.X, Y = l.Y, Z = l.Z, t = now }
end

local function dropIgnoreList(pawn, owner)
    local ignore = { pawn, owner }
    pcall(function()
        for _, hand in ipairs({ Handed.Left, Handed.Right }) do
            local c = controllers.getController(hand, true)
            if c ~= nil and c:GetOwner() ~= nil then ignore[#ignore + 1] = c:GetOwner() end
        end
    end)
    pcall(function()
        local hands = require('libs/hands')
        for _, hand in ipairs({ Handed.Left, Handed.Right }) do
            local m = hands.getHandComponent(hand)
            if m ~= nil and m:GetOwner() ~= nil then ignore[#ignore + 1] = m:GetOwner() end
        end
    end)
    pcall(function()
        local ik = require('libs/ik')
        for _, i in ipairs({ 0, 1 }) do
            local m = ik.getCurrentMesh(i)
            if m ~= nil and m:GetOwner() ~= nil then ignore[#ignore + 1] = m:GetOwner() end
        end
    end)
    return ignore
end

local function startFall(h, pawn)
    local cur = h.owner:K2_GetActorLocation()
    local rot = h.owner:K2_GetActorRotation()
    local k = cfgNum("ip_grab_throw", 1.0)
    local now = os.clock()
    fallers[#fallers + 1] = {
        owner = h.owner, rb = h.rootFromBottom, origLoc = h.origLoc,
        pos = { X = cur.X, Y = cur.Y, Z = cur.Z }, vel = { X = handVel.X * k, Y = handVel.Y * k, Z = handVel.Z * k },
        startRot = copyR(rot), targetRot = h.origRot, t0 = now, last = now, ignore = dropIgnoreList(pawn, h.owner),
    }
end

local function updateFallers()
    if #fallers == 0 then return end
    local now = os.clock()
    local keep = {}
    for _, fl in ipairs(fallers) do
        local done = true
        pcall(function()
            if not exists(fl.owner) then return end
            local age = now - fl.t0
            local tr = fl.targetRot
            if age > FALL_MAX_S then
                fl.owner:K2_SetActorLocationAndRotation(v3(fl.origLoc), uevrUtils.rotator(tr.Pitch, tr.Yaw, tr.Roll), false, reusable_hit_result, true)
                return
            end
            local dt = math.min(now - fl.last, 0.05)
            fl.last = now
            local p, v, rb = fl.pos, fl.vel, fl.rb
            local np = { X = p.X + v.X * dt, Y = p.Y + v.Y * dt, Z = p.Z + v.Z * dt - 0.5 * GRAVITY * dt * dt }
            v.Z = v.Z - GRAVITY * dt
            -- bottom point path this step (bottom offset of the upright item)
            local fromB = { X = p.X - rb.X, Y = p.Y - rb.Y, Z = p.Z - rb.Z + 2.0 }
            local toB = { X = np.X - rb.X, Y = np.Y - rb.Y, Z = np.Z - rb.Z }
            local hit = traceLine(fromB, toB, fl.ignore)
            local a = math.min(1.0, age / FALL_UPRIGHT_S)
            a = a * a * (3 - 2 * a)
            local sr = fl.startRot
            if hit ~= nil then
                fl.owner:K2_SetActorLocationAndRotation(uevrUtils.vector(hit.X + rb.X, hit.Y + rb.Y, hit.Z + rb.Z + 0.5),
                    uevrUtils.rotator(tr.Pitch, tr.Yaw, tr.Roll), false, reusable_hit_result, true)
                return
            end
            local rr = kismet_math_library:RLerp(uevrUtils.rotator(sr.Pitch, sr.Yaw, sr.Roll), uevrUtils.rotator(tr.Pitch, tr.Yaw, tr.Roll), a, true)
            fl.owner:K2_SetActorLocationAndRotation(uevrUtils.vector(np.X, np.Y, np.Z), rr, false, reusable_hit_result, true)
            fl.pos = np
            done = false
        end)
        if not done then keep[#keep + 1] = fl end
    end
    fallers = keep
end

local function releaseHeld(pawn)
    local h = held
    held = nil
    clearGrabPose()
    if h == nil or not exists(h.owner) then return end
    pcall(function() h.owner:K2_DetachFromActor(1, 1, 1) end)
    pcall(function()
        local origRot = uevrUtils.rotator(h.origRot.Pitch, h.origRot.Yaw, h.origRot.Roll)
        if configui.getValue("ip_grab_release") == 2 then
            h.owner:K2_SetActorLocationAndRotation(v3(h.origLoc), origRot, false, reusable_hit_result, true)
            return
        end
        -- drop: falls from the hand (see fallers below)
        startFall(h, pawn)
    end)
end

-- forget the hold without moving the item (it is being taken, or the world is going away)
local function forgetHeld(detach)
    local h = held
    held = nil
    clearGrabPose()
    if detach and h ~= nil and exists(h.owner) then pcall(function() h.owner:K2_DetachFromActor(1, 1, 1) end) end
end

-- what a trigger pull would grab: a pickup within reach of the hand (nearest), else the pointer's pickup target
local function findGrabCandidate(handLoc, pointerTarget, pointerDist)
    if configui.getValue("ip_grab_enabled") == false then return nil, nil end
    local reach = cfgNum("ip_grab_reach", 25.0)
    local best, bestD = nil, reach
    for _, c in ipairs(candidates) do
        if c.pickup and c.owner ~= nil then
            local d1 = uevrUtils.vectorDistance(handLoc, uevrUtils.vector(c.X, c.Y, c.Z))
            local d2 = c.RX ~= nil and uevrUtils.vectorDistance(handLoc, uevrUtils.vector(c.RX, c.RY, c.RZ)) or d1
            local d = math.min(d1, d2)
            if d <= bestD then best, bestD = c, d end
        end
    end
    if best ~= nil then return best, "reach" end
    local pointDist = cfgNum("ip_grab_point_dist", 300.0)
    if pointerTarget ~= nil and pointerTarget.pickup and pointerTarget.owner ~= nil and pointDist > 0 and pointerDist ~= nil and pointerDist <= pointDist then
        return pointerTarget, "point"
    end
    return nil, nil
end

-- left trigger: edges for the tick; the press that starts a grab (and the whole hold) is kept from the game, from
-- two-handing AND from the hand animation. Priority 12: BEFORE hands_animation (10) - at 7 the hand handler had
-- already started its 0.1 s left-trigger finger lerp on the grab press, which then finished on top of the grab pose
-- (index finger curled, 2026-10-19). The left hand's input is also locked right here when a grab pose is set, so
-- nothing animates it between the press and the hold starting on the next tick.
local pressLocked = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    local down = state.Gamepad.bLeftTrigger > LT_THRESHOLD
    if down and not triggerDown then
        if held == nil and grabCandidate ~= nil then
            triggerPressed = true
            swallowTrigger = true
            local id = GRAB_POSE_IDS[configui.getValue("ip_grab_pose") or defaultGrabPose]
            if handsAnimation ~= nil and id ~= nil and id ~= "" then
                pcall(function() handsAnimation.setInputLocked(Handed.Left, true) end)
                pressLocked = true
            end
        end
    elseif not down and triggerDown then
        if held ~= nil then triggerReleased = true end
    end
    triggerDown = down
    if swallowTrigger or held ~= nil then
        state.Gamepad.bLeftTrigger = 0
        if not down then swallowTrigger = false end
    end
end, 12)

local function steerAt(pc, point)
    local cm = pc.PlayerCameraManager
    local camLocation = cm ~= nil and cm:GetCameraLocation() or nil
    if camLocation == nil then return false end
    local look = kismet_math_library:FindLookAtRotation(camLocation, point)
    look.Roll = 0
    if not steering then
        steering = true
        input.setOverrideAimMethod(input.AimMethod.UEVR)
    end
    pc:SetControlRotation(look)
    return true
end

-- per tick while an item is held; returns true when the hold owns this tick
local function tickHeld(pawn, pc, controller)
    if held == nil then return false end
    if heldGone(held) then
        forgetHeld(true)
        triggerReleased = false
        status("item taken")
        return false
    end
    if triggerReleased then
        triggerReleased = false
        releaseHeld(pawn)
        stopSteering()
        status("item released")
        return true
    end
    if held.velReset == nil then -- new hold: start the hand velocity fresh
        held.velReset = true
        handPrev = nil
        handVel.X, handVel.Y, handVel.Z = 0, 0, 0
    end
    trackHandVelocity(controller)
    updateHeld(controller)
    hideAll()
    local point = nil
    pcall(function() point = held.comp:K2_GetComponentLocation() end)
    if point == nil then pcall(function() point = held.owner:K2_GetActorLocation() end) end
    if point ~= nil then steerAt(pc, point) end
    status("holding " .. tostring(held.name) .. " - press A to take, let go to " .. (configui.getValue("ip_grab_release") == 2 and "put it back" or "drop it"))
    return true
end

local function tick()
    if configui.getValue("ip_enabled") == false then
        if held ~= nil then releaseHeld(uevr.api:get_local_pawn(0)) end
        grabCandidate = nil
        stopSteering()
        if capsule ~= nil then destroyPointer() end
        candidates = {}
        status("off")
        return
    end

    local pawn = uevr.api:get_local_pawn(0)
    local pc = uevr.api:get_player_controller(0)
    local controller = controllers.getController(Handed.Left, true)
    if pawn == nil or pc == nil or controller == nil then
        stopSteering()
        hideAll()
        status("waiting for pawn / controller")
        return
    end

    local reason = blockedReason()
    if reason ~= nil then
        if held ~= nil then releaseHeld(pawn) end
        grabCandidate = nil
        stopSteering()
        hideAll()
        status("paused (" .. reason .. ")")
        return
    end

    -- a montage currently owns the aim method (interactions, cutscenes): stay out of its way
    local now = os.clock()
    if now >= nextAimMethodPoll then
        nextAimMethodPoll = now + AIM_METHOD_POLL_INTERVAL
        aimMethodOverridden = uevrUtils.getUEVRParam_int("VR_AimMethod", 0) ~= 0
    end
    if aimMethodOverridden then
        if held ~= nil then releaseHeld(pawn) end
        grabCandidate = nil
        stopSteering()
        hideAll()
        status("paused (montage aim override)")
        return
    end

    if tickHeld(pawn, pc, controller) then return end

    if now >= nextScan then
        nextScan = now + SCAN_INTERVAL
        scanCandidates(pawn)
    end

    local controllerLocation = controllers.getControllerLocation(Handed.Left)
    local controllerRotation = controllers.getControllerRotation(Handed.Left)
    if controllerLocation == nil or controllerRotation == nil then stopSteering() return end
    local origin, dir = getPointerRay(controllerLocation, controllerRotation)

    local target, targetDist = pickCandidate(origin, dir)
    if target ~= nil and not lineOfSightClear(origin, target, targetDist, pawn, now) then target = nil end

    -- grab: what a left-trigger pull would take now; a pull since the last tick starts it
    local grabEntry, grabKind = findGrabCandidate(controllerLocation, target, targetDist)
    grabCandidate = grabEntry
    if triggerPressed then
        triggerPressed = false
        local started = grabEntry ~= nil and startHold(grabEntry, controller, grabKind == "reach" and math.min(0.1, cfgNum("ip_grab_fly_time", 0.25)) or cfgNum("ip_grab_fly_time", 0.25))
        if pressLocked and not grabPoseActive then -- the grab did not start: give the hand its input back
            pcall(function() handsAnimation.setInputLocked(Handed.Left, false) end)
        end
        pressLocked = false
        if started then
            grabCandidate = nil
            tickHeld(pawn, pc, controller)
            return
        end
    end

    -- look: colour by state, visibility mode, style
    local onItem = target ~= nil
    local colorEntry = POINTER_COLORS[configui.getValue(onItem and "ip_target_color" or "ip_color") or (onItem and 4 or 1)] or POINTER_COLORS[1]
    updateLook(colorEntry.hex)
    local vis = configui.getValue("ip_visibility") or 1
    local show = vis == 1 or (vis == 2 and onItem)
    local style = configui.getValue("ip_style") or 3
    local showBeam, showReticle = show and style ~= 2, show and style ~= 1

    local endPoint, hitSomething = nil, false
    if onItem then
        endPoint = uevrUtils.vector(target.X, target.Y, target.Z)
        hitSomething = true
    elseif showBeam or showReticle then
        endPoint, hitSomething = beamEnd(origin, dir, pawn)
    end

    local p = ensurePointer(controller, colorEntry.hex)
    if p ~= nil then
        setPointerVisible(p, showBeam)
        if showBeam and endPoint ~= nil then
            if onItem then
                setPointerToTarget(p, origin, endPoint)
            else
                setPointerLength(p, uevrUtils.vectorDistance(origin, endPoint))
            end
        end
    end
    if showReticle and hitSomething and endPoint ~= nil then
        updateReticle(origin, endPoint, colorEntry.hex)
    else
        setReticleVisible(false)
    end

    -- steer the game camera at the target so the game's own focus selects it (A then works as normal)
    if onItem then
        local cm = pc.PlayerCameraManager
        local camLocation = cm ~= nil and cm:GetCameraLocation() or nil
        if camLocation ~= nil then
            local look = kismet_math_library:FindLookAtRotation(camLocation, uevrUtils.vector(target.X, target.Y, target.Z))
            look.Roll = 0
            if not steering then
                steering = true
                input.setOverrideAimMethod(input.AimMethod.UEVR)
            end
            pc:SetControlRotation(look)
            status("pointing at " .. tostring(target.name))
            return
        end
    end
    stopSteering()
    status(string.format("on (no target, %d interactables near)", #candidates))
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    pcall(updateFallers)
    local ok, err = pcall(tick)
    if not ok then
        stopSteering()
        print("[interaction_pointer] " .. tostring(err))
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    stopSteering()
    -- the components go with the level: forget them without touching them
    capsule, capsuleParent, reticle = nil, nil, nil
    appliedHalf, appliedOffsetKey, appliedVisible, reticleVisible, reticleRadius, appliedColorHex = nil, nil, nil, nil, nil, nil
    candidates = {}
    nextScan = 0
    los.target = nil
    held, grabCandidate = nil, nil
    grabPoseActive = false
    fallers = {}
    handPrev = nil
    triggerPressed, triggerReleased, swallowTrigger = false, false, false
end)

uevr.params.sdk.callbacks.on_script_reset(function()
    stopSteering()
    destroyPointer()
end)

print("[interaction_pointer] loaded")
