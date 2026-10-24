-- Inspected items in VR (2026-10-09).
--
-- Picking up an inspectable item (BP_ZoomObject_C children, e.g. BP_ZO_StrangeSkull_C) sets Pawn.InspectingObject. The
-- game puts the item's (unattached) root at Pawn.ZOInspectionPoint - a point only 10 cm in front of the pawn's
-- CineCamera - and shrinks it to 0.3x (MCP). Flat that reads as a normal-sized object close up; in VR the stereo depth
-- shows a doll-sized item 10 cm from the eyes (hard to focus, "FOV / depth looks wrong").
--
-- Fix: push the item out along the camera ray by a factor k and scale it up by the same k. Seen from the game camera it
-- covers exactly the same angles (so the game's interact aiming at the item's parts still lines up), but it sits at a
-- comfortable distance at roughly real size. The game's own pose is kept in camera space and re-detected whenever the
-- game moves or rescales the item itself (zoom-in / zoom-out animation), so the push never compounds. Rotation is not
-- touched (the game turns the item's pivot children). uevrmenus.lua turns input.lua off while inspecting (right stick ->
-- the item).

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 6.7, label = "Inspected Items", layout = {
    { widgetType = "checkbox", id = "insp_enabled", label = "Show inspected items at a comfortable VR distance", initialValue = true },
    { widgetType = "slider_float", id = "insp_distance", label = "Distance (cm)", initialValue = 35.0, range = {15.0, 80.0} },
    { widgetType = "checkbox", id = "insp_keep_size", label = "Keep the on-screen size (scale up with distance)", initialValue = true },
    { widgetType = "checkbox", id = "insp_ui_match", label = "Put the UI (prompts) at the item's distance, fixed to the game camera", initialValue = true },
    { widgetType = "slider_float", id = "insp_ui_size_factor", label = "UI size per metre of distance", initialValue = 1.83, range = {0.5, 4.0}, speed = 0.01 },
    { widgetType = "checkbox", id = "insp_hide_vignette", label = "Hide the dark inspection vignette (box around the item)", initialValue = true },
    { widgetType = "text", id = "insp_status", label = "Inspecting: none" },
}})

local ui = require('libs/ui')

-- The prompts on the item's parts are 2D UI projected from the game camera (CineCamera, horizontal FOV 85, 16:9 - MCP)
-- and shown on UEVR's UI plane (head-locked at ~2.8 m in gameplay), so in stereo they floated far behind the item, at a
-- different spot in each eye. While inspecting, the UI is fixed to the game camera (libs/ui.lua viewLocked = true ->
-- UI_FollowView off + recenter, the same path menus.lua uses) and UEVR's UI plane is put at the item's distance with
-- a width of 2 * d * tan(FOV / 2) (= 1.83 * d for 85 deg), so each prompt sits on its part at the same depth.
-- Leaving clears the state and ui.lua restores the gameplay UI settings.
local UI_PRIORITY = 95 -- below menus.lua (100), above the seated "UI follows view" (50)
local uiOwned = false
local function applyUI(active, distanceCm)
    local inMenu = _G.hrIsInMenu ~= nil and _G.hrIsInMenu()
    if active and not inMenu and configui.getValue("insp_ui_match") ~= false then
        ui.setCustomState("viewLocked", true, UI_PRIORITY)
        uiOwned = true
        local d = distanceCm / 100.0
        uevrUtils.setUIFollowsViewOffset({ X = 0, Y = 0, Z = d })
        uevrUtils.setUIFollowsViewSize(d * (configui.getValue("insp_ui_size_factor") or 1.83))
    elseif uiOwned and not inMenu then
        ui.setCustomState("viewLocked", nil)
        uiOwned = false
    elseif inMenu then
        uiOwned = false -- menus.lua owns the slot now (and clears it when the menu closes)
    end
end

local hitResult = nil
local function getHitResult()
    if hitResult == nil then hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult") end
    return hitResult
end

