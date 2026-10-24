--[[
Usage
	Drop the lib folder containing this file into your project folder

	Add code like this in your script (one call does the whole start-up):
		local hud = require("libs/hud")
		hud.setup({
			developerMode = true,             -- the "HUD Dev" tab for building elements (default: uevrUtils dev mode)
			playerTab = "HUD",                -- label of the players' tab, false for none (default "HUD")
			exposure = "postprocess",         -- "none", "postprocess" or a function returning the game's EV100
			                                  -- (default: what was saved with the elements)
			redrawRate = 45,                  -- VR redraws per second of the game widgets, 0 = every frame (default:
			                                  -- what was saved, otherwise every frame)
			logFile = "hud_log.txt",          -- also log to data/hud_log.txt (print() does not reach log.txt on every build)
			logLevel = LogLevel.Warning,
			-- parametersFile = "hud_parameters", playerConfigFile = "hud_player_config"   (data/<name>.json)
		})
	For a release build turn developerMode off: the elements come from data/hud_parameters.json, which the dev tab's
	Save button writes. Ship that file with the mod.
	hud.init(isDeveloperMode, logLevel) still works on its own; setup() calls it.

	This module takes pieces of a game's flat (2D) HUD and either hides them or shows them as world space
	widgets attached to a controller, the HMD, a VR hand mesh bone or a pawn mesh socket. Each piece is an
	"element". An element can be

		hud.Mode.DIRECT - a whole top level UserWidget (one that the game adds to the viewport by itself) is
			shown in its own WidgetComponent. Sharpest result. Use it when the game builds its HUD out of
			many separate widgets (e.g. Hellraiser).

		hud.Mode.REGION - the element is a child inside one big HUD widget (e.g. Stalker 2 W_GameHUD_C). The
			big widget (the "source") is shown once in a WidgetComponent that is not drawn in the world, and
			each element is a flat plane (engine mesh + the engine's widget material) showing a render target
			of its own that receives an exact copy of its rectangle of the source every frame. Any number of
			elements can share one source.

		In both modes the game's widget is NEVER taken off the screen: it stays where the game put it, made
		invisible (render opacity 0), and a host widget of our own shows the same content (shared Slate, see
		"Shared widgets"). Taking it off the screen crashed Outer Worlds 2, whose UI manager drops the widget
		from its own list and later reads a null HUD. The game's widget tree is never re-parented, so bindings,
		animations and the game's show/hide logic keep working (the game's opacity / visibility changes are
		mirrored onto the VR copy).

		hud.Mode.HIDE - the widget (top level or child) is collapsed and nothing is shown in its place.

	Disabling an element, calling hud.restoreAll() or resetting scripts makes the flat screen copy visible again.

	Available functions:

	hud.setup(options) - start-up in one call, see above
	hud.init(isDeveloperMode, logLevel) - loads saved elements (data/hud_parameters.json) and starts updating
		example:
			hud.init(true, LogLevel.Debug)
	hud.setLogFile(fileName) - copy everything the lib logs (at the current log level) into data/<fileName>
	hud.setRedrawRate(perSecond), hud.getRedrawRate() - VR redraws per second of the shown game widgets, 0 = every
		frame. A Region source redraws a screen-sized widget each time, so 30 - 45 saves GPU time
	hud.getStats() - { averageMs, copiesPerFrame }: the lib's Lua time per frame and Region copies per frame

	hud.addElement(definition, (optional)persist) - adds or replaces an element. Only plain data goes in the
		definition so it can be saved. Returns the element id.
		example (Region mode, Stalker 2 ammo panel on the right hand):
			hud.addElement({
				id = "ammo",
				mode = hud.Mode.REGION,
				widget = { class = "WidgetBlueprintGeneratedClass /Game/.../W_GameHUD.W_GameHUD_C", child = "AmmoPanel" },
				-- (sourceSize is ignored: a shared source always uses the screen layout size)
				--region = { 3400, 1990, 370, 158 },		-- optional fixed rectangle x, y, w, h (default: the child's own rectangle)
				target = { type = hud.Target.RIGHT_HAND, socket = "hand_r" },
				transform = { position = {0, 8, 4}, rotation = {0, 90, 0}, widthCm = 12 },
				appearance = { opacity = 1.0, brightness = 0, exposure = true },
			})
		example (Direct mode, Hellraiser health widget on the left controller):
			hud.addElement({
				id = "health",
				mode = hud.Mode.DIRECT,
				widget = { class = "WidgetBlueprintGeneratedClass /Game/.../W_PlayerInfo.W_PlayerInfo_C" },
				drawAtDesiredSize = true,				-- size the plane to the widget's content
				target = { type = hud.Target.LEFT_CONTROLLER },
				transform = { position = {0, 0, 5}, rotation = {0, 180, 0}, scale = 0.05 },
			})

		DIRECT suits widgets that size to their content. A top level widget that fills the screen with its
		content in one corner (very common) works better as REGION with no child and a fixed region.
		regionRest = true (Region, usually with no child): shows the whole widget minus the areas the other Region
		elements of the same widget show - for games whose whole HUD is one widget (Stalker 2), so taking one part
		does not take the rest of the HUD away. Placed like any element, e.g. on the HMD in front of the player.
		Region elements whose widget draws parts outside its own box (icons around a ring, a label hanging off
		a bar) take regionBounds = "content": the copied rectangle is then the union of every visible widget
		inside the child instead of the child's own box.
		widget.child is a widget name inside the widget's own tree, or a path into nested UserWidgets:
		child = "PlayerStatsDisplay/HealthBar" is HealthBar inside the tree of the nested UserWidget PlayerStatsDisplay.
		hud.findParts("health") lists every matching part with the class + child to use (the dev panel's Search).
		Other definition fields: enabled, regionPadding, resolutionScale, restoreZOrder, drawSize,
		appearance = { tint = {r,g,b}, blendMode, twoSided, pivot, cylinderArcAngle, sortPriority,
		exposureStrength, maxTint }. maxTint caps the brightness multiplier: a large bright panel in a dark
		scene is part of what the game exposes for and will darken the scene around it.

	Panels
		hud.init(true) also opens the "HUD Dev" tab (libs/config/hud_config_dev.lua): pick a game widget and a part
		of it, choose mode, target, placement and appearance, all applied live. Nothing is saved until its Save
		button (hud.saveParameters) is pressed; Revert (hud.revertParameters) goes back to the saved set.
	hud.showPlayerConfiguration(panelLabel, saveFileName) - adds a "HUD" tab for players (libs/config/hud_config.lua)
		with on/off, size and opacity per element, kept in data/<saveFileName>.json (default hud_player_config)
		example:
			hud.init(false)
			hud.showPlayerConfiguration("HUD")
	hud.saveParameters(), hud.revertParameters() - write / reload data/hud_parameters.json (elements, exposure source,
		global stops). Elements added from a script are only saved by this or addElement(definition, true).
	hud.setPlayerSetting(id, key, value), hud.getPlayerSetting(id, key) - "enabled", "sizeScale", "opacity" on top
		of the definition (used by the player tab)
	hud.setExposureSourceName("none" | "postprocess") - the saved exposure source choice

	Visibility rules (optional, per element; none by default = always shown)
		definition.visibility = {
			fadeTime = 0.25,
			lookAt   = { enabled = true, inner = 15, outer = 30, minimum = 0 },	-- glance at it
			facing   = { enabled = true, inner = 40, outer = 70, minimum = 0 },	-- its front turned to the eyes (wrist turn)
			distance = { enabled = true, near = 40, far = 70, minimum = 0 },	-- close to the head
			hideWhenPaused = true, hideInCutscene = true, hideInUEVRMenu = true, hideWhenCharacterHidden = true,
		}
		Each enabled rule gives a factor (1 inside inner/near, 0 beyond outer/far, lifted to minimum); the lowest wins
		and fades the element. A fully faded element is hidden and costs next to nothing. Players can switch the
		rules off per element with "Always show" in the player tab.
	hud.registerVisibilityCallback(func) - func(id, definition) returns 0..1 or nil, for game specific rules

	hud.removeElement(id) - restores and forgets an element
	hud.setElementEnabled(id, value) - turns one element on or off (off restores it to the flat HUD)
	hud.setElementValue(id, path, value, (optional)persist) - changes one value of a live element
		example:
			hud.setElementValue("ammo", {"appearance", "opacity"}, 0.6)
	hud.getElement(id), hud.getElementIDs(), hud.getComponent(id), hud.getElementInfo(id)
	hud.findParts(text, (optional)options) - text search (widget and class names, any case) over every HUD widget
		that exists now, nested UserWidgets included. Returns results (drawn first) and the number searched.
		example:
			for _, r in ipairs(hud.findParts("ammo")) do print(r.class, r.child, r.drawn) end
	hud.findWidgetPart(class, child) - the live widget a definition's widget field points at, or nil
	hud.restoreAll() - puts every widget back and destroys all components
	hud.setEnabled(value) - master switch

	Brightness (see "Exposure" below)
	hud.setExposureSource(func) - func returns the current effective EV100 or nil
	hud.setExposureStops(stops) - global manual brightness offset, each +1 doubles
	hud.exposure.effectiveEV100(ev100, bias, curve), hud.exposure.fromLuminance(luminance, bias, curve)
	hud.exposure.createPostProcessSource(options) - ready made source for games that pin their exposure

	Callbacks
	hud.registerTargetCallback(func) - func(definition) returns parentComponent, socketName for
		hud.Target.CUSTOM (e.g. the IK rig mesh or a weapon mesh)
	hud.registerPostAttachCallback(func) - func(id, component, widget) for game specific fixups
	hud.registerRegionCallback(func) - func(id, definition, source) returns x, y, w, h to override the rectangle

	Exposure
		A world space widget is drawn with an unlit material, so scene lighting does not touch it, but the
		game's auto exposure does. Measured swing in Stalker 2 between a dark room and open daylight is
		13.7 stops. The fix is a tint: SetTintColorAndOpacity with RGB = 1.2 * 2^(effective EV100), where
		effective EV100 = scene EV100 - exposure bias - bias curve value. Values above 1 are honoured.
		Sources, best first:
			1. A game specific getter passed to hud.setExposureSource
			2. hud.exposure.createPostProcessSource() for games whose post process volumes set the same
			   minimum and maximum exposure (Hellraiser: both 0, bias +1)
			3. No source: only the manual stops apply
		Fully automatic games (Stalker 2: -10 to +25 EV) have no generic source. See the notes at the
		bottom of this file.

	Engine notes that shaped this file (all measured)
		- BlendMode on a WidgetComponent is EWidgetBlendMode (0 Opaque, 1 Masked, 2 Transparent), not the
		  material blend mode. On UE 5.5 the component's material already exists when the component does,
		  so the blend mode is applied by setting the matching engine material.
		- Showing the source through a second widget Image applies transparency twice (255 became 82).
		  The canvas copy used here is bit exact once the target's TargetGamma is 1.0.
		- A save reload replaces the HUD widgets, the pawn and the controller. Nothing here keeps an object
		  across a rebuild without re-validating it.

	Save loads: everything this module keeps remembers its world, and anything from a previous world is only
	forgotten, never touched (the level change is raised after the new level is current).

	STATUS 2026-10-15 (Hellraiser, UE 5.6): verified - Region build and canvas copy onto the plane display (facing
	and orientation checked), child rectangles, post process exposure source, controller / HMD / hand bone targets,
	live value changes, disable and restore, Hide mode, clean startup, and 11 save loads in a row (rebuilt every time,
	values keep updating). Two Region elements sharing one source (loadout weapon selection + current equipment) and
	regionBounds = "content" verified. Direct mode verified visually (damage direction indicator on the HMD, arcs
	point the right way). Hellraiser builds almost every HUD widget as a full-screen canvas, so Region is the main
	route there; Direct warns when a widget is laid out for the whole screen (verified on W_ObjectiveNotification_C).
	Not yet run on any UE 5.5 or UE4 game.
]]--

local uevrUtils = require("libs/uevr_utils")
local controllers = require("libs/controllers")
local paramModule = require("libs/core/params")

local handsLoaded, hands = pcall(require, "libs/hands")
if not handsLoaded then hands = nil end

local M = {}

M.Mode = {
	HIDE = "hide",
	DIRECT = "direct",
	REGION = "region",
}

M.Target = {
	LEFT_CONTROLLER = "left_controller",
	RIGHT_CONTROLLER = "right_controller",
	HMD = "hmd",
	LEFT_HAND = "left_hand",
	RIGHT_HAND = "right_hand",
	PAWN_MESH = "pawn_mesh",
	CUSTOM = "custom",
}

M.BlendMode = {
	OPAQUE = 0,
	MASKED = 1,
	TRANSPARENT = 2,
}

M.exposure = {}

local controllerIDs = {
	[M.Target.LEFT_CONTROLLER] = 0,
	[M.Target.RIGHT_CONTROLLER] = 1,
	[M.Target.HMD] = 2,
}

-- material property on the WidgetComponent for each blend mode, { two sided, one sided }
local blendMaterialProperties = {
	[M.BlendMode.OPAQUE] = { "OpaqueMaterial", "OpaqueMaterial_OneSided" },
	[M.BlendMode.MASKED] = { "MaskedMaterial", "MaskedMaterial_OneSided" },
	[M.BlendMode.TRANSPARENT] = { "TranslucentMaterial", "TranslucentMaterial_OneSided" },
}

-- Region display (2026-10-15): an engine plane under an anchor component, drawn with a dynamic instance of the
-- engine's widget material (parameters SlateUI / TintColorAndOpacity / OpacityFromTexture, read from a live
-- WidgetComponent MID) showing a render target of our own. No game widget is ever created: instantiating a game
-- Blueprint widget is what broke Hellraiser save loads (genesis_cube.lua, 2026-10-14). Orientation constants are
-- verified live (see STATUS).
local REGION_MESH = "StaticMesh /Engine/BasicShapes/Plane.Plane"	-- 100 x 100 units in its X/Y plane, facing +Z
-- pitch, yaw, roll: plane X (texture U) -> anchor -Y, plane Y (texture V) -> anchor -Z, plane normal -> anchor +X =
-- the WidgetComponent convention (front faces +X, widget right = -Y, top = +Z). From FRotationMatrix: (0, -90, 90) gives
-- X axis (0,-1,0), Y axis (0,0,-1), Z axis (1,0,0). Checked live 2026-10-15: { -90, 0, 0 } showed the region readable
-- but turned 90 degrees; { 0, -90, -90 } turned its front away (invisible).
local REGION_MESH_ROTATION = { 0, -90, 90 }
local REGION_MESH_SIZE = 100.0
local REGION_MATERIAL_PATH = "MaterialInstanceConstant /Engine/EngineMaterials/%s.%s"
local regionMaterials = {	-- { two sided, one sided }
	[M.BlendMode.OPAQUE] = { "Widget3DPassThrough_Opaque", "Widget3DPassThrough_Opaque_OneSided" },
	[M.BlendMode.MASKED] = { "Widget3DPassThrough_Masked", "Widget3DPassThrough_Masked_OneSided" },
	[M.BlendMode.TRANSPARENT] = { "Widget3DPassThrough_Translucent", "Widget3DPassThrough_Translucent_OneSided" },
}
local RTF_RGBA8_SRGB = 3	-- ETextureRenderTargetFormat; the game's widget targets are 8 bit sRGB (PF_B8G8R8A8)

local ESlateVisibility_Collapsed = 1
local ESlateVisibility_Hidden = 2
local BLEND_Opaque = 0

local parametersFileName = "hud_parameters"
local paramManager = nil

local isEnabled = true
local isInitialized = false

local elements = {}			-- id -> definition (plain data)
local elementOrder = {}		-- ids in the order they were added
local runtime = {}			-- id -> live state { component, widget, source, renderTarget, ... }
local sources = {}			-- widget class name -> { root, component, width, height, zOrder, users }

local retryAfter = {}		-- id -> os.clock() time before which a failed element is not built again
local RETRY_BACKOFF = 30.0
local PENDING_CHECK_INTERVAL = 0.25	-- seconds between checks while a Region part has no size yet
local SOURCE_IDLE_RELEASE = 3.0	-- seconds a source kept for a rebuild may stay unused before the widget goes back to the screen

local knownWidgets = {}		-- class name -> the widget last taken off the screen for it
local layoutWarned = {}		-- id -> draw size the Direct layout warning was last logged for
local layoutWarnings = {}	-- id -> current Direct layout warning text (shown by the dev panel), nil when fine

local classCache = {}		-- class name -> class object looked up by this module since the last level change
local classCheckedAt = {}	-- class name -> os.clock() time of the last fresh lookup
local CLASS_LOOKUP_INTERVAL = 5.0

local slateLibrary = nil
local drawContext = nil
local canvasCopyAvailable = nil	-- nil = not tried yet, true/false after the first attempt

-- player choices on top of the modder's definitions (player tab, libs/config/hud_config.lua); never saved into the
-- definitions: id -> { enabled = false to turn the element off, sizeScale = width multiplier, opacity = multiplier }
local playerSettings = {}

local exposureSource = nil
local exposureSourceName = "none"	-- what the dev panel selected and saves: "none" or "postprocess"
local exposureStops = 0.0
local exposureEV = nil		-- smoothed effective EV100, nil when there is no source
local EXPOSURE_RATE = 2.0	-- how fast the smoothed value follows the source, per second

local targetCallback = nil
local regionCallback = nil
local postAttachCallbacks = {}

-- cost readout (hud.getStats, dev panel): Lua time of update() averaged over STATS_WINDOW seconds. os.clock has ~1 ms
-- steps on Windows, so single frames read 0 or 1 ms; the average over a few hundred frames is still right.
local STATS_WINDOW = 2.0
local stats = { frames = 0, seconds = 0.0, window = 0.0, copies = 0, averageMs = 0.0, copiesPerFrame = 0.0 }

-- seconds between redraws of the game widgets shown in VR (WidgetComponent.RedrawTime), 0 = every frame
local redrawTime = 0.0
local headNeeded = nil -- cache of needsHead(); nil = work it out again

local validateTimer = 0.0
local tintTimer = 0.0
local VALIDATE_INTERVAL = 1.0
local TINT_INTERVAL = 0.25

local currentLogLevel = LogLevel.Error
function M.setLogLevel(val)
	currentLogLevel = val
end
-- optional copy of the log in data/<logFileName> (script print() does not reach log.txt on every UEVR build)
local logFileName, logLines = nil, {}
local LOG_FILE_LINES = 500
function M.setLogFile(fileName)
	logFileName = fileName
	logLines = {}
end

function M.print(text, logLevel)
	if logLevel == nil then logLevel = LogLevel.Debug end
	if logLevel <= currentLogLevel then
		uevrUtils.print("[hud] " .. text, logLevel)
		if logFileName ~= nil then
			logLines[#logLines + 1] = os.date("%H:%M:%S ") .. tostring(text)
			if #logLines > LOG_FILE_LINES then table.remove(logLines, 1) end
			pcall(fs.write, logFileName, table.concat(logLines, "\n"))
		end
	end
end

-- names are made once: making an FName from a string is an engine call
local fnameCache = {}
local function fname(str)
	str = str or ""
	local cached = fnameCache[str]
	if cached == nil then
		cached = uevrUtils.fname_from_string(str)
		fnameCache[str] = cached
	end
	return cached
end

-- runs fn inside pcall and logs a failure once per label so a per-frame error cannot flood the log
local loggedFailures = {}
local function try(label, fn, ...)
	local ok, a, b, c, d = pcall(fn, ...)
	if not ok then
		if loggedFailures[label] == nil then
			loggedFailures[label] = true
			M.print(label .. " failed: " .. tostring(a), LogLevel.Warning)
		end
		return nil
	end
	return a, b, c, d
end

-- A widget from before a level change or a save load can still pass getValid while its methods are gone
-- (the lookup returns nil). Returns the object only when methodName can still be looked up on it.
-- (named functions, not closures: these run several times per element per frame)
local function indexField(object, key) return object[key] end
local function getAddressOf(object) return object:get_address() end

local function getLive(object, methodName)
	object = uevrUtils.getValid(object)
	if object == nil then return nil end
	local ok, method = pcall(indexField, object, methodName)
	if not ok or method == nil then return nil end
	return object
end

-- Every source and element state remembers the world it was made in (2026-10-14). The libs raise the level change
-- only after the new level is current, and by then the old level's objects can be freed and their memory reused by
-- the new level. Calling into them then corrupts the game (Hellraiser: destroyComponent with destroyOwner on a stale
-- component destroyed the NEW level's pawn). Anything from another world is only ever forgotten, never touched.
-- Inside update() the world is read once per frame (it was read many times per element per frame before).
local inUpdate, frameId, frameWorld, frameWorldId = false, 0, nil, -1
local function currentWorld()
	if inUpdate and frameWorldId == frameId then return frameWorld end
	local ok, world = pcall(uevrUtils.get_world)
	if not ok then world = nil end
	if inUpdate then frameWorld, frameWorldId = world, frameId end
	return world
end

local function isCurrentWorld(record)
	if record == nil or record.world == nil then return false end
	local world = currentWorld()
	return world ~= nil and world == record.world
end

-- Objects this module made itself (components, render targets, materials): address -> { world, adopted }.
-- On some backends (Outer Worlds 2) UObjectHook.exists() - and with it uevrUtils.getValid - rejects a NEW object
-- until a background scan has adopted it, measured 0 to 22+ s. Gating our own fresh objects on getValid made every
-- Region build there fail, rebuild every second and skip the cleanup (leaking components that still held the game's
-- HUD). So our own objects are trusted while they wait for adoption - but ONLY until then: once getValid has accepted
-- an object, getValid alone decides. Something else can destroy our objects (a parent destroyed together with its
-- children, e.g. a hand mesh), and trusting the record after that would hand a freed object back.
local ownObjects = {}
local function addressOf(object)
	local ok, address = pcall(getAddressOf, object)
	if ok then return address end
	return nil
end

local function own(object)
	local address = object ~= nil and addressOf(object) or nil
	if address ~= nil then ownObjects[address] = { world = currentWorld(), adopted = false } end
	return object
end

local function disown(object)
	local address = object ~= nil and addressOf(object) or nil
	if address ~= nil then ownObjects[address] = nil end
end

-- getValid for objects of any origin, plus our own objects that the backend has not adopted yet
local function isAlive(object)
	if object == nil or type(object) ~= "userdata" then return nil end
	local address = addressOf(object)
	local record = address ~= nil and ownObjects[address] or nil
	if uevrUtils.getValid(object) ~= nil then
		if record ~= nil then record.adopted = true end
		return object
	end
	if record == nil then return nil end
	if record.adopted or record.world ~= currentWorld() then
		-- accepted before and rejected now: destroyed by something else (or its level is gone). Forget it.
		ownObjects[address] = nil
		return nil
	end
	return object -- new, not adopted yet
end

local function getNumber(tbl, index, name, default)
	if type(tbl) ~= "table" then return default end
	local v = tbl[index]
	if v == nil and name ~= nil then v = tbl[name] end
	if v == nil then return default end
	return v
end

--------------------------- Widget lookup ---------------------------

-- The libs cache class objects by name, and after a save load that cache still hands back the class object
-- from before the load: GetAllWidgetsOfClass then finds nothing although the widget is on screen (measured in
-- Hellraiser). So this module keeps its own cache, drops it on every level change and asks for an uncached
-- lookup. A lookup is a hash hit when the class exists but a full object array walk when it does not
-- (hundreds of ms in large games), so fresh lookups are limited to one per class every few seconds.
local function getClassCached(className, refresh)
	if className == nil or className == "" then return nil end
	local class = classCache[className]
	if class ~= nil and refresh ~= true then return class end
	local now = os.clock()
	if classCheckedAt[className] ~= nil and now - classCheckedAt[className] < CLASS_LOOKUP_INTERVAL then return class end
	classCheckedAt[className] = now
	class = uevrUtils.get_class(className, true)
	classCache[className] = class
	return class
end

local function getTopLevelWidgets(class)
	local found = {}
	---@diagnostic disable-next-line: undefined-field
	WidgetBlueprintLibrary:GetAllWidgetsOfClass(uevrUtils.get_world(), found, class, true)
	return found
end

-- the live top level instance of a widget class that belongs to the local player, or nil
local function findTopLevelWidget(className)
	local class = getClassCached(className)
	if class == nil or WidgetBlueprintLibrary == nil then return nil end
	local found = getTopLevelWidgets(class)
	if #found == 0 then
		-- nothing on screen for this class: make sure it is not a class object left over from before a load
		local fresh = getClassCached(className, true)
		if fresh ~= nil and fresh ~= class then found = getTopLevelWidgets(fresh) end
	end
	local playerController = uevr.api:get_player_controller(0)
	for _, widget in ipairs(found) do
		if uevrUtils.getValid(widget) ~= nil then
			local owner = widget.GetOwningPlayer ~= nil and widget:GetOwningPlayer() or nil
			if owner == nil or playerController == nil or owner == playerController then
				return widget
			end
		end
	end
	-- a widget this module took off the screen and then lost track of (its component was destroyed by
	-- something else) is in no viewport, so it is not in the list above
	local known = getLive(knownWidgets[className], "IsInViewport")
	if known ~= nil then
		local detached = try("checkKnownWidget", function() return not known:IsInViewport() end)
		if detached == true then return known end
	end
	return nil
end

-- first widget with that name inside one widget tree: panel children and content slots, not the trees of nested
-- UserWidgets (same walk as libs/widget.lua findWidget, done here so older lib sets without widget.lua work too)
local function findInTree(start, name)
	local found = nil
	local function visit(widget)
		if widget == nil or found ~= nil then return end
		if widget:get_fname():to_string() == name then
			found = widget
			return
		end
		-- a content widget (Border, SizeBox...) is a panel too: its content is child 0, so it is not walked twice
		-- (walking both doubled the work at every nesting level, measured in Outer Worlds 2's HUD)
		if widget.GetChildrenCount ~= nil then
			for i = 0, widget:GetChildrenCount() - 1 do visit(widget:GetChildAt(i)) end
		elseif widget.GetContent ~= nil then
			visit(widget:GetContent())
		end
	end
	visit(start)
	return found
end

-- The part name may be a path: "PlayerStatsDisplay/HealthBar" finds PlayerStatsDisplay in the root's tree, then
-- HealthBar inside PlayerStatsDisplay's own tree (a nested UserWidget). "/" never occurs in a widget name, so a
-- plain name works as before. A step that is not a UserWidget continues in that widget's children.
local function findChildWidget(root, childName)
	if childName == nil or childName == "" then return root end
	local found = nil
	try("findChildWidget", function()
		local current = root
		for name in string.gmatch(childName, "[^/]+") do
			local tree = current.WidgetTree ~= nil and uevrUtils.getValid(current.WidgetTree) or nil
			local start = tree ~= nil and tree.RootWidget or (current ~= root and current or nil)
			current = start ~= nil and findInTree(start, name) or nil
			if current == nil then return end
		end
		found = current
	end)
	return found
end

--------------------------- Component helpers ---------------------------

-- Sets the blend mode and then the matching engine material, which is the only route that works on both
-- UE 5.5 (material exists as soon as the component does) and UE 5.6. Verified in Hellraiser (5.6).
local function applyBlendMode(component, blendMode, twoSided)
	if blendMode == nil then blendMode = M.BlendMode.TRANSPARENT end
	if twoSided == nil then twoSided = true end
	try("applyBlendMode", function()
		component.BlendMode = blendMode
		if component.SetTwoSided ~= nil then component:SetTwoSided(twoSided) end
		local names = blendMaterialProperties[blendMode]
		local material = names ~= nil and component[names[twoSided and 1 or 2]] or nil
		if uevrUtils.getValid(material) ~= nil then
			component:SetMaterial(0, material)
		end
	end)
end

local function configureDisplayComponent(component)
	if component.SetCastShadow ~= nil then component:SetCastShadow(false) end
	if component.SetTickWhenOffscreen ~= nil then component:SetTickWhenOffscreen(true) end
	-- a component that does not tick never draws, so it would have no render target while the game is paused
	if component.SetTickableWhenPaused ~= nil then component:SetTickableWhenPaused(true) end
	-- without this a small component can be culled (primitives only; a Region anchor is a plain SceneComponent)
	try("boundsScale", function()
		if component:is_a(uevrUtils.get_class("Class /Script/Engine.PrimitiveComponent")) then component.BoundsScale = 10 end
	end)
end

-- the redraw rate (hud.setRedrawRate) on a WidgetComponent that draws game widgets
local function setRedrawTimeNow(component) component.RedrawTime = redrawTime end
local function applyRedrawTime(component)
	if component ~= nil then try("redrawTime", setRedrawTimeNow, component) end
end

local function destroyComponent(component)
	if isAlive(component) == nil then return end
	try("destroyComponent", function()
		if component.SetWidget ~= nil then component:SetWidget(nil) end
		uevrUtils.detachAndDestroyComponent(component, true, false)
	end)
	disown(component)
end

--------------------------- Shared widgets ---------------------------

-- A game widget is NEVER taken off the screen (2026-10-16). Outer Worlds 2's UI manager keeps its own list of the
-- widgets it shows; RemoveFromParent took HUD_BP_C off that list, AddToViewport did not put it back, and the next input
-- that made the manager look its HUD up crashed the game (null read; proven by reading the list before and after a
-- Region build). Instead the widget stays where the game put it, and a host UserWidget of our own shows the SAME
-- content: the host's root is the game widget's root, so both share one Slate widget (bindings, animations and the
-- game's own show/hide keep working). The copy on the screen is made invisible with render opacity 0 on the game
-- widget (its visibility is left to the game, which may test it); the game's own opacity and visibility changes are
-- mirrored onto the host every frame. Approach from jbusfield's libs/widgetcomponent.lua (Hogwarts Legacy).
local hostClass = nil		-- { class, world } (class nil = none found in this world; not searched again until a level change)
local pendingRefresh = {}	-- released content waiting to be shown again on the screen: { widget, visibility, time, world }
local isScriptResetting = false

local function createWidgetOfClass(class)
	return try("createHostWidget", function()
		---@diagnostic disable-next-line: undefined-field
		return WidgetBlueprintLibrary:Create(uevrUtils.get_world(), class, uevr.api:get_player_controller(0))
	end)
end

-- The host's class. First choice: the engine's own UserWidget - no Blueprint and no game code at all; the engine creates
-- it (checked in Stalker 2, 2026-10-16). Fallback (as jbusfield's widget.lua): a loaded widget Blueprint class directly
-- under UserWidget with no event graph, found through the engine's widget search (UEVR's object listing is blind in
-- Stalker 2: it returned 1 of 417 widgets). A miss is remembered for the world.
local function getHostClass()
	local world = currentWorld()
	if hostClass ~= nil and hostClass.world == world and (hostClass.class == nil or uevrUtils.getValid(hostClass.class) ~= nil) then
		return hostClass.class
	end
	hostClass = { world = world }
	local userWidget = uevrUtils.get_class("Class /Script/UMG.UserWidget")
	local probe = userWidget ~= nil and createWidgetOfClass(userWidget) or nil
	if probe ~= nil and try("probeHost", function() return probe.WidgetTree ~= nil end) == true then
		hostClass.class = userWidget
		M.print("Host widget class Class /Script/UMG.UserWidget")
		return userWidget
	end
	try("findHostClass", function()
		local blueprintClass = uevrUtils.get_class("Class /Script/UMG.WidgetBlueprintGeneratedClass")
		local found = {}
		---@diagnostic disable-next-line: undefined-field
		WidgetBlueprintLibrary:GetAllWidgetsOfClass(uevrUtils.get_world(), found, userWidget, false)
		local seen = {}
		for _, widget in ipairs(found) do
			local class = widget:get_class()
			local name = class:get_full_name()
			if not seen[name] then
				seen[name] = true
				local super = class:get_super_struct()
				if super ~= nil and super:get_full_name() == "Class /Script/UMG.UserWidget" and class:is_a(blueprintClass) and class.UberGraphFunction == nil then
					hostClass.class = class
					M.print("Host widget class " .. name)
					return
				end
			end
		end
	end)
	if hostClass.class == nil then
		M.print("No host widget class found in this level: game widgets are left on the flat screen", LogLevel.Error)
	end
	return hostClass.class
end

-- shows root's content in a new host widget; the original stays on the screen, invisible. Returns the share or nil
local function shareWidget(root)
	local inner = try("readInnerRoot", function() return root.WidgetTree.RootWidget end)
	if inner == nil then return nil end
	local class = getHostClass()
	if class == nil then return nil end
	local host = createWidgetOfClass(class)
	if host == nil then return nil end
	own(host) -- just made: getValid can reject it for seconds on some backends
	if try("shareContent", function()
		host.WidgetTree.RootWidget = inner
		return true
	end) ~= true then
		disown(host)
		return nil
	end
	local share = { root = root, inner = inner, host = host, world = currentWorld(), gameOpacity = 1.0 }
	try("hideOriginal", function()
		share.gameOpacity = root:GetRenderOpacity()
		share.gameVisibility = root:GetVisibility()
		host:SetVisibility(share.gameVisibility)
		host:SetRenderOpacity(share.gameOpacity)
		root:SetRenderOpacity(0.0)
	end)
	return share
end

-- HUD widgets usually live outside the level: Hellraiser's under its GameInstance, Outer Worlds 2's and Stalker 2's
-- under the game viewport (all in /Engine/Transient), so they survive a level change or save load. Such a widget is not
-- freed with the old level and must get back what this module changed on it (render opacity, the brief collapse of a
-- release), or it stays invisible / collapsed for good (seen in Hellraiser 2026-10-17: a release during a load left
-- W_PlayerInfo's content collapsed). Level objects keep the rule: other-world objects are forgotten, never touched.
local function persistsAcrossLevels(object)
	if object == nil then return false end
	return try("persistCheck", function()
		return uevrUtils.getValid(object) ~= nil and object:get_full_name():find(" /Engine/Transient%.") ~= nil
	end) == true
end

-- every frame: the game's own opacity / visibility changes go to the host, the screen copy stays invisible
local function keepSharedNow(share)
	local opacity = share.root:GetRenderOpacity()
	if opacity > 0.0 then
		share.gameOpacity = opacity
		share.host:SetRenderOpacity(opacity)
		share.root:SetRenderOpacity(0.0)
	end
	local visibility = share.root:GetVisibility()
	if visibility ~= share.gameVisibility then
		share.gameVisibility = visibility
		share.host:SetVisibility(visibility)
	end
end

local function keepShared(share)
	if share == nil or share.world ~= currentWorld() then return end
	try("keepShared", keepSharedNow, share)
end

-- first half of a release: the content leaves the host before the host's Slate is released (or the content's Slate
-- would be released with it)
local function detachShared(share)
	if share == nil or share.world ~= currentWorld() then return end -- went with its level: forget, never touch
	try("detachShared", function()
		share.host.WidgetTree.RootWidget = uevrUtils.spawn_object("Class /Script/UMG.CanvasPanel", share.host.WidgetTree)
	end)
	disown(share.host)
end

-- second half: the original is made visible again. The screen does not redraw released content until its visibility
-- changes for a moment (jbusfield), so it is collapsed briefly; skipped on a script reset, where the delayed restore
-- would never run
local function restoreShared(share)
	if share == nil then return end
	-- after a level change only a widget that outlives levels is touched (see persistsAcrossLevels)
	if share.world ~= currentWorld() and not persistsAcrossLevels(share.root) then return end
	local root = getLive(share.root, "SetRenderOpacity")
	if root == nil then return end
	try("restoreShared", function()
		root:SetRenderOpacity(share.gameOpacity or 1.0)
		root:InvalidateLayoutAndVolatility()
	end)
	if isScriptResetting then return end
	local inner = getLive(share.inner, "SetVisibility")
	if inner == nil then return end
	try("refreshShared", function()
		table.insert(pendingRefresh, { widget = inner, visibility = inner:GetVisibility(), time = os.clock() + 0.25, world = currentWorld() })
		inner:SetVisibility(ESlateVisibility_Collapsed)
	end)
end

local function updatePendingRefresh()
	if #pendingRefresh == 0 then return end
	local now, world = os.clock(), currentWorld()
	for i = #pendingRefresh, 1, -1 do
		local entry = pendingRefresh[i]
		if entry.world ~= world then
			-- level changed: a widget that outlives levels gets its visibility back now, anything else is forgotten
			table.remove(pendingRefresh, i)
			if persistsAcrossLevels(entry.widget) then
				local widget = getLive(entry.widget, "SetVisibility")
				if widget ~= nil then try("refreshSharedDone", function() widget:SetVisibility(entry.visibility) end) end
			end
		elseif now >= entry.time then
			table.remove(pendingRefresh, i)
			local widget = getLive(entry.widget, "SetVisibility")
			if widget ~= nil then try("refreshSharedDone", function() widget:SetVisibility(entry.visibility) end) end
		end
	end
end

--------------------------- Region display ---------------------------

-- anchor (carries the user transform, one unit = one draw pixel) + plane mesh + our own render target. Both components
-- live on the one helper actor create_component_of_class spawns, so destroying the anchor with its owner removes all.
local function createRegionDisplay(state)
	local anchor = own(uevrUtils.create_component_of_class("Class /Script/Engine.SceneComponent", true, nil, false, nil, "uevrlib_hud"))
	if anchor == nil then return false end
	state.component = anchor
	local owner = try("regionAnchorOwner", function() return anchor:GetOwner() end)
	if owner == nil then return false end

	local mesh = own(uevrUtils.createStaticMeshComponent(REGION_MESH, { visible = true, collisionEnabled = false, parent = owner, tag = "uevrlib_hud" }))
	if mesh == nil then return false end
	state.display = mesh
	try("regionMeshSetup", function()
		mesh:K2_AttachTo(anchor, fname(""), 0, false)
		if mesh.SetCastShadow ~= nil then mesh:SetCastShadow(false) end
		mesh.BoundsScale = 10
	end)

	local target = try("regionRenderTarget", function()
		local clear = uevrUtils.color_from_rgba(0, 0, 0, 0)
		return kismet_rendering_library:CreateRenderTarget2D(uevrUtils.get_world(), state.drawWidth, state.drawHeight, RTF_RGBA8_SRGB, clear, false, false)
	end)
	if target == nil then return false end -- just made: getValid can reject it (see ownObjects)
	own(target)
	target.TargetGamma = 1.0 -- the canvas copy is bit exact only with gamma 1 (otherwise pow(1/2.2) is applied)
	state.renderTarget = target
	return true
end

-- the plane inside the anchor: centred on the pivot, sized drawWidth x drawHeight anchor units
local function placeRegionMesh(definition, state)
	if isAlive(state.display) == nil then return end
	local appearance = definition.appearance or {}
	local px = getNumber(appearance.pivot, 1, "X", 0.5)
	local py = getNumber(appearance.pivot, 2, "Y", 0.5)
	local w, h = state.drawWidth, state.drawHeight
	-- anchor frame as seen from the front (+X): right = -Y, up = +Z (widget y grows downwards)
	local position = { 0, (px - 0.5) * w, (py - 0.5) * h }
	try("placeRegionMesh", function()
		-- plane X carries the texture's width, plane Y its height (see REGION_MESH_ROTATION)
		uevrUtils.set_component_relative_transform(state.display, position, REGION_MESH_ROTATION, { w / REGION_MESH_SIZE, h / REGION_MESH_SIZE, 1 })
	end)
end

-- (re)creates the plane's material instance for a blend mode and points it at our render target
local function applyRegionMaterial(state, blendMode, twoSided)
	if blendMode == nil then blendMode = M.BlendMode.TRANSPARENT end
	if twoSided == nil then twoSided = true end
	local names = regionMaterials[blendMode] or regionMaterials[M.BlendMode.TRANSPARENT]
	local name = names[twoSided and 1 or 2]
	try("applyRegionMaterial", function()
		-- the engine's own widget material, read from the source WidgetComponent: present in every game that has
		-- widget components, whatever the cook kept (Stalker 2 has no loadable /Engine/EngineMaterials MIC by path)
		local parent = nil
		local properties = blendMaterialProperties[blendMode] or blendMaterialProperties[M.BlendMode.TRANSPARENT]
		local sourceComponent = state.source ~= nil and isAlive(state.source.component) or nil
		if sourceComponent ~= nil then
			parent = uevrUtils.getValid(sourceComponent[properties[twoSided and 1 or 2]])
		end
		if parent == nil then
			parent = uevrUtils.getLoadedAsset(string.format(REGION_MATERIAL_PATH, name, name))
		end
		if uevrUtils.getValid(parent) == nil then
			M.print("Region material " .. name .. " not found", LogLevel.Warning)
			return
		end
		local mid = own(state.display:CreateDynamicMaterialInstance(0, parent, fname("")))
		if mid == nil then return end
		mid:SetTextureParameterValue(fname("SlateUI"), state.renderTarget)
		mid:SetScalarParameterValue(fname("OpacityFromTexture"), 1.0)
		state.mid = mid
	end)
end

--------------------------- Region source ---------------------------

local function getViewportLayoutSize()
	local width, height = 1920, 1080
	try("getViewportLayoutSize", function()
		local world = uevrUtils.get_world()
		---@diagnostic disable-next-line: undefined-field
		local size = WidgetLayoutLibrary:GetViewportSize(world)
		---@diagnostic disable-next-line: undefined-field
		local scale = WidgetLayoutLibrary:GetViewportScale(world)
		if size ~= nil and scale ~= nil and scale > 0 then
			width, height = size.X / scale, size.Y / scale
		end
	end)
	return width, height
end

-- checked once per frame per source inside update() (every Region element of the source asks each frame)
local function sourceIsValid(source)
	if source == nil then return false end
	if inUpdate and source.validFrame == frameId then return source.validNow end
	local valid = isCurrentWorld(source) and isAlive(source.component) ~= nil and getLive(source.root, "RemoveFromParent") ~= nil
		and source.share ~= nil and isAlive(source.share.host) ~= nil
	if inUpdate then source.validFrame, source.validNow = frameId, valid end
	return valid
end

local releaseSourceShare -- defined below (acquireSource replaces a dead source with it)
local sourceSizeNoted = {} -- widget class -> true once the "sourceSize is ignored" note was logged

-- shows the big widget's content (shared, see shareWidget) in a WidgetComponent that keeps redrawing but is not drawn
-- in the world; the game's widget stays on the screen, invisible
local function acquireSource(definition)
	local key = definition.widget.class
	local source = sources[key]
	if sourceIsValid(source) then
		source.idleSince = nil
		return source
	end
	if source ~= nil then
		releaseSourceShare(source)
		sources[key] = nil
	end

	local root = findTopLevelWidget(key)
	if root == nil then return nil end

	-- Always the screen's layout size. The shared content is laid out twice a frame, on the screen and in this
	-- component; any other size (or aspect) moves its parts between the two, and the rectangles measured from the cached
	-- geometry then point at the wrong place (Hellraiser 2026-10-17: a saved 1920x1080 against a 3840x2400 screen
	-- layout copied empty space). definition.sourceSize is therefore ignored.
	local width, height = getViewportLayoutSize()
	if definition.sourceSize ~= nil and not sourceSizeNoted[key] then
		sourceSizeNoted[key] = true
		M.print("sourceSize is ignored for " .. key .. ": shared sources always use the screen layout size (" .. width .. "x" .. height .. ")")
	end

	local component = own(uevrUtils.create_component_of_class("Class /Script/UMG.WidgetComponent", true, nil, false, nil, "uevrlib_hud_source"))
	if component == nil then return nil end

	local zOrder = definition.restoreZOrder
	if zOrder == nil then
		-- not an engine property, but some games keep it on their widget base class
		zOrder = try("readZOrder", function() return root.ZOrder end) or 0
	end

	component:SetDrawSize(uevrUtils.vector2D(width, height))
	configureDisplayComponent(component)
	applyRedrawTime(component)
	if component.SetTickableWhenPaused ~= nil then component:SetTickableWhenPaused(true) end
	if component.SetRenderInMainPass ~= nil then component:SetRenderInMainPass(false) end
	if component.SetRenderInDepthPass ~= nil then component:SetRenderInDepthPass(false) end

	local share = shareWidget(root)
	if share == nil then
		destroyComponent(component)
		return nil
	end
	component:SetWidget(share.host)

	source = { key = key, root = root, share = share, component = component, width = width, height = height, zOrder = zOrder, world = currentWorld() }
	sources[key] = source
	M.print("Created source for " .. key .. " at " .. width .. "x" .. height .. " (shared, the game's widget stays on the screen)")
	return source
end

-- content out of the host, component gone, the game's widget visible on the screen again. Always restores a live
-- widget: with sharing nothing was taken away, so there is no case where leaving it invisible would be right
function releaseSourceShare(source)
	if not isCurrentWorld(source) then return end -- went with its level: forget, never touch
	detachShared(source.share)
	if isAlive(source.component) ~= nil then
		try("releaseSource", function() source.component:SetWidget(nil) end)
	end
	destroyComponent(source.component)
	restoreShared(source.share)
end

local function releaseSource(source, restore)
	if source == nil then return end
	sources[source.key] = nil
	releaseSourceShare(source)
end

local function sourceInUse(source)
	for _, state in pairs(runtime) do
		if state.source == source then return true end
	end
	return false
end

-- the game's widget stays on the screen now, so all there is to keep is the mirrored opacity / visibility
local function keepSourceWidget(source)
	keepShared(source.share)
end

-- Rectangle of a child inside the source, in source layout units. Only known once the source has drawn.
-- maps a widget's cached geometry into source pixels: origin and scale of the source's root widget
local function getSourceFrame(source)
	if slateLibrary == nil then
		slateLibrary = uevrUtils.find_default_instance("Class /Script/UMG.SlateBlueprintLibrary")
	end
	if slateLibrary == nil then return nil end
	local zero = uevrUtils.vector2D(0, 0)
	-- the shared content, not the game's widget: the content's geometry is the one the host drew last (the game's
	-- widget itself is only drawn on the screen)
	local frameWidget = source.share ~= nil and source.share.inner or source.root
	local rootGeometry = frameWidget:GetCachedGeometry()
	local rootSize = slateLibrary:GetAbsoluteSize(rootGeometry)
	if rootSize == nil or rootSize.X <= 0 or rootSize.Y <= 0 then return nil end
	local rootOrigin = slateLibrary:LocalToAbsolute(rootGeometry, zero)
	return { zero = zero, x = rootOrigin.X, y = rootOrigin.Y, scaleX = source.width / rootSize.X, scaleY = source.height / rootSize.Y }
end

local function getWidgetRect(frame, widget)
	local geometry = widget:GetCachedGeometry()
	local origin = slateLibrary:LocalToAbsolute(geometry, frame.zero)
	local size = slateLibrary:GetAbsoluteSize(geometry)
	return (origin.X - frame.x) * frame.scaleX, (origin.Y - frame.y) * frame.scaleY, size.X * frame.scaleX, size.Y * frame.scaleY
end

local function getChildRect(source, child)
	return try("getChildRect", function()
		local frame = getSourceFrame(source)
		if frame == nil then return nil end
		local x, y, w, h = getWidgetRect(frame, child)
		if w < 1 or h < 1 then return nil end
		return x, y, w, h
	end)
end

-- regionBounds = "content": the union of every visible widget inside the child (the child included), clamped to the
-- source. Game widgets often draw parts outside their own box - Hellraiser's loadout weapon selection is a 300x242
-- d-pad ring while its weapon slot icons sit above, below and beside it.
local CONTENT_WALK_LIMIT = 400
local CONTENT_REFRESH = 5.0 -- seconds; parts can appear without the child's own box changing (a new weapon slot)
local function getContentRect(source, child)
	return try("getContentRect", function()
		local frame = getSourceFrame(source)
		if frame == nil then return nil end
		local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
		local visited = 0
		local function walk(widget, depth)
			if widget == nil or depth > 16 or visited >= CONTENT_WALK_LIMIT then return end
			visited = visited + 1
			local visibility = widget.GetVisibility ~= nil and widget:GetVisibility() or nil
			if visibility == ESlateVisibility_Collapsed or visibility == ESlateVisibility_Hidden then return end
			if widget.GetCachedGeometry ~= nil then
				local x, y, w, h = getWidgetRect(frame, widget)
				if w >= 1 and h >= 1 then
					minX, minY = math.min(minX, x), math.min(minY, y)
					maxX, maxY = math.max(maxX, x + w), math.max(maxY, y + h)
				end
			end
			local tree = widget.WidgetTree -- a nested UserWidget keeps its content in its own tree
			if tree ~= nil and tree.RootWidget ~= nil then walk(tree.RootWidget, depth + 1) end
			if widget.GetChildrenCount ~= nil then
				for i = 0, widget:GetChildrenCount() - 1 do walk(widget:GetChildAt(i), depth + 1) end
			end
		end
		walk(child, 0)
		minX, minY = math.max(minX, 0), math.max(minY, 0)
		maxX, maxY = math.min(maxX, source.width), math.min(maxY, source.height)
		if maxX - minX < 1 or maxY - minY < 1 then return nil end
		return minX, minY, maxX - minX, maxY - minY
	end)
end

-- content bounds are only walked again when the child's own box changes or every CONTENT_REFRESH seconds
local function getCachedContentRect(state)
	local x, y, w, h = getChildRect(state.source, state.widget)
	if w == nil then return nil end
	local key = string.format("%.1f %.1f %.1f %.1f", x, y, w, h)
	local now = os.clock()
	if state.contentRect == nil or state.contentKey ~= key or now >= (state.contentRefreshAt or 0) then
		local cx, cy, cw, ch = getContentRect(state.source, state.widget)
		if cw == nil then return x, y, w, h end
		state.contentRect = { cx, cy, cw, ch }
		state.contentKey = key
		state.contentRefreshAt = now + CONTENT_REFRESH
	end
	return state.contentRect[1], state.contentRect[2], state.contentRect[3], state.contentRect[4]
end

local function resolveRegion(id, definition, state)
	local x, y, w, h = nil, nil, nil, nil
	if regionCallback ~= nil then
		x, y, w, h = try("regionCallback", regionCallback, id, definition, state.source)
	end
	if w == nil and type(definition.region) == "table" then
		x, y = getNumber(definition.region, 1, "x"), getNumber(definition.region, 2, "y")
		w, h = getNumber(definition.region, 3, "w"), getNumber(definition.region, 4, "h")
	end
	if w == nil and uevrUtils.getValid(state.widget) ~= nil then
		if definition.regionBounds == "content" then
			x, y, w, h = getCachedContentRect(state)
		else
			x, y, w, h = getChildRect(state.source, state.widget)
		end
	end
	if x == nil or y == nil or w == nil or h == nil or w < 1 or h < 1 then return nil end
	local padding = definition.regionPadding or 0
	return x - padding, y - padding, w + 2 * padding, h + 2 * padding
end

--------------------------- Region copy ---------------------------

-- Copies a UV rectangle of one render target into another. BLEND_Opaque keeps colour and alpha exactly when the target's TargetGamma is 1.0.
-- The Canvas out parameter is not relied on: BeginDrawCanvasToRenderTarget always hands back the world's
-- CanvasForRenderingToTarget, which is read from the world afterwards.
-- cutouts: rectangles { x, y, w, h } in display pixels made fully transparent after the copy (regionRest)
local function canvasCopy(sourceTarget, displayTarget, u, v, uSize, vSize, width, height, state, cutouts, cutoutCount)
	local world = currentWorld()
	if drawContext == nil then
		drawContext = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.DrawToRenderTargetContext")
	end
	if state.vecs == nil then
		state.vecs = {
			size = uevrUtils.vector2D(0, 0), position = uevrUtils.vector2D(0, 0), screenSize = uevrUtils.vector2D(0, 0),
			uv = uevrUtils.vector2D(0, 0), uvSize = uevrUtils.vector2D(0, 0), pivot = uevrUtils.vector2D(0.5, 0.5),
			white = uevrUtils.color_from_rgba(1, 1, 1, 1),
			clear = uevrUtils.color_from_rgba(0, 0, 0, 0),
			cutPosition = uevrUtils.vector2D(0, 0), cutSize = uevrUtils.vector2D(0, 0),
		}
	end
	local vecs = state.vecs
	vecs.screenSize.X, vecs.screenSize.Y = width, height
	vecs.uv.X, vecs.uv.Y = u, v
	vecs.uvSize.X, vecs.uvSize.Y = uSize, vSize

	kismet_rendering_library:BeginDrawCanvasToRenderTarget(world, displayTarget, nil, vecs.size, drawContext)
	drawContext.RenderTarget = displayTarget
	local canvas = world.CanvasForRenderingToTarget
	if canvas ~= nil then
		canvas:K2_DrawTexture(sourceTarget, vecs.position, vecs.screenSize, vecs.uv, vecs.uvSize, vecs.white, BLEND_Opaque, 0.0, vecs.pivot)
		-- opaque blend writes texture x colour including alpha, so a (0,0,0,0) colour leaves transparent pixels
		if cutouts ~= nil then
			for i = 1, cutoutCount or #cutouts do
				local cut = cutouts[i]
				vecs.cutPosition.X, vecs.cutPosition.Y = cut[1], cut[2]
				vecs.cutSize.X, vecs.cutSize.Y = cut[3], cut[4]
				canvas:K2_DrawTexture(sourceTarget, vecs.cutPosition, vecs.cutSize, vecs.uv, vecs.uvSize, vecs.clear, BLEND_Opaque, 0.0, vecs.pivot)
			end
		end
	end
	kismet_rendering_library:EndDrawCanvasToRenderTarget(world, drawContext)
	return canvas ~= nil
end

local function updateRegionCopy(id, definition, state)
	local source = state.source
	if not sourceIsValid(source) or isAlive(state.renderTarget) == nil then return end
	if state.rect == nil then return end

	-- read from the live component every frame; it is new (not adopted) right after the source is made
	local sourceTarget = source.component:GetRenderTarget()
	if sourceTarget == nil then return end

	local x, y, w, h = state.rect[1], state.rect[2], state.rect[3], state.rect[4]
	if canvasCopyAvailable == false then return end

	-- regionRest: the areas other elements of the same source show are cut out, so nothing appears twice (the
	-- rectangle tables are reused frame to frame)
	local cutouts, cutoutCount = nil, 0
	if definition.regionRest == true then
		cutouts = state.cutouts or {}
		state.cutouts = cutouts
		local scaleX, scaleY = state.drawWidth / w, state.drawHeight / h
		for otherId, other in pairs(runtime) do
			local otherDefinition = elements[otherId]
			if otherId ~= id and other.source == source and other.rect ~= nil and otherDefinition ~= nil and otherDefinition.regionRest ~= true then
				local r = other.rect
				cutoutCount = cutoutCount + 1
				local cut = cutouts[cutoutCount] or {}
				cut[1], cut[2], cut[3], cut[4] = (r[1] - x) * scaleX, (r[2] - y) * scaleY, r[3] * scaleX, r[4] * scaleY
				cutouts[cutoutCount] = cut
			end
		end
	end

	local ok = try("canvasCopy", canvasCopy, sourceTarget, state.renderTarget, x / source.width, y / source.height, w / source.width, h / source.height, state.drawWidth, state.drawHeight, state, cutouts, cutoutCount)
	if ok == true then stats.copies = stats.copies + 1 end
	if canvasCopyAvailable == nil then
		canvasCopyAvailable = ok == true
		if not canvasCopyAvailable then
			M.print("Canvas copy is not available on this game: Region elements stay empty", LogLevel.Error)
		end
	end
end

--------------------------- Attachment and appearance ---------------------------

local function resolveTarget(definition)
	local target = definition.target or {}
	local kind = target.type or M.Target.LEFT_CONTROLLER
	local socket = target.socket or ""
	if kind == M.Target.LEFT_HAND or kind == M.Target.RIGHT_HAND then
		if hands == nil then return nil end
		local hand = kind == M.Target.LEFT_HAND and Handed.Left or Handed.Right
		return uevrUtils.getValid(hands.getHandComponent(hand, target.componentName)), socket
	elseif kind == M.Target.PAWN_MESH then
		return uevrUtils.getValid(pawn, { target.meshProperty or "Mesh" }), socket
	elseif kind == M.Target.CUSTOM then
		if targetCallback == nil then return nil end
		local parent, customSocket = try("targetCallback", targetCallback, definition)
		return uevrUtils.getValid(parent), customSocket or socket
	end
	return nil
end

-- controllers are created on demand, everything else has to exist before a widget is taken off the screen
local function targetAvailable(definition)
	local kind = definition.target ~= nil and definition.target.type or M.Target.LEFT_CONTROLLER
	if controllerIDs[kind] ~= nil then return true end
	return resolveTarget(definition) ~= nil
end

local function attachComponent(definition, state)
	local component = state.component
	local kind = definition.target ~= nil and definition.target.type or M.Target.LEFT_CONTROLLER
	local attached = false
	if controllerIDs[kind] ~= nil then
		attached = controllers.attachComponentToController(controllerIDs[kind], component, definition.target ~= nil and definition.target.socket or "", 0, false, true) ~= false
		-- cached first, as attachComponentToController does: the world-wide search cannot see a new controller yet
		state.parent = controllers.getController(controllerIDs[kind], true) or controllers.getController(controllerIDs[kind])
	else
		local parent, socket = resolveTarget(definition)
		if parent ~= nil then
			attached = component:K2_AttachTo(parent, fname(socket), 0, false) ~= false
			state.parent = parent
		end
	end
	if attached then
		-- hiding the old parent propagates to children, so a component can arrive on a new parent still hidden
		if component.SetVisibility ~= nil then component:SetVisibility(true, false) end
	end
	return attached
end

local function applyTransform(definition, state)
	local transform = definition.transform or {}
	local scale = transform.scale
	if transform.widthCm ~= nil and state.drawWidth ~= nil and state.drawWidth > 0 then
		scale = transform.widthCm / state.drawWidth -- one draw unit is one world unit (cm) at scale 1
	end
	if scale == nil then scale = 0.05 end
	local playerScale = playerSettings[definition.id] ~= nil and playerSettings[definition.id].sizeScale or 1.0
	if type(scale) == "number" then
		scale = scale * playerScale
		scale = { scale, scale, scale }
	elseif playerScale ~= 1.0 then
		scale = { getNumber(scale, 1, "X", 1) * playerScale, getNumber(scale, 2, "Y", 1) * playerScale, getNumber(scale, 3, "Z", 1) * playerScale }
	end
	try("applyTransform", function()
		uevrUtils.set_component_relative_transform(state.component, transform.position or { 0, 0, 0 }, transform.rotation or { 0, 0, 0 }, scale)
	end)
end

-- the multiplier that cancels the game's exposure, 1.0 when there is no source
local function getExposureMultiplier(appearance)
	if appearance.exposure == false or exposureEV == nil then return 1.0 end
	local strength = appearance.exposureStrength or 1.0
	return (1.2 * 2 ^ exposureEV) ^ strength
end

local function applyTint(definition, state, force)
	local appearance = definition.appearance or {}
	local multiplier = getExposureMultiplier(appearance) * 2 ^ ((appearance.brightness or 0) + exposureStops)
	local maxTint = appearance.maxTint
	if maxTint ~= nil and multiplier > maxTint then multiplier = maxTint end
	local opacity = (appearance.opacity or 1.0) * (playerSettings[definition.id] ~= nil and playerSettings[definition.id].opacity or 1.0)
		* (state.visibility or 1.0) -- visibility rules (fade)
	if not force and state.lastMultiplier ~= nil and math.abs(multiplier - state.lastMultiplier) <= state.lastMultiplier * 0.01 and opacity == state.lastOpacity then
		return
	end
	state.lastMultiplier = multiplier
	state.lastOpacity = opacity
	local tint = appearance.tint
	local r, g, b = getNumber(tint, 1, "R", 1.0), getNumber(tint, 2, "G", 1.0), getNumber(tint, 3, "B", 1.0)
	try("applyTint", function()
		local color = uevrUtils.color_from_rgba(r * multiplier, g * multiplier, b * multiplier, opacity)
		if state.mode == M.Mode.REGION then
			if state.mid ~= nil then state.mid:SetVectorParameterValue(fname("TintColorAndOpacity"), color) end
		else
			state.component:SetTintColorAndOpacity(color)
		end
	end)
end

local function applyAppearance(definition, state)
	local appearance = definition.appearance or {}
	if state.mode == M.Mode.REGION then
		applyRegionMaterial(state, appearance.blendMode, appearance.twoSided)
		placeRegionMesh(definition, state)
		try("applyAppearance", function()
			if appearance.sortPriority ~= nil then state.display:SetTranslucentSortPriority(appearance.sortPriority) end
		end)
		if appearance.cylinderArcAngle ~= nil and not state.cylinderWarned then
			state.cylinderWarned = true
			M.print("cylinderArcAngle is not supported for Region elements (flat plane)", LogLevel.Warning)
		end
		applyTint(definition, state, true)
		return
	end
	local component = state.component
	applyBlendMode(component, appearance.blendMode, appearance.twoSided)
	try("applyAppearance", function()
		if appearance.pivot ~= nil and component.SetPivot ~= nil then
			component:SetPivot(uevrUtils.vector2D(getNumber(appearance.pivot, 1, "X", 0.5), getNumber(appearance.pivot, 2, "Y", 0.5)))
		end
		if appearance.cylinderArcAngle ~= nil and component.SetGeometryMode ~= nil then
			component:SetGeometryMode(1)
			component:SetCylinderArcAngle(appearance.cylinderArcAngle)
		end
		if appearance.gammaCorrection ~= nil then component.bApplyGammaCorrection = appearance.gammaCorrection end
		if appearance.sortPriority ~= nil and component.SetTranslucentSortPriority ~= nil then
			component:SetTranslucentSortPriority(appearance.sortPriority)
		end
	end)
	applyTint(definition, state, true)
end

local function executePostAttachCallbacks(id, state)
	for _, func in ipairs(postAttachCallbacks) do
		try("postAttachCallback", func, id, state.component, state.widget)
	end
end

--------------------------- Element build and teardown ---------------------------

-- keepSource: a rebuild is about to use the same source again, so the game widget is not handed back to the screen
-- and taken again (it stays in its component; validateElements releases a source left idle for SOURCE_IDLE_RELEASE)
local function destroyElement(id, restore, keepSource)
	local state = runtime[id]
	if state == nil then return end
	runtime[id] = nil

	if not isCurrentWorld(state) then
		-- went with its level: forget the element (and its source once nothing uses it), never touch either - except a
		-- game widget that outlives levels, which gets its opacity back (restoreShared checks that)
		if state.source ~= nil and not sourceInUse(state.source) and sources[state.source.key] == state.source then
			sources[state.source.key] = nil
			restoreShared(state.source.share)
		end
		if state.mode == M.Mode.DIRECT then restoreShared(state.share) end
		return
	end

	if state.mode == M.Mode.HIDE then
		if restore ~= false and getLive(state.widget, "SetVisibility") ~= nil and state.previousVisibility ~= nil then
			try("restoreVisibility", function() state.widget:SetVisibility(state.previousVisibility) end)
		end
	elseif state.mode == M.Mode.DIRECT then
		-- content out of the host first, then the component, then the game's widget visible again (it never left)
		detachShared(state.share)
		if isAlive(state.component) ~= nil then
			try("clearDirectWidget", function() state.component:SetWidget(nil) end)
		end
		destroyComponent(state.component)
		restoreShared(state.share)
	elseif state.mode == M.Mode.REGION then
		destroyComponent(state.component) -- with its helper actor, which also holds the plane
		disown(state.display)
		disown(state.renderTarget)
		disown(state.mid)
		if state.source ~= nil and not sourceInUse(state.source) then
			if keepSource == true and sources[state.source.key] == state.source then
				state.source.idleSince = os.clock()
			else
				releaseSource(state.source, restore)
			end
		end
	end
end

local function finishComponent(id, definition, state)
	configureDisplayComponent(state.component)
	if not attachComponent(definition, state) then
		M.print("Could not attach element " .. id .. ", target not available yet")
		return false
	end
	applyTransform(definition, state)
	applyAppearance(definition, state)
	executePostAttachCallbacks(id, state)
	return true
end

local function buildHide(id, definition)
	local root = findTopLevelWidget(definition.widget.class)
	if root == nil then return nil end
	local widget = findChildWidget(root, definition.widget.child)
	if uevrUtils.getValid(widget) == nil then return nil end
	local state = { mode = M.Mode.HIDE, widget = widget, root = root, world = currentWorld() }
	try("hideWidget", function()
		state.previousVisibility = widget:GetVisibility()
		widget:SetVisibility(ESlateVisibility_Collapsed)
	end)
	return state
end

-- Many games lay their HUD widgets out for the whole screen: a CanvasPanel (often under a ScaleBox) whose children are
-- anchored to the screen centre or edges at large offsets (Hellraiser's loadout: up to 1740 px from the centre). Drawn
-- into a smaller WidgetComponent, those children land outside it and the panel stays blank. Warn instead of failing
-- silently: such a widget belongs in REGION mode (or Direct at the full viewport layout size).
local function warnIfLaidOutForScreen(id, widget, width, height)
	try("checkDirectLayout", function()
		local root = widget.WidgetTree ~= nil and widget.WidgetTree.RootWidget or nil
		if root ~= nil and root:get_class():get_fname():to_string() == "ScaleBox" and root.GetChildrenCount ~= nil and root:GetChildrenCount() > 0 then
			root = root:GetChildAt(0)
		end
		if root == nil or root:get_class():get_fname():to_string() ~= "CanvasPanel" then return end
		local total, outside = 0, 0
		for i = 0, root:GetChildrenCount() - 1 do
			local child = root:GetChildAt(i)
			local layout = child ~= nil and child.Slot ~= nil and child.Slot.LayoutData or nil
			if layout ~= nil and child:GetVisibility() ~= ESlateVisibility_Collapsed then
				total = total + 1
				local anchors, offsets, alignment = layout.Anchors, layout.Offsets, layout.Alignment
				local w, h = offsets.Right, offsets.Bottom
				if child.Slot.bAutoSize then
					local desired = child:GetDesiredSize()
					w, h = desired.X, desired.Y
				end
				local left, top, right, bottom
				if anchors.Minimum.X == anchors.Maximum.X then
					left = anchors.Minimum.X * width + offsets.Left - alignment.X * w
					right = left + w
				else -- stretched: Left / Right are margins
					left, right = anchors.Minimum.X * width + offsets.Left, anchors.Maximum.X * width - offsets.Right
				end
				if anchors.Minimum.Y == anchors.Maximum.Y then
					top = anchors.Minimum.Y * height + offsets.Top - alignment.Y * h
					bottom = top + h
				else
					top, bottom = anchors.Minimum.Y * height + offsets.Top, anchors.Maximum.Y * height - offsets.Bottom
				end
				if right <= 0 or left >= width or bottom <= 0 or top >= height then outside = outside + 1 end
			end
		end
		local message = nil
		if outside > 0 then
			message = string.format("%d of %d parts of %s are laid out outside the %.0fx%.0f draw size (the widget is "
				.. "laid out for the whole screen) and will not show. Use REGION mode for it, or Direct without drawSize "
				.. "(full viewport layout size).", outside, total, widget:get_class():get_fname():to_string(), width, height)
		end
		layoutWarnings[id] = message
		-- logged once per element and draw size, not on every rebuild
		local key = string.format("%.0fx%.0f", width, height)
		if message ~= nil and layoutWarned[id] ~= key then
			M.print("Direct element " .. id .. ": " .. message, LogLevel.Warning)
		end
		layoutWarned[id] = key
	end)
end

local function buildDirect(id, definition)
	local widget = findTopLevelWidget(definition.widget.class)
	if widget == nil then return nil end

	local state = { mode = M.Mode.DIRECT, widget = widget, world = currentWorld() }
	knownWidgets[definition.widget.class] = widget
	state.zOrder = definition.restoreZOrder or try("readZOrder", function() return widget.ZOrder end) or 0

	local width, height = getViewportLayoutSize()
	width = getNumber(definition.drawSize, 1, "X", width)
	height = getNumber(definition.drawSize, 2, "Y", height)
	state.drawWidth, state.drawHeight = width, height
	warnIfLaidOutForScreen(id, widget, width, height)

	-- the widget stays on the screen (invisible) and its content is shared into a host in our component: see
	-- shareWidget. Not uevrUtils.createWidgetComponent: it rejects a widget getValid does not accept yet (a new host)
	local component = own(uevrUtils.create_component_of_class("Class /Script/UMG.WidgetComponent", true, nil, false, nil, "uevrlib_hud"))
	if component == nil then return nil end
	local share = shareWidget(widget)
	if share == nil then
		destroyComponent(component)
		return nil
	end
	state.share = share
	applyRedrawTime(component)
	try("setupDirectComponent", function()
		component:SetWidget(share.host)
		component:SetDrawSize(uevrUtils.vector2D(width, height))
		if definition.drawAtDesiredSize == true and component.SetDrawAtDesiredSize ~= nil then
			component:SetDrawAtDesiredSize(true)
		end
	end)
	state.component = component
	runtime[id] = state
	if not finishComponent(id, definition, state) then
		destroyElement(id, true)
		return nil
	end
	return state
end

-- second half of a Region build. Returns false while the child's rectangle is not known yet (it only exists
-- once the source has drawn), true when the element is complete, nil when it failed for good.
local function completeRegion(id, definition, state)
	local x, y, w, h = resolveRegion(id, definition, state)
	if w == nil then return false end
	state.rect = { x, y, w, h }

	local resolution = definition.resolutionScale or 1.0
	state.drawWidth, state.drawHeight = math.max(1, math.floor(w * resolution + 0.5)), math.max(1, math.floor(h * resolution + 0.5))

	if not createRegionDisplay(state) then return nil end
	if not finishComponent(id, definition, state) then return nil end
	state.pending = false
	return true
end

local function buildRegion(id, definition)
	-- the part must exist before the widget is taken off the screen (a wrong name must not move the whole HUD)
	local childName = definition.widget.child
	if childName ~= nil and childName ~= "" and type(definition.region) ~= "table" then
		local existing = sources[definition.widget.class]
		local root = sourceIsValid(existing) and existing.root or findTopLevelWidget(definition.widget.class)
		if root == nil then return nil end
		if findChildWidget(root, childName) == nil then
			M.print("Element " .. id .. ": no part named " .. childName .. " in " .. definition.widget.class, LogLevel.Warning)
			retryAfter[id] = os.clock() + RETRY_BACKOFF
			return nil
		end
	end

	local source = acquireSource(definition)
	if source == nil then return nil end

	local state = { mode = M.Mode.REGION, source = source, pending = true, pendingSince = os.clock(), world = currentWorld() }
	local child = definition.widget.child
	-- the whole widget = its shared content (the game's widget itself is only drawn on the screen)
	state.widget = (child == nil or child == "") and source.share.inner or findChildWidget(source.root, child)
	runtime[id] = state -- registered first so the source is released through destroyElement on failure
	if completeRegion(id, definition, state) == nil then
		destroyElement(id, true)
		retryAfter[id] = os.clock() + RETRY_BACKOFF
		return nil
	end
	return state
end

local function playerDisabled(id)
	return playerSettings[id] ~= nil and playerSettings[id].enabled == false
end

local function buildElement(id)
	local definition = elements[id]
	if definition == nil or definition.enabled == false or not isEnabled or playerDisabled(id) then return end
	if definition.widget == nil or definition.widget.class == nil then return end
	if retryAfter[id] ~= nil and os.clock() < retryAfter[id] then return end
	if currentWorld() == nil then return end -- (loading) a state without a world would be forgotten at once and leak
	if definition.mode ~= M.Mode.HIDE and not targetAvailable(definition) then return end
	local state = nil
	if definition.mode == M.Mode.HIDE then
		state = buildHide(id, definition)
	elseif definition.mode == M.Mode.DIRECT then
		state = buildDirect(id, definition)
	else
		state = buildRegion(id, definition)
	end
	if state ~= nil then
		runtime[id] = state
		M.print("Built element " .. id .. " (" .. tostring(definition.mode) .. ")")
	end
end

-- The element's parent is still what its target resolves to now. Compared with the current target instead of asking
-- getValid, which rejects a new controller or hand for seconds on some backends (Outer Worlds 2). A target that cannot
-- be resolved right now keeps the element as it is; a different parent means a rebuild.
local function parentIsCurrent(definition, state)
	if state.parent == nil then return true end
	local kind = definition.target ~= nil and definition.target.type or M.Target.LEFT_CONTROLLER
	local current = nil
	if controllerIDs[kind] ~= nil then
		current = controllers.getController(controllerIDs[kind], true) or controllers.getController(controllerIDs[kind])
	else
		current = resolveTarget(definition)
	end
	if current == nil then return true end
	local currentAddress, parentAddress = addressOf(current), addressOf(state.parent)
	return currentAddress ~= nil and currentAddress == parentAddress
end

-- true when everything the element depends on is still alive
local function elementIsValid(definition, state)
	if not isCurrentWorld(state) then return false end
	if state.mode == M.Mode.HIDE then
		return getLive(state.widget, "SetVisibility") ~= nil
	end
	if state.pending == true then return sourceIsValid(state.source) end
	if isAlive(state.component) == nil then return false end
	if not parentIsCurrent(definition, state) then return false end
	if state.mode == M.Mode.DIRECT then
		return getLive(state.widget, "RemoveFromParent") ~= nil and state.share ~= nil and isAlive(state.share.host) ~= nil
	end
	return sourceIsValid(state.source)
end

local function validateElements()
	headNeeded = nil -- picks up elements built, removed or changed since
	for _, id in ipairs(elementOrder) do
		local definition = elements[id]
		local state = runtime[id]
		if state ~= nil and (definition == nil or definition.enabled == false or not isEnabled or playerDisabled(id)) then
			destroyElement(id, true)
		elseif state ~= nil and not elementIsValid(definition, state) then
			M.print("Element " .. id .. " lost its widget, component or parent, rebuilding")
			destroyElement(id, false, true)
			buildElement(id)
		elseif state == nil then
			buildElement(id)
		elseif state.mode == M.Mode.REGION then
			keepSourceWidget(state.source)
			-- the child can move or resize, e.g. when the game changes HUD scale
			local x, y, w, h = resolveRegion(id, definition, state)
			if w ~= nil and state.pending ~= true then
				local old = state.rect
				if old == nil or math.abs(old[1] - x) > 0.5 or math.abs(old[2] - y) > 0.5 or math.abs(old[3] - w) > 0.5 or math.abs(old[4] - h) > 0.5 then
					state.rect = { x, y, w, h }
				end
			end
		elseif state.mode == M.Mode.HIDE then
			try("keepHidden", function()
				if state.widget:GetVisibility() ~= ESlateVisibility_Collapsed then
					state.widget:SetVisibility(ESlateVisibility_Collapsed)
				end
			end)
		end
	end
	-- sources kept through a rebuild but no longer used by any element go back to the screen
	for key, source in pairs(sources) do
		if source.idleSince ~= nil and not sourceInUse(source) and os.clock() - source.idleSince >= SOURCE_IDLE_RELEASE then
			releaseSource(source, true)
		end
	end
end

--------------------------- Update ---------------------------

local function updateExposure(delta)
	if exposureSource == nil then
		exposureEV = nil
		return
	end
	local value = try("exposureSource", exposureSource)
	if type(value) ~= "number" then
		exposureEV = nil
		return
	end
	if exposureEV == nil then
		exposureEV = value
	else
		exposureEV = exposureEV + (value - exposureEV) * math.min(1.0, delta * EXPOSURE_RATE)
	end
end

--------------------------- Visibility rules ---------------------------
-- definition.visibility = {
--     fadeTime = 0.25,                                              -- seconds for a full fade
--     lookAt   = { enabled, inner = 15, outer = 30, minimum = 0 },  -- degrees between view direction and the element
--     facing   = { enabled, inner = 40, outer = 70, minimum = 0 },  -- degrees between the element's front and the eyes
--     distance = { enabled, near = 40, far = 70, minimum = 0 },     -- cm from the head
--     hideWhenPaused, hideInCutscene, hideInUEVRMenu, hideWhenCharacterHidden = true / false
-- }
-- Every enabled rule gives a factor 0..1; the lowest one multiplies the element's opacity (with a fade). At 0 the
-- element's mesh is hidden and a Region element stops copying. Elements without rules are not evaluated at all.

local visibilityCallbacks = {}
local gameState = { paused = false, cutscene = false, uevrMenu = false, characterHidden = false }
local hmdCreateTried = false

local function ruleOn(rule) return type(rule) == "table" and rule.enabled == true end

local function hasRules(visibility)
	if #visibilityCallbacks > 0 then return true end
	if type(visibility) ~= "table" then return false end
	return ruleOn(visibility.lookAt) or ruleOn(visibility.facing) or ruleOn(visibility.distance)
		or visibility.hideWhenPaused == true or visibility.hideInCutscene == true
		or visibility.hideInUEVRMenu == true or visibility.hideWhenCharacterHidden == true
end

-- 1 up to `full`, 0 from `none` on, linear in between, then lifted to `minimum`
local function ramp(value, full, none, minimum)
	local t
	if value <= full then t = 1.0
	elseif value >= none then t = 0.0
	else t = 1.0 - (value - full) / (none - full) end
	minimum = minimum or 0.0
	return minimum + (1.0 - minimum) * t
end

local function angleBetween(ax, ay, az, bx, by, bz)
	local dot = math.max(-1.0, math.min(1.0, ax * bx + ay * by + az * bz))
	return math.deg(math.acos(dot))
end

-- head position and view direction from the HMD motion controller (created once if nothing made it yet)
local function getHead()
	-- cached first: a controller made a moment ago is not visible to the search (or to getValid) on some backends
	local hmd = controllers.getController(2, true) or controllers.getController(2)
	if hmd == nil and not hmdCreateTried then
		hmdCreateTried = true
		try("createHMDController", controllers.createController, 2)
		hmd = controllers.getController(2, true) or controllers.getController(2)
	end
	if hmd == nil then return nil end
	return try("readHead", function()
		local p, f = hmd:K2_GetComponentLocation(), hmd:GetForwardVector()
		return { x = p.X, y = p.Y, z = p.Z, fx = f.X, fy = f.Y, fz = f.Z }
	end)
end

local function evaluateVisibility(id, definition, state, head)
	local v = definition.visibility or {}
	local debug = {}
	local factor = 1.0
	if (v.hideWhenPaused and gameState.paused) or (v.hideInCutscene and gameState.cutscene)
		or (v.hideInUEVRMenu and gameState.uevrMenu) or (v.hideWhenCharacterHidden and gameState.characterHidden) then
		debug.state = 0.0
		factor = 0.0
	end
	if factor > 0 and head ~= nil and (ruleOn(v.lookAt) or ruleOn(v.facing) or ruleOn(v.distance)) then
		try("visibilityGeometry", function()
			local p = state.component:K2_GetComponentLocation()
			local dx, dy, dz = p.X - head.x, p.Y - head.y, p.Z - head.z
			local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
			if ruleOn(v.distance) then
				debug.distance = ramp(dist, v.distance.near or 40, v.distance.far or 70, v.distance.minimum)
				factor = math.min(factor, debug.distance)
			end
			if dist > 0.001 then
				local nx, ny, nz = dx / dist, dy / dist, dz / dist
				if ruleOn(v.lookAt) then
					local angle = angleBetween(head.fx, head.fy, head.fz, nx, ny, nz)
					debug.lookAt = ramp(angle, v.lookAt.inner or 15, v.lookAt.outer or 30, v.lookAt.minimum)
					factor = math.min(factor, debug.lookAt)
				end
				if ruleOn(v.facing) then
					-- the readable front of a display looks along its component's forward axis
					local f = state.component:GetForwardVector()
					local angle = angleBetween(f.X, f.Y, f.Z, -nx, -ny, -nz)
					debug.facing = ramp(angle, v.facing.inner or 40, v.facing.outer or 70, v.facing.minimum)
					factor = math.min(factor, debug.facing)
				end
			end
		end)
	end
	for _, callback in ipairs(visibilityCallbacks) do
		local result = try("visibilityCallback", callback, id, definition)
		if type(result) == "number" then
			debug.callback = math.max(0.0, math.min(1.0, result))
			factor = math.min(factor, debug.callback)
		end
	end
	debug.target = factor
	state.visibilityDebug = debug
	return factor
end

local function setDisplayShown(state, shown)
	local display = state.mode == M.Mode.REGION and state.display or state.component
	if isAlive(display) ~= nil and display.SetVisibility ~= nil then
		try("setDisplayShown", function() display:SetVisibility(shown, false) end)
	end
end

-- per frame for built elements: fades state.visibility towards the rules' target
local function updateVisibility(id, definition, state, head, delta)
	local target = 1.0
	local alwaysShow = playerSettings[id] ~= nil and playerSettings[id].alwaysShow == true
	if not alwaysShow and hasRules(definition.visibility) then
		target = evaluateVisibility(id, definition, state, head)
	else
		state.visibilityDebug = nil
	end
	local current = state.visibility or target
	local fadeTime = definition.visibility ~= nil and definition.visibility.fadeTime or 0.25
	local step = fadeTime > 0.001 and delta / fadeTime or 1.0
	if current < target then current = math.min(target, current + step)
	elseif current > target then current = math.max(target, current - step) end
	local changed = state.visibility == nil or math.abs(current - state.visibility) > 0.001
	state.visibility = current
	if changed then applyTint(definition, state, false) end
	local hide = current <= 0.001
	if hide ~= (state.hiddenByRules == true) then
		state.hiddenByRules = hide
		setDisplayShown(state, not hide)
	end
end

-- whether any built element has a head based rule; cached in headNeeded (was a loop over all elements every frame),
-- refreshed by the 1 Hz validation and by every element change
local function needsHead()
	if headNeeded ~= nil then return headNeeded end
	headNeeded = false
	for id in pairs(runtime) do
		local v = elements[id] ~= nil and elements[id].visibility or nil
		if type(v) == "table" and (ruleOn(v.lookAt) or ruleOn(v.facing) or ruleOn(v.distance)) then headNeeded = true break end
	end
	return headNeeded
end

local function update(delta)
	if not isInitialized then return end
	delta = delta or 0.0

	validateTimer = validateTimer + delta
	if validateTimer >= VALIDATE_INTERVAL then
		validateTimer = 0.0
		validateElements()
	end

	local doTint = false
	tintTimer = tintTimer + delta
	if tintTimer >= TINT_INTERVAL then
		updateExposure(tintTimer)
		tintTimer = 0.0
		doTint = true
	end

	-- shared widgets: the game's own opacity / visibility changes reach the VR copy the same frame, and the screen copy
	-- stays invisible (checked every frame so a game fade-in never flashes on the flat screen)
	for _, source in pairs(sources) do
		if isCurrentWorld(source) then keepShared(source.share) end
	end
	for _, state in pairs(runtime) do
		if state.mode == M.Mode.DIRECT and state.share ~= nil and isCurrentWorld(state) then keepShared(state.share) end
	end
	updatePendingRefresh()

	local head = needsHead() and getHead() or nil

	for id, state in pairs(runtime) do
		local definition = elements[id]
		if not isCurrentWorld(state) then
			-- a load happened inside this engine tick and the level change has not been raised yet: forget, never touch
			destroyElement(id, false)
		elseif definition ~= nil and state.pending == true then
			-- A part without a size is a normal game state (Stalker 2 gives its AmmoPanel 0x0 while no weapon is
			-- drawn): wait for it, checking a few times a second. Giving up here used to hand the whole source widget
			-- back to the screen and take it again on every retry.
			local now = os.clock()
			if now >= (state.nextPendingCheck or 0) then
				state.nextPendingCheck = now + PENDING_CHECK_INTERVAL
				local done = completeRegion(id, definition, state)
				if done == nil then
					M.print("Element " .. id .. " could not be completed, will retry later", LogLevel.Warning)
					destroyElement(id, true)
					retryAfter[id] = now + RETRY_BACKOFF
				elseif done == false and not state.waitNoted and now - state.pendingSince > 10.0 then
					state.waitNoted = true
					M.print("Element " .. id .. " is waiting for its part to get a size on screen (the game is not showing it right now)")
				end
			end
		elseif definition ~= nil and state.component ~= nil then
			if state.mode ~= M.Mode.HIDE and isAlive(state.component) ~= nil then
				updateVisibility(id, definition, state, head, delta)
			end
			if state.mode == M.Mode.REGION and state.hiddenByRules ~= true then
				updateRegionCopy(id, definition, state)
			end
			if doTint and isAlive(state.component) ~= nil then
				applyTint(definition, state, false)
			end
		end
	end
end

--------------------------- Public API ---------------------------

function M.setParametersFileName(fileName)
	parametersFileName = fileName
end

function M.loadParameters(fileName)
	if fileName ~= nil then parametersFileName = fileName end
	M.print("Loading hud parameters " .. parametersFileName)
	paramManager = paramModule.new(parametersFileName, { elements = {}, order = {} }, true)
	paramManager:load()
	local saved = paramManager:get("elements") or {}
	local order = paramManager:get("order") or {}
	for _, id in ipairs(order) do
		if saved[id] ~= nil and elements[id] == nil then
			elements[id] = saved[id]
			table.insert(elementOrder, id)
		end
	end
	local savedStops = paramManager:get("exposureStops")
	if type(savedStops) == "number" then exposureStops = savedStops end
	local savedRate = paramManager:get("redrawRate")
	if type(savedRate) == "number" then redrawTime = savedRate > 0 and 1.0 / savedRate or 0.0 end
	local savedSource = paramManager:get("exposureSource")
	if savedSource == "postprocess" then
		M.setExposureSource(M.exposure.createPostProcessSource())
		exposureSourceName = "postprocess"
	end
end

-- Writes every element (in order), the exposure source choice and the global stops to data/<parameters>.json.
-- Nothing else saves on its own: the dev panel edits live and only this makes the edits permanent.
function M.saveParameters()
	if paramManager == nil then
		paramManager = paramModule.new(parametersFileName, { elements = {}, order = {} }, true)
	end
	local saved = {}
	for _, id in ipairs(elementOrder) do saved[id] = elements[id] end
	local order = {}
	for i, id in ipairs(elementOrder) do order[i] = id end
	paramManager:set("elements", saved, false)
	paramManager:set("order", order, false)
	paramManager:set("exposureSource", exposureSourceName, false)
	paramManager:set("exposureStops", exposureStops, false)
	paramManager:set("redrawRate", redrawTime > 0 and math.floor(1.0 / redrawTime + 0.5) or 0, false)
	paramManager:save()
	M.print("Saved " .. #order .. " HUD elements to " .. parametersFileName .. ".json")
end

-- Throws away unsaved changes: every element goes back to the flat HUD and the saved set is loaded and rebuilt.
function M.revertParameters()
	M.destroyAll(true)
	elements = {}
	elementOrder = {}
	retryAfter = {}
	M.setExposureSource(nil)
	exposureSourceName = "none"
	exposureStops = 0.0
	M.loadParameters()
end

-- "none" or "postprocess" (hud.exposure.createPostProcessSource); remembered by saveParameters
function M.setExposureSourceName(name)
	if name == "script" then return end -- only a script can set that one
	if name == "postprocess" then
		M.setExposureSource(M.exposure.createPostProcessSource())
		exposureSourceName = "postprocess"
	else
		M.setExposureSource(nil)
		exposureSourceName = "none"
	end
end

function M.getExposureSourceName()
	return exposureSourceName
end

function M.getExposureStops()
	return exposureStops
end

-- Player choices (player tab) on top of an element's definition: key "enabled" (false hides the element),
-- "sizeScale" (multiplies its size), "opacity" (multiplies its opacity), "alwaysShow" (true ignores the element's
-- visibility rules). Not saved here: the player tab saves them.
function M.setPlayerSetting(id, key, value)
	if playerSettings[id] == nil then playerSettings[id] = {} end
	playerSettings[id][key] = value
	local definition = elements[id]
	local state = runtime[id]
	if key == "enabled" then
		if value == false then
			destroyElement(id, true)
		elseif state == nil and isInitialized then
			buildElement(id)
		end
	elseif definition ~= nil and state ~= nil and state.component ~= nil and isAlive(state.component) ~= nil then
		if key == "sizeScale" then
			applyTransform(definition, state)
		elseif key == "opacity" then
			applyTint(definition, state, true)
		end
	end
end

-- Text search over every HUD widget that exists right now: the top level widgets on screen and the ones elements
-- have taken off it, walked through the trees of nested UserWidgets too. Matches widget names and class names,
-- ignoring case. Returns a list (drawn parts first) of { class, child, name, className, path, width, height,
-- drawn, hidden, faded, ambiguous } where class + child are exactly what a definition's widget field takes, and
-- the number of widgets searched and the number of matches (can exceed limit). ambiguous = an earlier widget in the same tree has the same name, so the path
-- finds that one instead. options: limit (results, default 200), walkLimit (widgets, default 40000).
local SEARCH_DEPTH_LIMIT = 40
function M.findParts(text, options)
	options = options or {}
	local results, visited = {}, 0
	local term = string.lower(text or "")
	if term == "" then return results, visited end
	local limit = options.limit or 200
	local walkLimit = options.walkLimit or 40000
	local matchCap = math.max(limit * 10, 2000) -- matches kept before sorting, so drawn parts are never cut off
	if slateLibrary == nil then
		slateLibrary = uevrUtils.find_default_instance("Class /Script/UMG.SlateBlueprintLibrary")
	end

	-- one root per class (definitions name classes, not instances)
	local roots, seenClasses = {}, {}
	local function addRoot(widget)
		widget = getLive(widget, "GetCachedGeometry")
		if widget == nil then return end
		local className = try("searchRootClass", function() return widget:get_class():get_full_name() end)
		if className == nil or seenClasses[className] then return end
		seenClasses[className] = true
		table.insert(roots, { widget = widget, class = className })
	end
	try("searchRoots", function()
		for _, widget in ipairs(getTopLevelWidgets(uevrUtils.get_class("Class /Script/UMG.UserWidget"))) do addRoot(widget) end
	end)
	for _, source in pairs(sources) do
		if isCurrentWorld(source) then addRoot(source.root) end
	end
	for _, state in pairs(runtime) do
		if state.mode == M.Mode.DIRECT and isCurrentWorld(state) then addRoot(state.widget) end
	end

	for _, root in ipairs(roots) do
		local nameCounts = {} -- per tree: a later widget with a name already seen cannot be found by its path
		local function record(widget, name, className, path, hidden)
			local entry = { class = root.class, child = path, name = name, className = className, path = path or "", hidden = hidden }
			entry.ambiguous = path ~= nil and nameCounts[path] ~= nil and nameCounts[path] > 1
			try("searchSize", function()
				local size = slateLibrary:GetLocalSize(widget:GetCachedGeometry())
				entry.width, entry.height = size.X, size.Y
			end)
			try("searchOpacity", function() entry.faded = widget:GetRenderOpacity() < 0.05 end)
			entry.drawn = not hidden and not entry.faded and (entry.width or 0) >= 1 and (entry.height or 0) >= 1
			table.insert(results, entry)
		end
		local function walk(widget, prefix, depth, hidden)
			if widget == nil or visited >= walkLimit or depth > SEARCH_DEPTH_LIMIT then return end
			visited = visited + 1
			local name = widget:get_fname():to_string()
			local className = widget:get_class():get_fname():to_string()
			local path = prefix == "" and name or (prefix .. "/" .. name)
			nameCounts[path] = (nameCounts[path] or 0) + 1
			local visibility = widget.GetVisibility ~= nil and widget:GetVisibility() or nil
			hidden = hidden or visibility == ESlateVisibility_Collapsed or visibility == ESlateVisibility_Hidden
			if #results < matchCap and (string.find(string.lower(name), term, 1, true) or string.find(string.lower(className), term, 1, true)) then
				record(widget, name, className, path, hidden)
			end
			local tree = widget.WidgetTree -- a nested UserWidget: its parts are one path step further in
			if tree ~= nil and tree.RootWidget ~= nil then
				walk(tree.RootWidget, path, depth + 1, hidden)
				return
			end
			if widget.GetChildrenCount ~= nil then -- content widgets are panels too: content = child 0, walked once
				for i = 0, widget:GetChildrenCount() - 1 do walk(widget:GetChildAt(i), prefix, depth + 1, hidden) end
			elseif widget.GetContent ~= nil then
				walk(widget:GetContent(), prefix, depth + 1, hidden)
			end
		end
		try("searchWalk", function()
			local widget = root.widget
			local className = widget:get_class():get_fname():to_string()
			visited = visited + 1
			if string.find(string.lower(className), term, 1, true) then record(widget, className, className, nil, false) end
			local tree = uevrUtils.getValid(widget.WidgetTree)
			if tree ~= nil then walk(tree.RootWidget, "", 1, false) end
		end)
	end

	table.sort(results, function(a, b)
		if a.drawn ~= b.drawn then return a.drawn end
		if a.class ~= b.class then return a.class < b.class end
		return a.path < b.path
	end)
	local total = #results
	for i = total, limit + 1, -1 do results[i] = nil end
	return results, visited, total
end

-- the widget a definition's widget field points at right now (whole widget or part), or nil; for the dev panel
function M.findWidgetPart(className, child)
	local root = findTopLevelWidget(className)
	if root == nil then
		for _, source in pairs(sources) do
			if isCurrentWorld(source) and getLive(source.root, "GetCachedGeometry") ~= nil and source.root:get_class():get_full_name() == className then root = source.root end
		end
	end
	if root == nil then
		for _, state in pairs(runtime) do
			if state.mode == M.Mode.DIRECT and isCurrentWorld(state) and getLive(state.widget, "GetCachedGeometry") ~= nil and state.widget:get_class():get_full_name() == className then root = state.widget end
		end
	end
	if root == nil then return nil end
	return findChildWidget(root, child)
end

-- Sorted bone and socket names of a definition's hand / pawn mesh / custom target, for the dev panel dropdown.
-- nil for controller and HMD targets (no sockets) or when the target does not exist right now.
function M.getTargetSocketNames(definition)
	if definition == nil then return nil end
	local kind = definition.target ~= nil and definition.target.type or M.Target.LEFT_CONTROLLER
	if controllerIDs[kind] ~= nil then return nil end
	local parent = resolveTarget(definition)
	if parent == nil then return nil end
	local names, seen = {}, {}
	local function add(name)
		if name == nil then return end
		local text = type(name) == "string" and name or (name.to_string ~= nil and name:to_string() or tostring(name))
		if text ~= "" and text ~= "None" and not seen[text] then
			seen[text] = true
			table.insert(names, text)
		end
	end
	try("getSocketNames", function()
		if parent.GetAllSocketNames ~= nil then
			for _, name in ipairs(parent:GetAllSocketNames() or {}) do add(name) end
		end
		if #names == 0 and parent.GetNumBones ~= nil then
			for i = 0, parent:GetNumBones() - 1 do add(parent:GetBoneName(i)) end
		end
	end)
	table.sort(names)
	return names
end

function M.getPlayerSetting(id, key)
	return playerSettings[id] ~= nil and playerSettings[id][key] or nil
end

-- Adds the player tab (on/off, size and opacity per element) to the UEVR overlay. Call after hud.init.
-- Player choices are saved in data/<saveFileName>.json (default "hud_player_config").
local playerConfigModule = nil
function M.showPlayerConfiguration(panelLabel, saveFileName)
	local ok, playerConfig = pcall(require, "libs/config/hud_config")
	if ok and type(playerConfig) == "table" then
		playerConfigModule = playerConfig
		try("playerPanel", playerConfig.show, M, panelLabel, saveFileName)
	else
		M.print("HUD player panel not loaded: " .. tostring(playerConfig), LogLevel.Warning)
	end
end

-- rebuilds the player tab's element list (the dev panel calls this after Save)
function M.refreshPlayerConfiguration()
	if playerConfigModule ~= nil then try("playerPanelRefresh", playerConfigModule.refresh) end
end

local function persistElement(id)
	if paramManager == nil then return end
	paramManager:set({ "elements", id }, elements[id], true)
	paramManager:set("order", elementOrder, true)
end

function M.addElement(definition, persist)
	if type(definition) ~= "table" then return nil end
	local id = definition.id or uevrUtils.guid()
	definition.id = id
	if definition.mode == nil then definition.mode = M.Mode.REGION end
	if elements[id] ~= nil then
		destroyElement(id, true, true)
	else
		table.insert(elementOrder, id)
	end
	elements[id] = definition
	retryAfter[id] = nil
	headNeeded = nil
	if persist == true then persistElement(id) end
	if isInitialized then buildElement(id) end
	return id
end

function M.removeElement(id, persist)
	destroyElement(id, true)
	elements[id] = nil
	headNeeded = nil
	for i = #elementOrder, 1, -1 do
		if elementOrder[i] == id then table.remove(elementOrder, i) end
	end
	if persist == true and paramManager ~= nil then
		paramManager:set({ "elements", id }, nil, true)
		paramManager:set("order", elementOrder, true)
	end
end

function M.getElement(id)
	return elements[id]
end

function M.getElementIDs()
	local result = {}
	for _, id in ipairs(elementOrder) do table.insert(result, id) end
	return result
end

function M.getComponent(id)
	local state = runtime[id]
	return state ~= nil and isAlive(state.component) or nil
end

-- a snapshot of an element's live state for tools and debugging, nil when the element is not built
function M.getElementInfo(id)
	local state = runtime[id]
	if state == nil then return nil end
	local info = { mode = state.mode, pending = state.pending == true, drawWidth = state.drawWidth, drawHeight = state.drawHeight }
	if state.mode == M.Mode.DIRECT then info.warning = layoutWarnings[id] end
	info.visibility = state.visibility
	info.visibilityDebug = state.visibilityDebug -- { target, lookAt, facing, distance, state, callback } of the last frame
	if state.rect ~= nil then info.rect = { state.rect[1], state.rect[2], state.rect[3], state.rect[4] } end
	if state.source ~= nil then info.sourceWidth, info.sourceHeight = state.source.width, state.source.height end
	info.hasComponent = isAlive(state.component) ~= nil
	info.hasRenderTarget = isAlive(state.renderTarget) ~= nil
	info.canvasCopy = canvasCopyAvailable
	-- the game's own state of the widget, for panels that come out empty (collapsed or faded out by the game)
	local widget = getLive(state.widget, "GetVisibility")
	if widget ~= nil then
		try("elementInfoWidget", function()
			info.widgetVisibility = widget:GetVisibility()
			if widget.GetRenderOpacity ~= nil then info.widgetRenderOpacity = widget:GetRenderOpacity() end
			if widget.IsVisible ~= nil then info.widgetIsVisible = widget:IsVisible() end
			local desired = widget.GetDesiredSize ~= nil and widget:GetDesiredSize() or nil
			if desired ~= nil then info.widgetDesiredSize = { desired.X, desired.Y } end
		end)
	end
	return info
end

function M.setElementEnabled(id, value, persist)
	local definition = elements[id]
	if definition == nil then return end
	definition.enabled = value
	if persist == true then persistElement(id) end
	if value == false then
		destroyElement(id, true)
	elseif runtime[id] == nil and isInitialized then
		buildElement(id)
	end
end

-- path is a key or a list of keys, e.g. {"transform", "position"}. Transform and appearance changes are
-- applied to the live component, anything else rebuilds the element.
function M.setElementValue(id, path, value, persist)
	local definition = elements[id]
	if definition == nil then return end
	if type(path) ~= "table" then path = { path } end
	local field = definition
	for i = 1, #path - 1 do
		if type(field[path[i]]) ~= "table" then field[path[i]] = {} end
		field = field[path[i]]
	end
	field[path[#path]] = value
	headNeeded = nil
	if persist == true then persistElement(id) end

	if path[1] == "visibility" or path[1] == "label" or path[1] == "regionRest" then return end -- read every frame / display only: no rebuild

	local state = runtime[id]
	if state == nil or state.component == nil or isAlive(state.component) == nil then return end
	if path[1] == "transform" then
		applyTransform(definition, state)
	elseif path[1] == "appearance" then
		applyAppearance(definition, state)
	else
		destroyElement(id, true, true) -- keep the source: the rebuild uses it again at once
		retryAfter[id] = nil
		buildElement(id)
	end
end

function M.setEnabled(value)
	isEnabled = value
	if not value then
		M.restoreAll()
	end
end

function M.isEnabled()
	return isEnabled
end

-- VR redraws per second of the game widgets the elements show (0 = every frame, the default). Each redraw draws the
-- whole widget again (a screen-sized render target for a Region source), so a lower rate saves GPU time; 30 - 45 is
-- usually plenty for a HUD. Saved by saveParameters.
function M.setRedrawRate(perSecond)
	perSecond = tonumber(perSecond) or 0
	redrawTime = perSecond > 0 and 1.0 / perSecond or 0.0
	for _, source in pairs(sources) do
		if isCurrentWorld(source) then applyRedrawTime(source.component) end
	end
	for _, state in pairs(runtime) do
		if state.mode == M.Mode.DIRECT and isCurrentWorld(state) then applyRedrawTime(state.component) end
	end
end

function M.getRedrawRate()
	return redrawTime > 0 and math.floor(1.0 / redrawTime + 0.5) or 0
end

-- { averageMs = the lib's Lua time per frame (averaged over a couple of seconds), copiesPerFrame = Region copies }
function M.getStats()
	return { averageMs = stats.averageMs, copiesPerFrame = stats.copiesPerFrame }
end

-- restore == false drops the components without touching the game's widgets. Only for widgets known to be
-- dead: a live widget that is dropped this way ends up on neither the screen nor a panel.
function M.destroyAll(restore)
	for id, _ in pairs(runtime) do
		destroyElement(id, restore)
	end
	for _, source in pairs(sources) do
		releaseSource(source, restore)
	end
	runtime = {}
	sources = {}
end

function M.restoreAll()
	M.destroyAll(true)
end

function M.setExposureSource(func)
	exposureSource = func
	-- a source set from a script is not something the dev panel can save or recreate
	exposureSourceName = func == nil and "none" or "script"
	if func == nil then exposureEV = nil end
end

function M.setExposureStops(stops)
	exposureStops = stops or 0.0
end

function M.getExposureEV()
	return exposureEV
end

-- func(id, definition) returns a visibility factor 0..1 (or nil to have no say) for game specific rules,
-- e.g. only while aiming; combined with the element's own rules (the lowest factor wins)
function M.registerVisibilityCallback(func)
	table.insert(visibilityCallbacks, func)
end

function M.registerTargetCallback(func)
	targetCallback = func
end

function M.registerRegionCallback(func)
	regionCallback = func
end

function M.registerPostAttachCallback(func)
	if type(func) == "function" then table.insert(postAttachCallbacks, func) end
end

--------------------------- Exposure helpers ---------------------------

-- scene EV100 minus everything the game adds on top. curve is the game's AutoExposureBiasCurve (a
-- CurveFloat object) or nil.
function M.exposure.effectiveEV100(ev100, bias, curve)
	local curveValue = 0.0
	if uevrUtils.getValid(curve) ~= nil then
		curveValue = try("exposureCurve", function() return curve:GetFloatValue(ev100) end) or 0.0
	end
	return ev100 - (bias or 0.0) - curveValue
end

-- average scene luminance in cd/m2 to effective EV100. In Stalker 2 this predicted the measured exposure
-- to within about half a stop outdoors and at night.
function M.exposure.fromLuminance(luminance, bias, curve)
	if luminance == nil or luminance <= 0 then return nil end
	local ev100 = math.log(luminance) / math.log(2) + 3.0 -- EV100 = log2(L * 100 / 12.5)
	return M.exposure.effectiveEV100(ev100, bias, curve)
end

-- Class lookup for the exposure helpers, remembered per level INCLUDING misses: a class that is not loaded costs a
-- full object table scan (~400 ms in Stalker 2) on every find_uobject, so a missing one is only looked up again
-- after the next level change (2026-10-15: a fire barrel class missing indoors hitched the game every refresh).
local exposureClassCache, exposureClassWorld = {}, nil
function M.exposure.getClass(path)
	local world = currentWorld()
	if world ~= exposureClassWorld then
		exposureClassCache, exposureClassWorld = {}, world
	end
	local cached = exposureClassCache[path]
	if cached == nil then
		cached = uevrUtils.get_class(path, true) or false
		exposureClassCache[path] = cached
	end
	return cached or nil
end

-- Inside-volume test for games that mark interiors with box volumes (Stalker 2: BP_PPVIndoor_C actors with a
-- BoxComponent "Box" and a PostProcessComponent blending over BlendRadius). Returns tester(x, y, z) -> 0..1:
-- 1 inside any box, fading to 0 over the blend margin outside it. Boxes are static, so their transforms are read
-- once and cached; the list is refreshed every options.refresh seconds and on a world change, and objects from
-- an old world are dropped, never touched.
--   options = { actorClass = "BlueprintGeneratedClass /Game/...", boxProperty = "Box",
--               postProcessProperty = "PostProcess" (optional, gives the blend radius), blend = 100, refresh = 5 }
function M.exposure.createVolumeTester(options)
	options = options or {}
	local boxes, world, nextRefresh = {}, nil, 0
	local refresh = options.refresh or 5.0

	local function quatRotateInverse(q, x, y, z)
		-- v' = conj(q) * v * q, for a unit quaternion
		local qx, qy, qz, qw = -q.X, -q.Y, -q.Z, q.W
		local tx = 2 * (qy * z - qz * y)
		local ty = 2 * (qz * x - qx * z)
		local tz = 2 * (qx * y - qy * x)
		return x + qw * tx + (qy * tz - qz * ty), y + qw * ty + (qz * tx - qx * tz), z + qw * tz + (qx * ty - qy * tx)
	end

	local function rebuild()
		boxes = {}
		world = currentWorld()
		local class = M.exposure.getClass(options.actorClass)
		if class == nil or world == nil then return end
		-- the engine's own actor list: UEVR's object listing misses objects it has not adopted (Stalker 2)
		local actors = try("volumeActors", function()
			local found = {}
			Statics:GetAllActorsOfClass(world, class, found)
			return found
		end) or {}
		for _, actor in ipairs(actors) do
			try("volumeBox", function()
				local box = actor[options.boxProperty or "Box"]
				if uevrUtils.getValid(box) == nil then return end
				local t = box:K2_GetComponentToWorld()
				local extent = box.BoxExtent
				local blend = options.blend or 100.0
				local post = options.postProcessProperty ~= nil and actor[options.postProcessProperty] or nil
				if post ~= nil and post.BlendRadius ~= nil then blend = post.BlendRadius end
				local ex, ey, ez = extent.X * t.Scale3D.X, extent.Y * t.Scale3D.Y, extent.Z * t.Scale3D.Z
				table.insert(boxes, {
					cx = t.Translation.X, cy = t.Translation.Y, cz = t.Translation.Z,
					q = { X = t.Rotation.X, Y = t.Rotation.Y, Z = t.Rotation.Z, W = t.Rotation.W },
					ex = math.abs(ex), ey = math.abs(ey), ez = math.abs(ez), blend = blend,
					reach = math.sqrt(ex * ex + ey * ey + ez * ez) + blend,
				})
			end)
		end
	end

	return function(x, y, z)
		local now = os.clock()
		if now >= nextRefresh or currentWorld() ~= world then
			nextRefresh = now + refresh
			rebuild()
		end
		local best = 0.0
		for _, b in ipairs(boxes) do
			local dx, dy, dz = x - b.cx, y - b.cy, z - b.cz
			if dx * dx + dy * dy + dz * dz <= b.reach * b.reach then
				local lx, ly, lz = quatRotateInverse(b.q, dx, dy, dz)
				-- distance outside the box (0 when inside)
				local ox = math.max(math.abs(lx) - b.ex, 0)
				local oy = math.max(math.abs(ly) - b.ey, 0)
				local oz = math.max(math.abs(lz) - b.ez, 0)
				local outside = math.sqrt(ox * ox + oy * oy + oz * oz)
				local weight = outside <= 0 and 1.0 or (b.blend > 0 and math.max(0.0, 1.0 - outside / b.blend) or 0.0)
				if weight > best then best = weight end
				if best >= 1.0 then break end
			end
		end
		return best, #boxes
	end
end

-- Open-sky test: line traces from a point over the upper hemisphere (straight up, and rings of six at 60 and 30
-- degrees). Returns tester(x, y, z) -> blocked fraction 0..1 (1 = everything above is covered, e.g. a closed room;
-- measured 2026-10-13 in Stalker 2: 0 open sky in a closed room), plus the open fraction of the low (30 degree) ring
-- as a second value: daylight coming in through windows and doors. Results are reused for options.interval seconds.
--   options = { length = 3000, interval = 0.5, channel = 0 (Visibility), ignorePawn = true }
function M.exposure.createSkyTester(options)
	options = options or {}
	local directions = { { 0, 0, 1 } }
	for _, elevation in ipairs({ 60, 30 }) do
		local e = math.rad(elevation)
		for i = 0, 5 do
			local a = math.rad(i * 60 + (elevation == 30 and 30 or 0))
			table.insert(directions, { math.cos(e) * math.cos(a), math.cos(e) * math.sin(a), math.sin(e) })
		end
	end
	local hitResult = nil
	local last, lastLowOpen, lastTime = 0.0, 1.0, nil
	return function(x, y, z)
		local now = os.clock()
		if lastTime ~= nil and now - lastTime < (options.interval or 0.5) then return last, lastLowOpen end
		lastTime = now
		local result = try("skyTest", function()
			if kismet_system_library == nil then return nil end
			if hitResult == nil then hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult") end
			local world = uevrUtils.get_world()
			if world == nil then return nil end
			local ignore = {}
			local localPawn = options.ignorePawn ~= false and uevr.api:get_local_pawn(0) or nil
			if localPawn ~= nil then ignore = { localPawn } end
			local length = options.length or 3000
			local blocked, lowOpen = 0, 0
			for index, d in ipairs(directions) do
				local from = uevrUtils.vector(x, y, z)
				local to = uevrUtils.vector(x + d[1] * length, y + d[2] * length, z + d[3] * length)
				if kismet_system_library:LineTraceSingle(world, from, to, options.channel or 0, false, ignore, 0, hitResult, true, zero_color, zero_color, 0.0) then
					blocked = blocked + 1
				elseif index > 7 then -- directions 8..13 are the 30 degree ring
					lowOpen = lowOpen + 1
				end
			end
			return { blocked / #directions, lowOpen / 6 }
		end)
		if result ~= nil then last, lastLowOpen = result[1], result[2] end
		return last, lastLowOpen
	end
end

-- Local light probe: approximate illuminance (lux) at a point from nearby light actors that have a clear line of
-- sight to it - lamps, fires and similar. Bounce light and emissive surfaces are not counted. Light actors within
-- options.range are collected every options.refresh seconds (engine actor list, works where UEVR's object listing is
-- blind), the nearest options.maxLights are traced every options.interval seconds.
--   options = { range = 3000, refresh = 3, interval = 0.5, maxLights = 12, channel = 0,
--               sources = { { class = "Class /Script/Engine.Light", components = { "LightComponent" } }, ... } }
-- Many games build lamps as Blueprint actors with named light components (Stalker 2: BP_Light_Base_C "MainLight"),
-- so sources lists actor classes and the light component properties to read on them.
-- Returns probe(x, y, z) -> lux, lights seen (in range, on), lights with line of sight.
function M.exposure.createLightProbe(options)
	options = options or {}
	local range = options.range or 3000
	local sources = options.sources or { { class = "Class /Script/Engine.Light", components = { "LightComponent" } } }
	local lights, nextRefresh, world = {}, 0, nil
	local lastLux, lastSeen, lastVisible, lastTime = 0.0, 0, 0, nil
	local hitResult = nil

	-- candela of a local light (UE light units: 0 unitless, 1 candelas, 2 lumens, 3 EV)
	local function candela(component)
		local intensity = component.Intensity or 0
		local units = component.IntensityUnits
		if units == 1 then return intensity end
		if units == 2 then return intensity / (4 * math.pi) end
		if units == 3 then return 2 ^ intensity end
		return intensity / 625.0 -- unitless: 625 unitless = 1 candela for inverse squared falloff
	end

	local function rebuild(x, y, z)
		lights = {}
		world = currentWorld()
		if world == nil then return end
		for _, source in ipairs(sources) do
			local class = M.exposure.getClass(source.class)
			if class ~= nil then
				local actors = {}
				try("lightActors", function() Statics:GetAllActorsOfClass(world, class, actors) end)
				for _, actor in ipairs(actors) do
					for _, property in ipairs(source.components or { "LightComponent" }) do
						try("lightActor", function()
							local component = actor[property]
							if uevrUtils.getValid(component) == nil or component.Intensity == nil then return end
							local p = component:K2_GetComponentLocation()
							local dx, dy, dz = p.X - x, p.Y - y, p.Z - z
							if dx * dx + dy * dy + dz * dz <= range * range then
								table.insert(lights, { component = component, actor = actor, x = p.X, y = p.Y, z = p.Z })
							end
						end)
					end
				end
			end
		end
	end

	return function(x, y, z)
		local now = os.clock()
		if now >= nextRefresh or currentWorld() ~= world then
			nextRefresh = now + (options.refresh or 3.0)
			rebuild(x, y, z)
		end
		if lastTime ~= nil and now - lastTime < (options.interval or 0.5) then return lastLux, lastSeen, lastVisible end
		lastTime = now
		local result = try("lightProbe", function()
			if hitResult == nil then hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult") end
			local candidates = {}
			for _, light in ipairs(lights) do
				local dx, dy, dz = light.x - x, light.y - y, light.z - z
				local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
				local component = light.component
				if uevrUtils.getValid(component) ~= nil and component:IsVisible() and (component.Intensity or 0) > 0 then
					local radius = component.AttenuationRadius
					if radius == nil or distance <= radius then
						table.insert(candidates, { light = light, distance = distance })
					end
				end
			end
			table.sort(candidates, function(a, b) return a.distance < b.distance end)
			local localPawn = uevr.api:get_local_pawn(0)
			local lux, visible = 0.0, 0
			for i = 1, math.min(#candidates, options.maxLights or 12) do
				local c = candidates[i]
				local light = c.light
				local ignore = { light.actor }
				if localPawn ~= nil then table.insert(ignore, localPawn) end
				local blocked = kismet_system_library:LineTraceSingle(uevrUtils.get_world(), uevrUtils.vector(light.x, light.y, light.z),
					uevrUtils.vector(x, y, z), options.channel or 0, false, ignore, 0, hitResult, true, zero_color, zero_color, 0.0)
				if not blocked then
					visible = visible + 1
					local meters = math.max(c.distance / 100.0, 0.5)
					lux = lux + candela(light.component) / (meters * meters)
				end
			end
			return { lux, #candidates, visible }
		end)
		if result ~= nil then lastLux, lastSeen, lastVisible = result[1], result[2], result[3] end
		return lastLux, lastSeen, lastVisible
	end
end

local function readPinnedExposure(settings)
	if settings == nil then return nil end
	if settings.bOverride_AutoExposureMinBrightness ~= true or settings.bOverride_AutoExposureMaxBrightness ~= true then return nil end
	local minimum, maximum = settings.AutoExposureMinBrightness, settings.AutoExposureMaxBrightness
	if minimum == nil or maximum == nil then return nil end
	local bias = settings.bOverride_AutoExposureBias == true and settings.AutoExposureBias or 0.0
	return minimum, maximum, bias
end

-- A source for games whose post process
-- volumes set the same minimum and maximum exposure, which makes exposure a constant that can simply be
-- read. Uses the enabled volume or component with the highest priority; it does not test whether the
-- camera is inside a bounded volume. Returns nil (no compensation) when the range is wider than
-- options.maxRange stops (default 1).
function M.exposure.createPostProcessSource(options)
	options = options or {}
	local maxRange = options.maxRange or 1.0
	local refreshInterval = options.refreshInterval or 5.0
	local lastRefresh = -1000.0
	local cached = nil
	return function()
		local now = os.clock()
		if now - lastRefresh < refreshInterval then return cached end
		lastRefresh = now
		cached = nil
		local best = -1e30
		for _, className in ipairs({ "Class /Script/Engine.PostProcessVolume", "Class /Script/Engine.PostProcessComponent" }) do
			for _, object in ipairs(uevrUtils.find_all_instances(className, false) or {}) do
				try("readPostProcess", function()
					if object.bEnabled ~= false then
						local priority = object.Priority or 0.0
						local minimum, maximum, bias = readPinnedExposure(object.Settings)
						if minimum ~= nil and priority > best and (maximum - minimum) <= maxRange then
							best = priority
							cached = (minimum + maximum) * 0.5 - bias
						end
					end
				end)
			end
		end
		return cached
	end
end

--------------------------- Init ---------------------------

function M.init(isDeveloperMode, logLevel)
	if logLevel ~= nil then
		M.setLogLevel(logLevel)
	end
	if isDeveloperMode == nil and uevrUtils.getDeveloperMode() ~= nil then
		isDeveloperMode = uevrUtils.getDeveloperMode()
	end
	if isInitialized then return end

	M.loadParameters()
	isInitialized = true

	if isDeveloperMode then
		local ok, devConfig = pcall(require, "libs/config/hud_config_dev")
		if ok and type(devConfig) == "table" then
			try("devPanel", devConfig.init, M)
		else
			M.print("HUD dev panel not loaded: " .. tostring(devConfig), LogLevel.Warning)
		end
	end

	-- the source widget draws during the engine tick, so copying after it gives a same frame result
	uevrUtils.registerPostEngineTickCallback(function(engine, delta)
		local started = os.clock()
		frameId = frameId + 1
		inUpdate = true
		local ok, err = pcall(update, delta)
		inUpdate = false
		if not ok and loggedFailures.update == nil then
			loggedFailures.update = true
			M.print("update failed: " .. tostring(err), LogLevel.Warning)
		end
		-- cost readout
		stats.seconds = stats.seconds + (os.clock() - started)
		stats.frames = stats.frames + 1
		stats.window = stats.window + (delta or 0.0)
		if stats.window >= STATS_WINDOW and stats.frames > 0 then
			stats.averageMs = stats.seconds / stats.frames * 1000.0
			stats.copiesPerFrame = stats.copies / stats.frames
			stats.frames, stats.seconds, stats.window, stats.copies = 0, 0.0, 0.0, 0
		end
	end)

	-- The libs raise this once at script start and, on a real change, after the new level is already current.
	-- destroyAll(true) restores only what belongs to the current world (the start-up call); everything from the
	-- previous level is forgotten without being touched (see isCurrentWorld). Elements rebuild on the next validate.
	-- game states for the visibility rules (uevrlib only polls these while something listens)
	uevrUtils.registerGamePausedCallback(function(value) gameState.paused = value == true end)
	uevrUtils.registerCutsceneChangeCallback(function(value) gameState.cutscene = value == true end)
	uevrUtils.registerUEVRUIChangeCallback(function(value) gameState.uevrMenu = value == true end)
	uevrUtils.registerCharacterHiddenCallback(function(value) gameState.characterHidden = value == true end)

	-- uevrlib raises this once at script start for the level that is already current: nothing changed then, so the
	-- elements built for it stay (restoring them would hand every source widget back to the screen and take it
	-- again a moment later). On a real change everything from the previous level is only forgotten, never touched
	-- (see isCurrentWorld), and the elements rebuild on the next validate.
	local knownLevel = try("readLevel", function() local world = uevrUtils.get_world() return world ~= nil and world.PersistentLevel or nil end)
	uevrUtils.registerPreLevelChangeCallback(function(level)
		if level ~= nil and level == knownLevel then return end
		knownLevel = level
		M.print("Level change, rebuilding on the new level")
		hmdCreateTried = false
		for id, state in pairs(runtime) do
			if not isCurrentWorld(state) then destroyElement(id, false) end
		end
		for key, source in pairs(sources) do
			if not isCurrentWorld(source) then
				sources[key] = nil
				restoreShared(source.share) -- only touches a game widget that outlives levels
			end
		end
		local world = currentWorld()
		for address, record in pairs(ownObjects) do
			if record.world ~= world then ownObjects[address] = nil end
		end
		knownWidgets = {}
		retryAfter = {}
		classCache = {}
		classCheckedAt = {}
		drawContext = nil
	end)

	if hands ~= nil and hands.registerOnDestroyCallback ~= nil then
		hands.registerOnDestroyCallback(function()
			for id, state in pairs(runtime) do
				local kind = elements[id] ~= nil and elements[id].target ~= nil and elements[id].target.type or nil
				if kind == M.Target.LEFT_HAND or kind == M.Target.RIGHT_HAND then
					state.parent = nil
					destroyElement(id, true)
				end
			end
		end)
	end
end

-- One call start-up for a mod (see Usage). Every option is optional.
function M.setup(options)
	options = options or {}
	if options.logFile ~= nil then M.setLogFile(options.logFile) end
	if options.parametersFile ~= nil then M.setParametersFileName(options.parametersFile) end
	M.init(options.developerMode, options.logLevel)
	-- after init: init loads the saved choices, these override them
	if options.redrawRate ~= nil then M.setRedrawRate(options.redrawRate) end
	if type(options.exposure) == "function" then
		M.setExposureSource(options.exposure)
	elseif type(options.exposure) == "string" then
		M.setExposureSourceName(options.exposure)
	end
	if options.playerTab ~= false then
		M.showPlayerConfiguration(type(options.playerTab) == "string" and options.playerTab or "HUD", options.playerConfigFile)
	end
	return M
end

uevr.params.sdk.callbacks.on_script_reset(function()
	isScriptResetting = true -- no delayed work: this Lua state is about to end
	M.restoreAll()
end)

--[[
Notes for a Stalker 2 exposure source (not implemented, measured 2026-10-13)

	Exposure there is fully automatic: the weather actor's unbound PostProcessComponent sets histogram auto
	exposure from -10 to +25 EV, bias +1, with an AutoExposureBiasCurve (C_ExponentialCurve_ue5_down outdoors,
	C_ExponentialCurveInterior inside BP_PPVIndoor volumes). No live exposure value is readable.

	hud.exposure.fromLuminance(L, 1, curve) reproduces the game's exposure from the average luminance of
	the view. What is missing is a reliable L:
		- An 8x8 SCS_SceneColorHDR scene capture at the camera gives L within 0.2 stops outdoors and at
		  night, costs about 6 to 8 ms per captured frame at any size, and can be pulsed (the render target
		  keeps its last image while bCaptureEveryFrame is off).
		- In a daytime interior the capture reads about outdoor brightness whatever its size or settings,
		  so it must not be used there.
		- 29 visibility line traces from the camera over the upper hemisphere reported 0 open sky in a
		  closed room, which makes a cheap "enclosed" test.
	Measured interiors needed 2^-2.4, 2^-4.3 and 2^-6.1, so a single interior level is good to about two
	stops. Locking exposure (r.EyeAdaptation.MethodOverride 0) is the exact alternative.
]]--

return M
