-- Flashlight on the headset for Hellraiser (2026-11-01).
--
-- The game's flashlight is Pawn.FlashlightSpotlight on a hidden 3.75 x 2.5 x 2.5 cm cube, Pawn.FlashlightMesh, attached
-- to Pawn.Mesh socket camera_jnt at (5.5, 0.5, -14.6) cm (MCP). The body animation turns camera_jnt toward the control
-- rotation (aim offset), so the light pointed wherever the AIM pointed, not the head: while the left-hand interaction
-- pointer steers the aim at the item it points at, the light swung with the left controller. Here the cube is
-- re-parented to the UEVR HMD component with the same relative transform (KeepRelative; its X axis = view forward as on
-- camera_jnt - MCP: within 1 deg of the camera), re-checked every 0.5 s (new pawn / HMD component after a level load,
-- or the game re-attaching it). Unticking the checkbox, or a script reset, puts it back on camera_jnt.
-- The re-parenting alone was not enough (live log 2026-11-01): the game also AIMS the light every tick - it rotates the
-- cube relative to its parent toward its look-at target (Pawn.TargetFlashlightLookAtRotation, from the camera / aim,
-- smoothed), so on the HMD it still swung to wherever the pointer steered the aim (beam -51/-110 with the aim at
-- -53/-110 and the HMD at 4/-174). So after the game's tick, for every stereo view (where UObjectHook's placements also
-- win the render, as for the gun), the cube's relative rotation is put back to its class default (0.5, 2.5, 0).

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local controllers = require('libs/controllers')

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 2.6, label = "Flashlight", layout = {
    { widgetType = "checkbox", id = "fl_on_hmd", label = "Flashlight follows the headset", initialValue = true },
}})

local GAME_SOCKET = "camera_jnt"
local CHECK_INTERVAL = 0.5
local DEFAULT_REL_ROT = { Pitch = 0.5, Yaw = 2.5, Roll = 0.0 } -- Default__CH_FirstPersonPlayable_C.FlashlightMesh (MCP)
local state = { mesh = nil, onHmd = false, nextCheck = 0, socket = nil, empty = nil, relRot = nil }

-- the cube's designer rotation from the pawn class default (falls back to the value read by MCP)
local function defaultRelativeRotation(pawn)
    local rot = DEFAULT_REL_ROT
    pcall(function()
        local r = pawn:get_class():get_class_default_object().FlashlightMesh.RelativeRotation
        if r ~= nil and r.Pitch ~= nil then rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end
    end)
    return uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll)
end

local function fname(s)
    return uevrUtils.fname_from_string(s)
end

-- back onto the game's parent (only the live pawn's own flashlight)
local function restore()
    local mesh = state.mesh
    state.mesh, state.onHmd = nil, false
    if mesh == nil then return end
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        if pawn == nil or pawn.FlashlightMesh ~= mesh or pawn.Mesh == nil then return end
        if state.socket == nil then state.socket = fname(GAME_SOCKET) end
        mesh:K2_AttachTo(pawn.Mesh, state.socket, 0, false) -- 0 = KeepRelative: the same offset on the bone again
        print("[flashlight_hmd] flashlight back on " .. GAME_SOCKET)
    end)
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local now = os.clock()
    if now < state.nextCheck then return end
    state.nextCheck = now + CHECK_INTERVAL
    if configui.getValue("fl_on_hmd") == false then
        if state.mesh ~= nil then restore() end
        return
    end
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        local mesh = pawn ~= nil and pawn.FlashlightMesh or nil
        if mesh == nil then state.mesh, state.onHmd = nil, false return end
        local hmd = controllers.getController(2, true)
        if hmd == nil then return end
        local parent = mesh.AttachParent
        if state.mesh == mesh and parent == hmd then return end
        if state.empty == nil then state.empty = fname("") end
        mesh:K2_AttachTo(hmd, state.empty, 0, false) -- KeepRelative: the camera_jnt offset, now from the headset
        state.mesh, state.onHmd = mesh, true
        if state.relRot == nil then state.relRot = defaultRelativeRotation(pawn) end
        print("[flashlight_hmd] flashlight attached to the HMD")
    end)
end)

-- every stereo view: undo the game's per-tick aiming of the cube (see the header)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if not state.onHmd or state.mesh == nil or state.relRot == nil then return end
    pcall(function()
        state.mesh:K2_SetRelativeRotation(state.relRot, false, reusable_hit_result, false)
    end)
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    state.mesh, state.onHmd = nil, false -- went with the old world
end)

uevr.params.sdk.callbacks.on_script_reset(function()
    restore()
end)

print("[flashlight_hmd] loaded")
