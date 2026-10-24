-- "IK Arms + Body" hands mode (ported from the Stalker 2 profile's stalker2/ik_full_body.lua, 2026-10-08): shows the
-- game's own animated body and legs under the IK arms.
--
-- Pawn.Mesh (SK_AidanFP2: body + legs + arms + head, ONE mesh) normally stays out of the render passes in both hands
-- modes (weaponhook.lua post-tick) while the gloves / IK rig draw the arms. With hands_mode = 3 ("IK Arms + Body"):
--   * Pawn.Mesh is shown through the callbacks weaponhook.lua (and libs/pawn) consult: is_pawn_body_hidden /
--     is_pawn_arms_hidden = false.
--   * Its own arms are hidden from the upper arm down (HideBoneByName upperarm_l / upperarm_r) and its neck + head
--     (neck_01, takes Head and camera_jnt with it) - the VR camera sits inside the head. The VR camera position comes
--     from libs/input.lua, not from camera_jnt, so hiding that bone does not move the view.
--   * libs/ik.lua pins the rig's clavicles to Pawn.Mesh's every tick (ik.setFullBodySource), so the IK arms start at
--     the visible body's shoulders; the IK dev panel's mesh_location/rotation_offset and shoulder width then have no
--     visible effect (by design, same as Stalker 2). Instead the panel's Shoulder width / forward / height sliders
--     move those pinned start points (ik.setFullBodyShoulderOffset).
--   * While the rig is hidden (is_hands_hidden - montage rules for interactions / cinematics) the body's own arms
--     show instead.
-- Pawn.Mesh keeps FirstPersonPrimitiveType = 1 on purpose: it has bOwnerNoSee = true and the FirstPerson mode is what
-- makes it visible to its owner; camera_stabilize.lua turns the camera's first-person scale off, so it renders at
-- real size.
-- Hands mode and plain IK Arms are untouched: every callback returns nil then.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local ik = require('libs/ik')

local MODE_IK_FULL_BODY = 3
local HEAD_BONE = "neck_01"
local ARM_BONES = { "upperarm_l", "upperarm_r" }
local PRIORITY = 100

-- Legs: Pawn.Mesh has a real lower-body section whose material parameter OpacityStrength the game leaves at 0.0 in
-- first person (MCP 2026-10-08: body rendering, leg bones not hidden, feet ~167 cm under the camera, yet no legs).
-- The slider sets it while this mode is active and the game's value is restored on leaving the mode. Done from Lua
-- on purpose: mutating a live MID through MCP crashed Stalker 2.
-- The lower-body slots are found by material NAME ("LowerBody"), not index: SK_AidanFP has one (slot 1,
-- MID_MI_Aidan_LowerBody_FP), the naked SK_AidanFP_Naked of EP_1 has 13 slots with the head in slot 1 and the
-- lower body in slots 4 and 8 (MI_Aidan_Naked_LowerBody) - the old fixed slot 1 made its head opaque and left the
-- legs invisible (MCP 2026-10-08).
local LEGS_MATERIAL_MATCH = "lowerbody"
local LEGS_PARAM = "OpacityStrength"
_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 1.5, label = "IK Arms + Body", layout = {
	{ widgetType = "text", label = "Only used when Hands = \"IK Arms + Body\"" },
	{ widgetType = "slider_float", id = "ikb_legs_opacity", label = "Legs opacity (game uses 0 in first person)", initialValue = 1.0, range = {0.0, 1.0} },
	-- the IK arms start at the body's shoulders; these move those start points (the IK panel's shoulder width does
	-- nothing in this mode because the clavicles are pinned to the body)
	{ widgetType = "slider_float", id = "ikb_shoulder_width", label = "Shoulder width (cm added per side)", initialValue = 0.0, range = {-10.0, 25.0} },
	{ widgetType = "slider_float", id = "ikb_shoulder_forward", label = "Shoulder forward (cm)", initialValue = 0.0, range = {-15.0, 15.0} },
	{ widgetType = "slider_float", id = "ikb_shoulder_up", label = "Shoulder height (cm)", initialValue = 0.0, range = {-15.0, 15.0} },
}})

