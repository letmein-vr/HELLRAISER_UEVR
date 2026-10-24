local uevrUtils = require('libs/uevr_utils')
local hands = require('libs/hands')
local controllers = require('libs/controllers')
local configui = require('libs/configui')

-- ---------------------------------------------------------------------------------------------
-- Hands mode for Hellraiser: VR hands (gloves cut from the arms mesh, this file) OR the full-arm IK rig
-- (libs/ik, driven from uevrmenus.lua). Ported from the Outer Worlds 2 profile's scripts/hands.lua.
--
-- They are mutually exclusive on purpose: both register the same animation ids (left_arms / right_arms)
-- with hands_animation, so whichever registers last owns the finger poses and destroying one strips the
-- other's poses. uevrmenus.lua exposes _G.setIKEnabled(bool) and _G.ikRebuild(); this file only calls them
-- when they exist (it loads before uevrmenus.lua: UEVR loads scripts in name order).
--
-- The file is deliberately NOT called hands.lua: the hands wizard's "generate script" step writes
-- scripts/hands.lua with its own immediate-create template. If that file ever appears, delete it - it
-- would build a second pair on every level change (and its on_xinput_get_state handler overrides the
-- per-weapon poses, see the OW2 notes).
--
-- Hellraiser facts (MCP, 2026-10-07): the player is CH_FirstPersonPlayable_C (C++ PlayerCharacter). Its
-- ONE skeletal mesh, Pawn.Mesh (CharacterMesh0, SK_AidanFP2, ABP_AdvancedLocomotionSystem_C), is the
-- first-person body: arms, legs, head and the camera_jnt bone the camera hangs from. Skeleton is UE
-- mannequin style: clavicle_l/r, upperarm_l/r, lowerarm_l/r, hand_l/r, fingers *_01..03_l/r,
-- weapon_jnt_l/r. That mesh is the source for the gloves and the IK rig.
-- ---------------------------------------------------------------------------------------------
local HANDS_MODE_GLOVES = 1
local HANDS_MODE_IK     = 2
local HANDS_MODE_IK_BODY = 3 -- combo value only: IK arms + the game's body/legs (scripts/ik_full_body.lua)
_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 1, label = "Hands", layout = {
			{ widgetType = "combo", id = "hands_mode", label = "Hands", initialValue = HANDS_MODE_GLOVES, selections = {"Hands", "IK Arms", "IK Arms + Body"} },
			{ widgetType = "text", id = "hands_mode_status", label = "Status: -" },
}})
-- 1 = hands, 2 = IK (both IK variants: every IK check in the profile stays `== 2`; the body part is ik_full_body.lua's)
local function getHandsMode()
	local v = configui.getValue("hands_mode")
	return (v == HANDS_MODE_IK or v == HANDS_MODE_IK_BODY) and HANDS_MODE_IK or HANDS_MODE_GLOVES
end
_G.getHandsMode = getHandsMode
local function setIK(enabled)
	if _G.setIKEnabled ~= nil then pcall(_G.setIKEnabled, enabled) end
end

-- Boot sequence (same reasons as OW2, 2026-09-26): hold auto-create off on a level change, wait for a
-- valid pawn arms mesh, create the motion controllers (the library keeps the fresh actors itself - they
-- fail exists() for a while after creation), verify they live in the pawn's world, then build. Auto-create
-- is re-enabled afterwards as a fallback for a pair that dies later.

local paramsFile = 'hands_parameters' -- [game profile]/data/hands_parameters.json, written by the hands wizard
local configName = 'Main'             -- the config name given in the wizard
local animationName = 'Shared'        -- the animation name given in the wizard

local FIRST_DELAY_MS = 2000   -- after the level-change event
local RETRY_MS       = 1000   -- while waiting for the pawn / arms mesh
local MAX_TRIES      = 90

local levelToken = 0
local lastArmsSignature = nil   -- set by buildHands, compared by the mesh-change poll below

local function log(text)
	pcall(function() uevrUtils.print("[hands boot] " .. tostring(text), LogLevel.Info) end)
end

local function alive(obj)
	if obj == nil then return false end
	local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
	return ok and r
end

-- "/Game/Maps/.../MAP_EP_1.MAP_EP_1.PersistentLevel." part of a full object name
local function worldPrefix(obj)
	if not alive(obj) then return nil end
	local name = obj:get_full_name()
	return name and name:match("%s(.-PersistentLevel%.)") or nil
end

local PLAYER_PAWN_CLASS = "CH_FirstPersonPlayable_C"
local function getArmsMesh()
	local pawn = uevr.api:get_local_pawn(0)
	if pawn == nil then return nil, nil end
	local isPlayer = false
	pcall(function() isPlayer = pawn:get_class():get_fname():to_string() == PLAYER_PAWN_CLASS end)
	if not isPlayer then return pawn, nil end -- menus / cinematic pawns: no hands
	local ok, mesh = pcall(function() return pawn.Mesh end)
	if ok and alive(mesh) then return pawn, mesh end
	return pawn, nil
end

-- true if both hand controllers exist and belong to the pawn's world
local function controllersAreCurrent(pawn)
	local want = worldPrefix(pawn)
	for id = 0, 1 do
		local c = controllers.getController(id, true)
		if not alive(c) then return false, "controller " .. id .. " missing" end
		local have = worldPrefix(c)
		if want ~= nil and have ~= nil and have ~= want then
			return false, "controller " .. id .. " is from another world (" .. have .. ")"
		end
	end
	return true
end

-- After a rebuild the new hand components start in the open pose: hands_animation only re-applies the
-- per-weapon grip pose on a grip-animation change or an input edge. Force the state refresh the
-- attachment-change path uses, a little after creation (and once more after the hide re-applies).
function refreshWeaponPoses()
	for _, ms in ipairs({300, 1200}) do
		uevrUtils.setTimeout(ms, function()
			pcall(function()
				hands.updateAnimationState(Handed.Right)
				hands.updateAnimationState(Handed.Left)
			end)
		end)
	end
end
_G.refreshWeaponPoses = refreshWeaponPoses

-- the wizard has not been run yet -> nothing to build from (createFromConfig with a missing file errored and
-- then crashed in the backend's error formatting on OW2). Opening the wizard writes a stub
-- {"profiles": null} before any pose is captured, so a table alone is not enough: require a profile.
local function haveHandsParameters()
	local ok, cfg = pcall(function() return json.load_file(paramsFile .. ".json") end)
	return ok and type(cfg) == "table" and type(cfg["profiles"]) == "table" and next(cfg["profiles"]) ~= nil
end

function armsSignature(arms)
	local sig = nil
	pcall(function()
		local mesh = arms.SkeletalMesh
		sig = mesh and mesh:get_full_name() or "nil"
		local mats = arms.OverrideMaterials
		if mats ~= nil then
			for i = 1, #mats do
				local m = mats[i]
				sig = sig .. "|" .. (m and tostring(m:get_full_name()) or "nil")
			end
		end
	end)
	return sig
end

local function buildHands(token, tries)
	if token ~= levelToken then return end -- another level change happened meanwhile
	local pawn, arms = getArmsMesh()
	if getHandsMode() == HANDS_MODE_IK then
		-- IK mode: no glove pair; the rig's own auto-create builds it. The solvers need the motion
		-- controllers and nothing else creates them in IK mode, so create them up front.
		hands.setAutoCreateHands(false)
		hands.destroyHands()
		controllers.createController(0)
		controllers.createController(1)
		controllers.createController(2)
		setIK(true)
		if arms ~= nil then lastArmsSignature = armsSignature(arms) end
		configui.setLabel("hands_mode_status", configui.getValue("hands_mode") == HANDS_MODE_IK_BODY and "Status: IK Arms + Body" or "Status: IK Arms")
		log("IK mode: glove hands disabled, rig enabled")
		return
	end
	setIK(false)
	if arms == nil then
		if tries < MAX_TRIES then
			uevrUtils.setTimeout(RETRY_MS, function() buildHands(token, tries + 1) end)
		else
			log("gave up waiting for the pawn arms mesh")
		end
		return
	end
	if not haveHandsParameters() then
		configui.setLabel("hands_mode_status", "Status: no data/hands_parameters.json - run the Hand Config wizard (uevrmenus.lua)")
		log("no " .. paramsFile .. ".json yet; hands not built")
		return
	end

	controllers.createController(0)
	controllers.createController(1)
	controllers.createController(2)
	local ok, why = controllersAreCurrent(pawn)
	if not ok then
		log("controllers are stale after create (" .. tostring(why) .. "); rebuilding")
		controllers.destroyControllers()
		controllers.createController(0)
		controllers.createController(1)
		controllers.createController(2)
		local ok2, why2 = controllersAreCurrent(pawn)
		if not ok2 then log("controllers STILL stale after rebuild: " .. tostring(why2)) end
	end

	hands.destroyHands() -- destroys any previous pair; hands.reset() only forgets it (leaks live components)
	hands.createFromConfig(paramsFile, configName, animationName)
	hands.setAutoCreateHands(true)
	lastArmsSignature = armsSignature(arms)
	refreshWeaponPoses()
	configui.setLabel("hands_mode_status", "Status: Hands")
	local c0 = controllers.getController(0, true)
	log("hands created (try " .. tries .. ", controllers " .. (ok and "ok" or "rebuilt") .. ", left controller " .. (alive(c0) and c0:get_full_name() or "nil") .. ")")
end

-- ---------------------------------------------------------------------------------------------
-- Arms mesh / material change -> rebuild (the hands are copies of the arms mesh and its materials).
-- Hellraiser swaps MeshMaterialDynamicInstances for burn / damage effects (pawn.BurnedHands timeline);
-- if that turns out to flicker the hands, drop the materials from armsSignature().
-- ---------------------------------------------------------------------------------------------
local POLL_MS          = 500
local REBUILD_DELAY_MS = 400
local nextPoll = 0
local rebuildPending = false

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local now = os.clock()
	if now < nextPoll or rebuildPending then return end
	nextPoll = now + POLL_MS / 1000
	local ikMode = getHandsMode() == HANDS_MODE_IK
	if not ikMode and not hands.exists() then return end
	local _, arms = getArmsMesh()
	if arms == nil then return end
	local sig = armsSignature(arms)
	if lastArmsSignature == nil then lastArmsSignature = sig return end
	if sig == nil or sig == lastArmsSignature then return end
	log("arms mesh changed -> rebuilding " .. (ikMode and "IK rig" or "hands") .. ": " .. tostring(sig))
	lastArmsSignature = sig
	rebuildPending = true
	local token = levelToken
	uevrUtils.setTimeout(REBUILD_DELAY_MS, function()
		rebuildPending = false
		if token ~= levelToken then return end
		if ikMode then
			if _G.ikRebuild ~= nil then pcall(_G.ikRebuild) end
		else
			buildHands(token, 1)
		end
	end)
end)

-- Switching the mode at runtime: tear down the current setup and build the other one in place.
configui.onUpdate("hands_mode", function(value)
	uevrUtils.setTimeout(1, function() -- configui callbacks run on the draw thread; build on the game thread
		levelToken = levelToken + 1
		local token = levelToken
		lastArmsSignature = nil
		buildHands(token, 1)
	end)
end)

uevrUtils.registerLevelChangeCallback(function(level)
	hands.setAutoCreateHands(false)
	hands.destroyHands()
	levelToken = levelToken + 1
	local token = levelToken
	uevrUtils.setTimeout(FIRST_DELAY_MS, function() buildHands(token, 1) end)
end)

-- script reset / first load with a level already running: no level-change event comes
uevrUtils.setTimeout(FIRST_DELAY_MS, function()
	levelToken = levelToken + 1
	buildHands(levelToken, 1)
end)

-- Input handling is automatic (libs/hands_animation.lua). Do NOT add on_xinput_get_state + hands.handleInput(state, false, ...):
-- it overrides the per-attachment weapon poses with the generic grip/trigger poses.