local function vec(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function len(v) return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
local function near(a, b, tol)
    return a ~= nil and b ~= nil and math.abs(a.X - b.X) < tol and math.abs(a.Y - b.Y) < tol and math.abs(a.Z - b.Z) < tol
end

-- state for the item currently inspected
local st = nil -- { obj, root, gameLocal, gameScale, writtenLoc, writtenScale, camT, ranges }

-- The item's interact points (COMP_Interact, e.g. the skull's nails) have InteractRange = 10 cm - the game's inspection
-- distance (MCP). Pushed out by k they were out of range: no prompts, no A. So their range is scaled by the same k while
-- the item is pushed (originals kept per component, restored when the inspection ends).
local interactClass = nil
local function interactComponents(obj)
    if interactClass == nil then interactClass = uevrUtils.get_class("Class /Script/Project.COMP_Interact") end
    if interactClass == nil then return {} end
    local list = {}
    pcall(function()
        local comps = obj:K2_GetComponentsByClass(interactClass)
        for _, c in ipairs(comps or {}) do list[#list + 1] = c end
    end)
    return list
end

-- Distances on a COMP_Interact (MCP 2026-10-09): InteractRange (10) + VisibilityRange (12) on the component, and the
-- CustomInteractMathData struct's InteractRange (10) + IndicatorRange (20). Scaling only the top-level InteractRange
-- brought the prompt markers back but not the A focus prompt - the struct copy is what the focus check uses.
local TOP_RANGES = { "InteractRange", "VisibilityRange" }
local STRUCT_RANGES = { "InteractRange", "IndicatorRange" }
local function applyRanges(k)
    if st == nil then return end
    if st.ranges == nil then
        st.ranges = {}
        for _, c in ipairs(interactComponents(st.obj)) do
            local e = { comp = c, top = {}, math = {} }
            for _, f in ipairs(TOP_RANGES) do
                local ok, r = pcall(function() return c[f] end)
                if ok and type(r) == "number" then e.top[f] = r end
            end
            for _, f in ipairs(STRUCT_RANGES) do
                local ok, r = pcall(function() return c.CustomInteractMathData[f] end)
                if ok and type(r) == "number" then e.math[f] = r end
            end
            st.ranges[#st.ranges + 1] = e
        end
    end
    if st.rangeK == k then return end
    st.rangeK = k
    for _, e in ipairs(st.ranges) do
        for f, orig in pairs(e.top) do pcall(function() e.comp[f] = orig * k end) end
        for f, orig in pairs(e.math) do pcall(function() e.comp.CustomInteractMathData[f] = orig * k end) end
    end
end

local function cameraTransform(cam)
    return kismet_math_library:MakeTransform(cam:K2_GetComponentLocation(), cam:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1))
end

-- put the item back where the game had it (camera space -> world with the current camera)
local function restore()
    if st == nil then return end
    applyRanges(1.0) -- interact ranges back to the game's values
    local s = st
    st = nil
    configui.setLabel("insp_status", "Inspecting: none")
    if s.gameLocal == nil or s.camT == nil then return end
    pcall(function()
        local cur = s.root:K2_GetComponentLocation()
        if not near(cur, s.writtenLoc, 0.05) then return end -- the game has already moved it (zoom-out): leave it
        local w = kismet_math_library:TransformLocation(s.camT, uevrUtils.vector(s.gameLocal.X, s.gameLocal.Y, s.gameLocal.Z))
        s.root:K2_SetWorldLocation(w, false, getHitResult(), false)
        s.root:SetWorldScale3D(uevrUtils.vector(s.gameScale.X, s.gameScale.Y, s.gameScale.Z))
    end)
end

local function tick()
    local pawn = uevr.api:get_local_pawn(0)
    local obj = nil
    pcall(function() obj = pawn ~= nil and pawn.InspectingObject or nil end)
    if obj == nil or configui.getValue("insp_enabled") == false then restore() applyUI(false) return end

    local root = obj.RootComponent
    local point = pawn.ZOInspectionPoint
    local cam = point ~= nil and point.AttachParent or nil
    if root == nil or cam == nil then return end

    if st == nil or st.obj ~= obj then
        restore()
        st = { obj = obj, root = root }
        configui.setLabel("insp_status", "Inspecting: " .. obj:get_fname():to_string())
    end

    local camT = cameraTransform(cam)
    local curLoc = vec(root:K2_GetComponentLocation())
    local curScale = vec(root:K2_GetComponentScale())
    -- unchanged since our last write -> keep the recorded game pose; otherwise the game moved / rescaled it itself
    if not (near(curLoc, st.writtenLoc, 0.05) and near(curScale, st.writtenScale, 0.0005)) then
        st.gameLocal = vec(kismet_math_library:InverseTransformLocation(camT, uevrUtils.vector(curLoc.X, curLoc.Y, curLoc.Z)))
        st.gameScale = curScale
    end
    st.camT = camT

    -- the game's inspection distance (ZOInspectionPoint in front of its camera, 10 cm here)
    local pointDist = math.max(len(vec(point.RelativeLocation)), 1.0)
    local gameDist = len(st.gameLocal)
    local wanted = configui.getValue("insp_distance") or 35.0
    local k = wanted / pointDist
    -- only while the item is (near) at the inspection point; during the fly-in / fly-out the game's path is kept
    if gameDist > pointDist * 2.0 then k = 1.0 end
    local keepSize = configui.getValue("insp_keep_size") ~= false
    applyRanges(k)
    applyUI(true, gameDist * k)

    local l = st.gameLocal
    local w = kismet_math_library:TransformLocation(camT, uevrUtils.vector(l.X * k, l.Y * k, l.Z * k))
    root:K2_SetWorldLocation(w, false, getHitResult(), false)
    local sk = keepSize and k or 1.0
    root:SetWorldScale3D(uevrUtils.vector(st.gameScale.X * sk, st.gameScale.Y * sk, st.gameScale.Z * sk))
    st.writtenLoc = vec(root:K2_GetComponentLocation())
    st.writtenScale = vec(root:K2_GetComponentScale())
end

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    local ok, err = pcall(tick)
    if not ok then print("[inspect_vr] " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    st = nil
    if uiOwned then pcall(function() ui.setCustomState("viewLocked", nil) end) end
    uiOwned = false
end)

-- Dark box around the item: the inspection overlay WBP_ZoomObjectUI_C (viewport widget) has a full-screen
-- Image_Vignette that darkens the screen edges flat; on UEVR's UI plane it is a dark translucent box around the item.
-- The game also never removes the overlays (probe 2026-10-09: 22 visible instances after a few inspections), so the
-- vignettes stack darker. While inspecting, every instance's vignette is made fully transparent (render opacity 0;
-- the key hints and description stay). Polled every 0.5 s while inspecting only (each inspection adds an instance).
local ZOOM_UI_CLASS = "WidgetBlueprintGeneratedClass /Game/Maps/Testing/ZlatanSalkanovic/TestsAndWIP/WBP_ZoomObjectUI.WBP_ZoomObjectUI_C"
-- The zoom UI class is a /Game Blueprint class (freed on level/save loads) -> looked up through uevrUtils.get_class on
-- every check (cache hit; uevr_utils drops it on level change), never kept here: a freed class passed to
-- GetAllWidgetsOfClass faults inside the engine and corrupts its Blueprint state (2026-10-15 save-load bug).
local widgetLib, nextVignetteCheck = nil, 0
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if st == nil or configui.getValue("insp_hide_vignette") == false or os.clock() < nextVignetteCheck then return end
    nextVignetteCheck = os.clock() + 0.5
    pcall(function()
        if widgetLib == nil then widgetLib = uevrUtils.find_default_instance("Class /Script/UMG.WidgetBlueprintLibrary") end
        local zoomUIClass = uevrUtils.get_class(ZOOM_UI_CLASS) -- loaded while inspecting
        if widgetLib == nil or zoomUIClass == nil then return end
        local found = {}
        widgetLib:GetAllWidgetsOfClass(uevrUtils.get_world(), found, zoomUIClass, true)
        for _, w in ipairs(found) do
            pcall(function()
                local v = w.Image_Vignette
                if v ~= nil and v.RenderOpacity ~= 0 then v:SetRenderOpacity(0.0) end
            end)
        end
    end)
end)

print("[inspect_vr] loaded")