local function num(id)
	local v = configui.getValue(id)
	return type(v) == "number" and v or 0.0
end
ik.setFullBodyShoulderOffset(function()
	return num("ikb_shoulder_width"), num("ikb_shoulder_forward"), num("ikb_shoulder_up")
end)

local state = {
	active = false,
	headHiddenOn = nil,  -- address of the Pawn.Mesh the head was hidden on
	armsHidden = nil,    -- current arm-bone hide state applied to Pawn.Mesh
	legsMesh = nil,      -- Pawn.Mesh the lower-body MIDs below belong to
	legsMIDs = nil,      -- { { mid = lower-body MID we changed, original = the game's OpacityStrength } }
	legsApplied = nil,   -- value we last wrote
}

local function isAlive(object)
	if object == nil then return false end
	local ok, name = pcall(function() return object:get_full_name() end)
	return ok and name ~= nil
end

local function addressOf(object)
	local ok, address = pcall(function() return object:get_address() end)
	return ok and address or nil
end

-- Read straight off the pawn: UObjectHook.exists() can reject freshly loaded pawn parts
local PLAYER_PAWN_CLASS = "CH_FirstPersonPlayable_C"
local function getBodyMesh()
	local p = uevr.api:get_local_pawn(0)
	if p == nil then return nil end
	local isPlayer = false
	pcall(function() isPlayer = p:get_class():get_fname():to_string() == PLAYER_PAWN_CLASS end)
	if not isPlayer then return nil end
	local ok, mesh = pcall(function() return p.Mesh end)
	if ok and isAlive(mesh) then return mesh end
	return nil
end

local function isWanted()
	return configui.getValue("hands_mode") == MODE_IK_FULL_BODY
end
_G.isIKFullBody = isWanted

local function isRigHidden()
	return uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_hands_hidden") == true
end

uevrUtils.registerUEVRCallback("is_pawn_body_hidden", function()
	if state.active then return false, PRIORITY end
	return nil, 0
end)

uevrUtils.registerUEVRCallback("is_pawn_arms_hidden", function()
	if state.active then return false, PRIORITY end
	return nil, 0
end)

local function setArmBonesHidden(mesh, hidden)
	for _, bone in ipairs(ARM_BONES) do
		pcall(function()
			if hidden then
				mesh:HideBoneByName(uevrUtils.fname_from_string(bone), 0)
			else
				mesh:UnHideBoneByName(uevrUtils.fname_from_string(bone))
			end
		end)
	end
	state.armsHidden = hidden
end

local legsParamName = nil
local function legsParam()
	if legsParamName == nil then legsParamName = uevrUtils.fname_from_string(LEGS_PARAM) end
	return legsParamName
end

local function restoreLegs()
	for _, entry in ipairs(state.legsMIDs or {}) do
		pcall(function()
			if isAlive(entry.mid) and entry.original ~= nil then entry.mid:SetScalarParameterValue(legsParam(), entry.original) end
		end)
	end
	state.legsMesh, state.legsMIDs, state.legsApplied = nil, nil, nil
end

-- the mesh's lower-body MIDs (material name contains "LowerBody"), with the game's OpacityStrength on each
local function collectLegsMIDs(mesh)
	local list = {}
	pcall(function()
		local count = mesh:GetNumMaterials()
		for i = 0, count - 1 do
			local mid = mesh:GetMaterial(i)
			if mid ~= nil and mid.SetScalarParameterValue ~= nil then
				local name = string.lower(mid:get_full_name() or "")
				if string.find(name, LEGS_MATERIAL_MATCH, 1, true) ~= nil then
					table.insert(list, { mid = mid, original = mid:K2_GetScalarParameterValue(legsParam()) })
				end
			end
		end
	end)
	return list
end

local LEGS_RECHECK_S = 2.0 -- the game can re-create the MIDs (outfit change / reload) on the same mesh
local function applyLegs(mesh)
	local want = configui.getValue("ikb_legs_opacity")
	if type(want) ~= "number" then want = 1.0 end
	local now = os.clock()
	local first = state.legsMIDs == nil or state.legsMesh ~= addressOf(mesh)
	if first or now - (state.legsCheckedAt or 0) > LEGS_RECHECK_S then
		state.legsCheckedAt = now
		local changed = first
		if not first then
			-- same mesh: re-collect only if its lower-body MIDs are no longer the ones we hold
			for _, entry in ipairs(state.legsMIDs) do
				local ok, still = pcall(function()
					for i = 0, mesh:GetNumMaterials() - 1 do
						if mesh:GetMaterial(i) == entry.mid then return true end
					end
					return false
				end)
				if not (ok and still) then changed = true break end
			end
		end
		if changed then
			if not first then restoreLegs() end
			state.legsMesh = addressOf(mesh)
			state.legsMIDs = collectLegsMIDs(mesh)
			state.legsApplied = nil
		end
	end
	if state.legsApplied ~= want then
		for _, entry in ipairs(state.legsMIDs or {}) do
			pcall(function() entry.mid:SetScalarParameterValue(legsParam(), want) end)
		end
		state.legsApplied = want
	end
end

local function activate()
	state.active = true
	state.armsHidden = nil
	ik.setFullBodySource(getBodyMesh)
	print("[IKFullBody] on")
end

local function deactivate()
	state.active = false
	ik.setFullBodySource(nil)
	local mesh = getBodyMesh()
	if mesh ~= nil then
		if state.headHiddenOn ~= nil and addressOf(mesh) == state.headHiddenOn then
			pcall(function() mesh:UnHideBoneByName(uevrUtils.fname_from_string(HEAD_BONE)) end)
		end
		setArmBonesHidden(mesh, false) -- the body is hidden again by weaponhook; leave its bones as the game made them
	end
	restoreLegs()
	state.headHiddenOn = nil
	state.armsHidden = nil
	-- the rig's clavicles keep the body's last pose; rebuild it from its reference pose (auto-created within ~1 s)
	if ik.exists() then ik.destroyAll() end
	print("[IKFullBody] off")
end

uevrUtils.setInterval(100, function()
	local wanted = isWanted()
	local mesh = wanted and getBodyMesh() or nil
	if wanted and mesh ~= nil then
		if not state.active then activate() end
		-- Loading a save can reset the hidden bones on the SAME mesh (MCP 2026-10-08: same address, no bone hidden,
		-- cached state still "hidden" -> the whole body incl. arms + head drawn over the IK rig). Check the mesh
		-- itself instead of trusting the cache.
		pcall(function()
			if state.headHiddenOn ~= nil and not mesh:IsBoneHiddenByName(uevrUtils.fname_from_string(HEAD_BONE)) then
				state.headHiddenOn = nil
			end
			if state.armsHidden == true and not mesh:IsBoneHiddenByName(uevrUtils.fname_from_string(ARM_BONES[1])) then
				state.armsHidden = nil
			end
		end)
		-- (re)hide the head on the current body mesh (a new pawn after a load or respawn)
		local address = addressOf(mesh)
		if state.headHiddenOn ~= address then
			local ok = pcall(function() mesh:HideBoneByName(uevrUtils.fname_from_string(HEAD_BONE), 0) end)
			if ok then
				state.headHiddenOn = address
				state.armsHidden = nil
			end
		end
		-- body arms: hidden under the IK arms, shown while a montage rule hides the rig
		local hideArms = not isRigHidden()
		if state.armsHidden ~= hideArms then setArmBonesHidden(mesh, hideArms) end
		applyLegs(mesh)
	elseif state.active and not wanted then
		deactivate()
	end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
	state.headHiddenOn = nil -- the level's pawn mesh is replaced
	state.armsHidden = nil
	state.legsMesh, state.legsMIDs, state.legsApplied = nil, nil, nil -- its MIDs go with it
end)
