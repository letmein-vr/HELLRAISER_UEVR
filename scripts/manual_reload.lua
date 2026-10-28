-- Manual reload for clip-fed pistols (2026-10-19). First weapon: Colt 1911 (SK_Colt_1911 - BP_Colt_1911_C and the
-- Genesis Colt share the mesh).
--
-- Flow: the game's own reload (X) is caught when its montages start and held paused near frame 0. The clip drops out
-- of the gun, a fresh clip sits in a pouch at the left hip; take it with the left grip, push it into the magazine well
-- (it glides in along the grip angle once close), rack the slide if the clip was empty, and the paused native reload is
-- fast-forwarded - the game's own Reload() moves the ammo from the spare stacks into the clip as usual.
--
-- Game facts (MCP + data/reload_probe.txt, 2026-10-19):
--   * The Colt is ONE skeletal mesh. Bones: Root, Slide_jnt, Hammer_jnt, Barrel_End_Jnt, Trigger_jnt, Magazine_jnt,
--     BulletCase_jnt, Bullet_jnt, Magazine_Extended_jnt. All children of Root except BulletCase_jnt (child of
--     Magazine_jnt) and Bullet_jnt (child of BulletCase_jnt) - the top round rides the clip. Magazine_Extended_jnt =
--     the clip-size upgrade (hidden on the real gun without it).
--   * Weapon component space: barrel +Y, up +Z. Root is -90 deg about X, so parent-bone (x,y,z) = component (x,z,-y).
--     Clip rest = component (0, 1.07, 1.50); in the reload animation it leaves along component (0,-0.31,-0.95) (down
--     and slightly back, the grip rake). The slide moves along component -Y, 4.42 cm when firing (rest Y 2.05).
--   * Tactical reload = pawn AM_Revenant_FirstPerson_Pistol_Reload_HalfClip + gun AM_Colt_1911_Reload_halfClip (both
--     1.30 s); empty = AM_Revenant_FirstPerson_Pistol_Reload (gun montage not seen yet). The clip starts moving at
--     0.43 s; AmmoInClip / spare change at ~0.68 s (GA_Reload_C.Reload from a notify).
--   * Ammo: CurrentEquipment.ItemInfo (ItemInfoRangedWeapon).AmmoInClip; spare = CurrentEquipment:GetAmmoInInventory().
--     bHasBulletInChamber is unreliable and ReloadAbilitySpec.ActiveCount reads 0 while reloading -> detection is by
--     montage name, "was empty" by AmmoInClip == 0 when the reload starts.
--
-- Visible parts are PoseableMeshComponent copies of the gun where every bone except the wanted one collapses into the
-- shrunken root (same idea as the VR hands, own bone pass - see applyPart): a clip copy (clip + its top round) and a
-- slide copy.
-- The real gun's bone is hidden (HideBoneByName) while a copy stands in for it.

local uevrUtils   = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui    = require('libs/configui')

local accessories = nil
pcall(function() accessories = require('libs/accessories') end)
local handsAnimation = nil
pcall(function() handsAnimation = require('libs/hands_animation') end)
local hands = nil
pcall(function() hands = require('libs/hands') end)

local vr = uevr.params.vr

local BTN_LB = 0x0100 -- XINPUT_GAMEPAD_LEFT_SHOULDER (the left grip)

-- Per-weapon data, matched against the held skeletal mesh asset name. Directions are weapon component space.
-- defaults = the per-weapon panel values a weapon starts with (saved per weapon in data/manual_reload_parameters.json
-- once touched); pose by attachment pose id.
local PROFILES = {
    {
        id = "colt1911", meshPattern = "SK_Colt_1911", label = "Colt 1911",
        magBones = { "Magazine_Extended_jnt", "Magazine_jnt" }, -- first one the real gun shows is the clip
        roundBone = "BulletCase_jnt",                            -- child of the clip: hidden on an emptied clip
        slideBone = "Slide_jnt",
        magOut = { X = 0.0, Y = -0.307, Z = -0.952 },            -- clip leaves the gun along this
        magCenter = { X = 0.0, Y = -1.84, Z = -5.71 },           -- clip centre from the clip bone (6 cm along magOut)
        slideAxis = { X = 0.0, Y = -1.0, Z = 0.0 },              -- slide pulls back along this
        slideRestY = 2.05,                                       -- Slide_jnt component Y at rest
        defaults = { -- xaero's tuning 2026-10-19
            mr_pouch_loc = { 0.0, -27.0, -58.0 }, mr_pouch_rot = { 0.0, 8.5, 0.0 }, mr_grab_radius = 12.0, mr_pose = "grab_items",
            mr_hold_loc = { 2.0, 5.2, -1.0 }, mr_hold_rot = { -13.0, -89.5, 2.5 },
            mr_insert_radius = 10.39, mr_insert_time = 0.175, mr_insert_depth = 7.42, mr_rock_angle = 0.0,
            mr_rack_point = { 0.0, -3.0, 1.2 }, mr_rack_radius = 10.56, mr_slide_travel = 4.4, mr_rack_done = 0.85,
        },
    },
    -- AK-47 (MCP + probe 2026-10-19): 11 bones, Magazine_jnt (comp 0,20.5,-2.7 - mid-magazine, not its top) with child
    -- Bullet_jnt (top round, comp 0,17.5,9.0), hidden extended_magazine_jnt. NO bolt / charging-handle bone: the rack is a
    -- pull gesture only. Right side = -X (safety lever x -2.3). The game rocks the magazine out: from 0.63 s it moves
    -- ~13 cm forward while rolling to -30 deg about X; ammo moves at 1.68 s (both montages; halfClip 2.47 s, empty 3.77 s).
    {
        id = "ak47", meshPattern = "SK_AK-47", label = "AK-47",
        magBones = { "extended_magazine_jnt", "Magazine_jnt" },
        roundBone = "Bullet_jnt",
        slideBone = nil,                                         -- no moving part: gesture-only rack
        magOut = { X = 0.0, Y = 0.3, Z = -0.954 },               -- down, slightly forward (curved magazine)
        magCenter = { X = 0.0, Y = 2.0, Z = -2.0 },
        slideAxis = { X = 0.0, Y = -1.0, Z = 0.0 },              -- charging handle pulls back
        defaults = {
            mr_pouch_loc = { 4.0, -27.0, -52.0 }, mr_pouch_rot = { 0.0, 8.5, 0.0 }, mr_grab_radius = 14.0, mr_pose = "grab_items",
            mr_hold_loc = { 2.0, 5.2, -1.0 }, mr_hold_rot = { -13.0, -89.5, 2.5 },
            mr_insert_radius = 12.0, mr_insert_time = 0.26, mr_insert_depth = 3.0,
            mr_rock_angle = -25.0, mr_rock_pivot = { 0.0, 22.0, 7.0 },
            mr_rack_point = { -3.0, 26.0, 11.0 }, mr_rack_radius = 12.0, mr_slide_travel = 12.0, mr_rack_done = 0.8,
        },
    },
    -- SMG (MCP + probe 2026-10-19): SK_SMG, 10 bones (Root, Magazine_jnt, ammo_jnt = top round child of Magazine,
    -- extended_magazine_jnt hidden, mode_switch_jnt, muzzle_jnt, magazine_release_jnt, Trigger_jnt, bolt_jnt,
    -- shell_ejector_jnt). Magazine_jnt comp (0,17.2,-2.0) mid-magazine, top round 12 cm above it -> axis down
    -- (0,0.27,-0.96) (raked forward). bolt_jnt = cocking handle, comp (0,24.8,14.4), still when firing; the empty reload
    -- (MP5 style) pulls it back 6.2 cm along -Y and twists it 33 deg into a notch at 0.32 s, slaps it home at 2.48 s.
    -- Magazine goes in from below, slightly forward, ~4 deg extra roll. Ammo: tactical 1.29 s, empty 2.10 s (pawn
    -- AM_FP_ATT_SMG_Reload_halfClip 2.00 s / AM_FP_ATT_SMG_Reload 3.13 s; gun AM_SMG_Reload_halfClip 2.33 s / AM_SMG_Reload).
    {
        id = "smg", meshPattern = "SK_SMG", label = "SMG",
        magBones = { "extended_magazine_jnt", "Magazine_jnt" },
        roundBone = "ammo_jnt",
        slideBone = "bolt_jnt",
        magOut = { X = 0.0, Y = 0.267, Z = -0.964 },
        magCenter = { X = 0.0, Y = 0.0, Z = 1.0 },
        slideAxis = { X = 0.0, Y = -1.0, Z = 0.0 },
        slideRestY = 24.8,
        defaults = {
            mr_pouch_loc = { 4.0, -27.0, -54.0 }, mr_pouch_rot = { 0.0, 8.5, 0.0 }, mr_grab_radius = 13.0, mr_pose = "grab_items",
            mr_hold_loc = { 2.0, 5.2, -1.0 }, mr_hold_rot = { -13.0, -85.0, 29.0 },
            mr_insert_radius = 11.0, mr_insert_time = 0.2, mr_insert_depth = 5.0,
            mr_rock_angle = -8.0, mr_rock_pivot = { 0.0, 16.0, 9.5 },
            mr_rack_point = { 0.0, 24.8, 14.4 }, mr_rack_radius = 10.0, mr_slide_travel = 6.2, mr_rack_done = 0.85,
        },
    },
}
local PROFILE_DEFAULTS = { -- a weapon without its own value for a widget
    mr_pouch_loc = { 8.0, -24.0, -58.0 }, mr_pouch_rot = { 0.0, 0.0, 0.0 }, mr_grab_radius = 12.0, mr_pose = "grab_items",
    mr_hold_loc = { 4.0, 0.0, -1.0 }, mr_hold_rot = { 0.0, -90.0, 90.0 },
    mr_insert_radius = 8.0, mr_insert_time = 0.16, mr_insert_depth = 5.0, mr_rock_angle = 0.0, mr_rock_pivot = { 0.0, 0.0, 0.0 },
    mr_rack_point = { 0.0, -3.0, 8.0 }, mr_rack_radius = 9.0, mr_slide_travel = 4.4, mr_rack_done = 0.85,
    mr_rack_hand_loc = { 0.0, 0.0, 0.0 }, mr_rack_hand_rot = { 0.0, 0.0, 0.0 },
}
local PER_WEAPON_IDS = { "mr_pouch_loc", "mr_pouch_rot", "mr_grab_radius", "mr_pose", "mr_hold_loc", "mr_hold_rot",
    "mr_insert_radius", "mr_insert_time", "mr_insert_depth", "mr_rock_angle", "mr_rock_pivot",
    "mr_rack_point", "mr_rack_radius", "mr_slide_travel", "mr_rack_done", "mr_rack_hand_loc", "mr_rack_hand_rot",
    "mr_rack_hand_loc_ik", "mr_rack_hand_rot_ik" }
-- IK modes place the hand on the slide with their own values; a weapon without them starts from its Hands values
local IK_SEEDED_FROM = { mr_rack_hand_loc_ik = "mr_rack_hand_loc", mr_rack_hand_rot_ik = "mr_rack_hand_rot" }

-- Hand pose while holding a clip: a left-hand attachment pose from data/hands_parameters.json (wizard ids)
local POSE_IDS = { "" }
local poseLabels = { "None (normal grip)" }
pcall(function()
    local params = json.load_file("hands_parameters.json")
    local ids = {}
    for id, _ in pairs((params and params["attachments"]) or {}) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        POSE_IDS[#POSE_IDS + 1] = id
        local label = params["attachments"][id]["label"]
        poseLabels[#poseLabels + 1] = (type(label) == "string" and label ~= "") and label or id
    end
end)
local defaultPose = 1
for i, id in ipairs(POSE_IDS) do
    if id == "magazine" or id == "clip" or id == "mag" then defaultPose = i break end
    if id == "grab_items" or id == "grab_item" then defaultPose = i end
end

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 5.8, label = "Manual Reload", layout = {
    { widgetType = "checkbox", id = "mr_enabled", label = "Manual reload: X drops the magazine, take a new one from the left hip and push it in", initialValue = true },
    { widgetType = "checkbox", id = "mr_rack", label = "Rack the slide / charging handle after an empty magazine", initialValue = true },
    { widgetType = "text", id = "mr_status", label = "Manual reload: -" },
    { widgetType = "spacing" },
    { widgetType = "text", id = "mr_weapon", label = "Settings below are for: (no supported gun held)" },
    { widgetType = "text", label = "-- Hip pouch (cm from the HMD: forward / right / up, body facing)" },
    { widgetType = "drag_float3", id = "mr_pouch_loc", label = "Pouch position", initialValue = { 8.0, -24.0, -58.0 }, range = {-120, 120}, speed = 0.5 },
    { widgetType = "drag_float3", id = "mr_pouch_rot", label = "Pouch clip rotation (pitch / yaw / roll)", initialValue = { 0.0, 0.0, 0.0 }, range = {-180, 180}, speed = 0.5 },
    { widgetType = "slider_float", id = "mr_grab_radius", label = "Grab: hand within (cm of the clip)", initialValue = 12.0, range = {4.0, 30.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "mr_grab_glide", label = "Pouch to hand glide time (s)", initialValue = 0.10, range = {0.0, 0.5}, speed = 0.005 },
    { widgetType = "combo", id = "mr_pose", label = "Left hand pose while holding a clip / racking", initialValue = defaultPose, selections = poseLabels },
    { widgetType = "spacing" },
    { widgetType = "text", label = "-- Clip in the hand (relative to the left controller)" },
    { widgetType = "drag_float3", id = "mr_hold_loc", label = "Clip centre (cm: forward / right / up)", initialValue = { 4.0, 0.0, -1.0 }, range = {-30, 30}, speed = 0.1 },
    { widgetType = "drag_float3", id = "mr_hold_rot", label = "Clip rotation (pitch / yaw / roll)", initialValue = { 0.0, -90.0, 90.0 }, range = {-180, 180}, speed = 0.5 },
    -- all weapons: the Hands-mode hand mesh sits elsewhere on the controller than the IK hand (ik_parameters end_bone_offset)
    { widgetType = "drag_float3", id = "mr_hold_hands_adjust", label = "Hands mode only, all weapons: move the clip (cm: forward / right / up)", initialValue = { -3.0, 0.0, 0.0 }, range = {-20, 20}, speed = 0.1 },
    { widgetType = "spacing" },
    { widgetType = "text", label = "-- Insert" },
    { widgetType = "slider_float", id = "mr_insert_radius", label = "Insert: clip within (cm of the magazine well)", initialValue = 7.0, range = {2.0, 20.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "mr_insert_time", label = "Insert glide time (s)", initialValue = 0.16, range = {0.0, 0.6}, speed = 0.005 },
    { widgetType = "slider_float", id = "mr_insert_depth", label = "Insert: line up this far below the well first (cm)", initialValue = 5.0, range = {0.0, 15.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "mr_rock_angle", label = "Rock-in angle (deg, 0 = straight push; AK: tilted, then rocked back)", initialValue = 0.0, range = {-60.0, 60.0}, speed = 0.5 },
    { widgetType = "drag_float3", id = "mr_rock_pivot", label = "Rock-in pivot (gun space cm: x / y=forward / z=up)", initialValue = { 0.0, 0.0, 0.0 }, range = {-60, 60}, speed = 0.1 },
    { widgetType = "spacing" },
    { widgetType = "text", label = "-- Slide / charging handle rack (after an empty magazine)" },
    { widgetType = "drag_float3", id = "mr_rack_point", label = "Grab point (gun space cm: x / y=forward / z=up)", initialValue = { 0.0, -3.0, 8.0 }, range = {-60, 60}, speed = 0.1 },
    { widgetType = "slider_float", id = "mr_rack_radius", label = "Rack: hand within (cm of the grab point)", initialValue = 9.0, range = {3.0, 25.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "mr_slide_travel", label = "Pull travel (cm)", initialValue = 4.4, range = {1.0, 20.0}, speed = 0.05 },
    { widgetType = "slider_float", id = "mr_rack_done", label = "Pulled far enough at (fraction of the travel)", initialValue = 0.85, range = {0.3, 1.0}, speed = 0.01 },
    { widgetType = "checkbox", id = "mr_rack_hand", label = "All weapons: left hand holds on to the slide / handle while racking", initialValue = true },
    { widgetType = "drag_float3", id = "mr_rack_hand_loc", label = "Hands mode - hand on the slide: move it (gun space cm: x / y=forward / z=up)", initialValue = { 0.0, 0.0, 0.0 }, range = {-30, 30}, speed = 0.1 },
    { widgetType = "drag_float3", id = "mr_rack_hand_rot", label = "Hands mode - hand on the slide: rotate it (hand space: pitch / yaw / roll)", initialValue = { 0.0, 0.0, 0.0 }, range = {-180, 180}, speed = 0.5 },
    { widgetType = "drag_float3", id = "mr_rack_hand_loc_ik", label = "IK modes - hand on the slide: move it (gun space cm: x / y=forward / z=up)", initialValue = { 0.0, 0.0, 0.0 }, range = {-30, 30}, speed = 0.1 },
    { widgetType = "drag_float3", id = "mr_rack_hand_rot_ik", label = "IK modes - hand on the slide: rotate it (hand space: pitch / yaw / roll)", initialValue = { 0.0, 0.0, 0.0 }, range = {-180, 180}, speed = 0.5 },
    { widgetType = "checkbox", id = "mr_rack_hand_preview", label = "Preview: hold the slide now (no reload needed; follows your wrist angle)", initialValue = false },
    { widgetType = "checkbox", id = "mr_debug_rack", label = "Debug: show the rack grab area (sphere = reach, dot = left hand point; shrinks when in reach)", initialValue = false },
    { widgetType = "spacing" },
    { widgetType = "slider_float", id = "mr_finish_rate", label = "Game reload fast-forward (x speed)", initialValue = 20.0, range = {2.0, 40.0}, speed = 0.5 },
    { widgetType = "checkbox", id = "mr_haptics", label = "Haptic pulses (grab / seat / rack)", initialValue = true },
    { widgetType = "checkbox", id = "mr_log", label = "Debug: write data/manual_reload_log.txt", initialValue = false }, -- release: off (new id: the old mr_debug_log was saved on)
}})

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
local function cfgNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end

-- configui drag_float3 values come back as vectors (X/Y/Z) or arrays
local function cfgVec(id, default)
    local v = configui.getValue(id)
    if type(v) == "table" or type(v) == "userdata" then
        local ok, x, y, z = pcall(function() return v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3] end)
        if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
    end
    return default[1], default[2], default[3]
end

local logLines = {}
local function log(text)
    if configui.getValue("mr_log") ~= true then return end
    print("[manual_reload] " .. tostring(text))
    table.insert(logLines, string.format("%.3f %s", os.clock(), tostring(text)))
    while #logLines > 300 do table.remove(logLines, 1) end
    pcall(function() fs.write("manual_reload_log.txt", table.concat(logLines, "\n") .. "\n") end)
end

local nextStatusAt, lastStatus = 0, nil
local function status(text, force)
    if text == lastStatus then return end
    if not force and os.clock() < nextStatusAt then return end
    nextStatusAt, lastStatus = os.clock() + 0.2, text
    configui.setLabel("mr_status", "Manual reload: " .. text)
end

-- ---------------------------------------------------------------------------------------------
-- Per-weapon settings: the panel shows the held weapon's values (loaded without callbacks); edits are stored for
-- that weapon in data/manual_reload_parameters.json { [profile id] = { [widget id] = value } } (pose by id).
-- ---------------------------------------------------------------------------------------------
local PARAMS_FILE = "manual_reload_parameters.json"
local weaponParams = {}
pcall(function()
    local p = json.load_file(PARAMS_FILE)
    if type(p) == "table" then weaponParams = p end
end)
local paramsDirtyAt = nil
local shownProfile = nil

local function poseIndexFor(id)
    for i, pid in ipairs(POSE_IDS) do if pid == id then return i end end
    return defaultPose
end

local function toArray(v)
    if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then return v end
    local ok, x, y, z = pcall(function() return v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3] end)
    if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return { x, y, z } end
    return nil
end

local function profileValue(profile, id)
    local saved = weaponParams[profile.id]
    if saved ~= nil and saved[id] ~= nil then return saved[id] end
    if profile.defaults ~= nil and profile.defaults[id] ~= nil then return profile.defaults[id] end
    return PROFILE_DEFAULTS[id]
end

local function loadProfileToUI(profile)
    -- first time a weapon is held with this build: its IK values start as copies of its Hands values (then separate)
    for ikId, handsId in pairs(IK_SEEDED_FROM) do
        local saved = weaponParams[profile.id]
        if saved == nil or saved[ikId] == nil then
            local v = toArray(profileValue(profile, handsId))
            if type(v) == "table" then
                saved = saved or {}
                weaponParams[profile.id] = saved
                saved[ikId] = { v[1], v[2], v[3] }
                paramsDirtyAt = os.clock()
            end
        end
    end
    for _, id in ipairs(PER_WEAPON_IDS) do
        local v = profileValue(profile, id)
        if id == "mr_pose" then v = poseIndexFor(v) end
        if v ~= nil then configui.setValue(id, v, true) end
    end
    configui.setLabel("mr_weapon", "Settings below are for: " .. profile.label .. " (saved per weapon)")
    shownProfile = profile
end

for _, wid in ipairs(PER_WEAPON_IDS) do
    configui.onUpdate(wid, function(value)
        if shownProfile == nil then return end
        local t = weaponParams[shownProfile.id] or {}
        weaponParams[shownProfile.id] = t
        if wid == "mr_pose" then t[wid] = POSE_IDS[value] or "" else t[wid] = toArray(value) end
        paramsDirtyAt = os.clock()
    end)
end

local function saveParamsIfDirty(now)
    if paramsDirtyAt == nil or now - paramsDirtyAt < 1.0 then return end
    paramsDirtyAt = nil
    pcall(function() json.dump_file(PARAMS_FILE, weaponParams, 4) end)
end

local function exists(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return UEVR_UObjectHook.exists(obj) end)
    return ok and r == true
end

local function addr(obj)
    if obj == nil then return nil end
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or nil
end

local function fname(s) return uevrUtils.fname_from_string(s) end
local function vec(x, y, z) return uevrUtils.vector(x, y, z) end
local function copyV(v) return { X = v.X, Y = v.Y, Z = v.Z } end
local function copyR(r) return { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } end
local function addV(a, b) return { X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z } end
local function subV(a, b) return { X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z } end
local function mulV(a, s) return { X = a.X * s, Y = a.Y * s, Z = a.Z * s } end
local function dotV(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
local function lenV(a) return math.sqrt(dotV(a, a)) end

-- FRotationMatrix axes (images of the local X / Y / Z axes)
local function axes(rot)
    local p, y, r = math.rad(rot.Pitch), math.rad(rot.Yaw), math.rad(rot.Roll)
    local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    return { X = cp * cy, Y = cp * sy, Z = sp },
           { X = sr * sp * cy - cr * sy, Y = sr * sp * sy + cr * cy, Z = -sr * cp },
           { X = -(cr * sp * cy + sr * sy), Y = cy * sr - cr * sp * sy, Z = cr * cp }
end
local function rotateV(v, rot)
    local ax, ay, az = axes(rot)
    return { X = ax.X * v.X + ay.X * v.Y + az.X * v.Z, Y = ax.Y * v.X + ay.Y * v.Y + az.Y * v.Z, Z = ax.Z * v.X + ay.Z * v.Y + az.Z * v.Z }
end

-- gun component space -> world
local function gunPoint(gun, p)
    local w = kismet_math_library:TransformLocation(gun:K2_GetComponentToWorld(), vec(p.X, p.Y, p.Z))
    return { X = w.X, Y = w.Y, Z = w.Z }
end
local function gunDir(gun, d)
    local w = kismet_math_library:TransformDirection(gun:K2_GetComponentToWorld(), vec(d.X, d.Y, d.Z))
    return { X = w.X, Y = w.Y, Z = w.Z }
end

local function haptic(duration, amplitude)
    if configui.getValue("mr_haptics") == false then return end
    pcall(function() vr.trigger_haptic_vibration(0, duration, 1.0, amplitude, vr.get_left_joystick_source()) end)
end

local function traceLine(from, to, ignore)
    local world = uevrUtils.get_world()
    if world == nil then return nil end
    local hit = kismet_system_library:LineTraceSingle(world, vec(from.X, from.Y, from.Z), vec(to.X, to.Y, to.Z),
        0, false, ignore or {}, 0, reusable_hit_result, true, zero_color, zero_color, 0.0)
    if hit then
        local l = reusable_hit_result.Location
        return { X = l.X, Y = l.Y, Z = l.Z }
    end
    return nil
end

local function blockedReason()
    if _G.hrIsInMenu ~= nil and _G.hrIsInMenu() then return "menu" end
    if _G.hrCutsceneActive == true then return "cutscene" end
    if _G.hrIsVideoPlaying ~= nil and _G.hrIsVideoPlaying() then return "video" end
    if _G.hrIsInFocusPuzzle ~= nil and _G.hrIsInFocusPuzzle() then return "puzzle / inspection" end
    if _G.hrIsSeated ~= nil and _G.hrIsSeated() then return "seated" end
    return nil
end

-- ---------------------------------------------------------------------------------------------
-- Part copies (PoseableMeshComponent of the gun, one bone kept)
-- ---------------------------------------------------------------------------------------------
-- The engine re-initialises a fresh PoseableMeshComponent's bones on its first tick(s) and wipes writes made in the
-- creation frame (libs/hands.lua, OW2) - for those frames the copy would show the WHOLE gun. So a copy stays invisible
-- for SHOW_AFTER_S while the bone pass is re-applied every tick; onVisible then swaps it in for the real part.
local SHOW_AFTER_S         = 0.08
local REAPPLY_EVERY_TICK_S = 0.4
local REAPPLY_UNTIL_S      = 3.0

local parts = {}  -- all live copies: { comp, bone, rootBone, t, rootT, hideRound, created, nextApply, visible, onVisible }

-- Bone pass, absolute writes in COMPONENT space (EBoneSpaces 1) so re-applying is idempotent: the root bone shrinks to
-- 0.001 at the kept bone's position, the kept bone gets its rest transform back (the poseable converts it to local
-- through the shrunken parent, x1000), its children keep their local transforms. NOT animation.transformBoneToRoot:
-- that one reads the root's current transform as its reference, and here the kept bone's parent IS the root bone,
-- so a second pass would shrink the kept bone too. Transforms come from the REAL gun (its pose is reliable; a fresh
-- poseable can read identity in its first frames).
local BONE_SPACE_COMPONENT = 1
local RTS_COMPONENT = 2
local function splitT(t)
    local r = kismet_math_library:TransformRotation(t, uevrUtils.rotator(0, 0, 0))
    return { loc = { X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z },
             rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll },
             scale = { X = t.Scale3D.X, Y = t.Scale3D.Y, Z = t.Scale3D.Z } }
end
local function makeT(loc, rot, scale)
    return kismet_math_library:MakeTransform(vec(loc.X, loc.Y, loc.Z), uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll), vec(scale.X, scale.Y, scale.Z))
end

local function applyPart(p)
    local tiny = { X = 0.001, Y = 0.001, Z = 0.001 }
    p.comp:SetBoneTransformByName(fname(p.rootBone), makeT(p.t.loc, p.rootT.rot, tiny), BONE_SPACE_COMPONENT)
    p.comp:SetBoneTransformByName(fname(p.bone), makeT(p.t.loc, p.t.rot, p.t.scale), BONE_SPACE_COMPONENT)
    if p.hideRound ~= nil then
        p.comp:SetBoneScaleByName(fname(p.hideRound), vector_3f(0.001, 0.001, 0.001), BONE_SPACE_COMPONENT)
    end
end

-- restLoc (optional): component-space location to use for the kept bone instead of where the real gun has it now
local function createPart(gun, bone, hideRound, onVisible, restLoc)
    local p = nil
    local ok, err = pcall(function()
        local rootBone = gun:GetBoneName(0):to_string()
        local t = splitT(gun:GetSocketTransform(fname(bone), RTS_COMPONENT))
        local rootT = splitT(gun:GetSocketTransform(fname(rootBone), RTS_COMPONENT))
        if restLoc ~= nil then t.loc = copyV(restLoc) end
        local comp = uevrUtils.createPoseableMeshFromSkeletalMesh(gun, { useDefaultPose = true })
        if comp == nil then return end
        pcall(function() comp:SetVisibility(false, true) end)
        pcall(function() comp:SetCastShadow(false) end)
        pcall(function() comp.BoundsScale = 2.0 end)
        p = { comp = comp, bone = bone, rootBone = rootBone, t = t, rootT = rootT, hideRound = hideRound, created = os.clock(),
              nextApply = 0, visible = false, onVisible = onVisible }
        applyPart(p)
        pcall(function() comp:K2_SetWorldTransform(gun:K2_GetComponentToWorld(), false, reusable_hit_result, true) end)
        table.insert(parts, p)
    end)
    if not ok then log("createPart " .. bone .. ": " .. tostring(err)) end
    return p
end

local function destroyPart(p)
    if p == nil then return end
    for i = #parts, 1, -1 do if parts[i] == p then table.remove(parts, i) end end
    if exists(p.comp) then pcall(function() uevrUtils.destroyComponent(p.comp, true, false) end) end
    p.comp = nil
end

local function forgetParts() parts = {} end -- level change: they went with the old world

local function tickParts(now)
    for i = #parts, 1, -1 do
        local p = parts[i]
        local age = now - p.created
        if age < REAPPLY_UNTIL_S and (age < REAPPLY_EVERY_TICK_S or now >= p.nextApply) then
            p.nextApply = now + 0.25
            local ok = pcall(applyPart, p)
            if not ok then table.remove(parts, i) end
        end
        if not p.visible and age >= SHOW_AFTER_S and parts[i] == p then
            p.visible = true
            pcall(function() p.comp:SetVisibility(true, true) end)
            if p.onVisible ~= nil then
                local cb = p.onVisible
                p.onVisible = nil
                local ok, err = pcall(cb, p)
                if not ok then log("onVisible: " .. tostring(err)) end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Falling clips (ejected / dropped): fall with gravity, land on the first surface, vanish after a while
-- ---------------------------------------------------------------------------------------------
local GRAVITY = 980.0
local FALL_MAX_S = 3.0
local LANDED_LIFETIME_S = 10.0
local fallers = {}

local function startFall(part, vel, centerLocal)
    pcall(function() part.comp:K2_DetachFromComponent(1, 1, 1) end)
    local l, r = part.comp:K2_GetComponentLocation(), part.comp:K2_GetComponentRotation()
    table.insert(fallers, { part = part, pos = copyV(l), rot = copyR(r), vel = vel, t0 = os.clock(), landedAt = nil, centerLocal = centerLocal })
end

local function updateFallers(dt, pawn)
    local now = os.clock()
    for i = #fallers, 1, -1 do
        local f = fallers[i]
        local done = false
        if f.part.comp == nil or not exists(f.part.comp) then
            done = true
        elseif f.landedAt ~= nil then
            done = now - f.landedAt > LANDED_LIFETIME_S
        elseif now - f.t0 > FALL_MAX_S then
            done = true
        else
            local ok = pcall(function()
                local nv = { X = f.vel.X, Y = f.vel.Y, Z = f.vel.Z - GRAVITY * dt }
                local np = addV(f.pos, mulV(nv, dt))
                -- trace the clip's centre path (the component origin is the collapsed gun root, a few cm away)
                local c = rotateV(f.centerLocal, f.rot)
                local hit = traceLine(addV(f.pos, c), addV(np, c), { pawn })
                if hit ~= nil then
                    np = subV(hit, c)
                    np.Z = np.Z + 1.5
                    f.landedAt = now
                end
                f.pos, f.vel = np, nv
                f.part.comp:K2_SetWorldLocation(vec(np.X, np.Y, np.Z), false, reusable_hit_result, true)
            end)
            if not ok then done = true end
        end
        if done then
            destroyPart(f.part)
            table.remove(fallers, i)
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------
local S_IDLE, S_AWAIT_MAG, S_HOLD, S_INSERT, S_AWAIT_RACK, S_RACK, S_FINISH = "idle", "await_clip", "holding_clip", "inserting", "await_rack", "racking", "finishing"
local state = S_IDLE
local LATE_CATCH_S = 0.4          -- a reload montage further along than this is left to the game
local noInterceptUntil = 0        -- short guard after a reload ends (its montage may still read as active)

local cur = {       -- the reload in progress
    pawn = nil, equipment = nil, gun = nil, profile = nil,
    pawnAnim = nil, pawnMontage = nil, gunAnim = nil, gunMontage = nil,
    magBone = nil, wasEmpty = false, clipBefore = 0,
    hiddenBones = {},         -- bone names hidden on the real gun
    held = nil, seated = nil, slide = nil,
    insert = nil, rack = nil, finishStart = 0, grabGlide = nil,
}
local rackHand = nil       -- left hand riding the slide while racking (see "Left hand on the slide")
local releaseRackHand      -- defined there; cleanup() lets the hand go
local pouch = nil          -- part shown at the hip
local pouchKey = nil       -- gun address + bone the pouch copy was built for
local spareAmmo = 0
local nextSparePoll = 0

-- input (written by the input callback, read by the tick)
local gripDown, gripPressed, gripReleased = false, false, false
local swallowGrip = false
local pressLocked = false  -- the input callback locked the left hand for a press the tick has not handled yet
local nearPouch, nearSlide = false, false

local accessoriesSuspended = false
local function suspendAccessories(on)
    if accessories == nil or on == accessoriesSuspended then return end
    accessoriesSuspended = on
    pcall(function() accessories.setDisabled(on) end)
end

local poseActive = false
local function setHandPose(on)
    if handsAnimation == nil then return end
    if on then
        local id = POSE_IDS[configui.getValue("mr_pose") or defaultPose]
        pcall(function()
            handsAnimation.setInputLocked(Handed.Left, true)
            if id ~= nil and id ~= "" then handsAnimation.setHoldingAttachment(Handed.Left, id) end
        end)
        poseActive = true
    elseif poseActive then
        poseActive = false
        pcall(function()
            handsAnimation.setInputLocked(Handed.Left, false)
            handsAnimation.setHoldingAttachment(Handed.Left, nil)
        end)
    end
end

local function profileFor(gun)
    local name = nil
    pcall(function()
        local asset = gun.SkeletalMesh or gun.SkinnedAsset
        if asset ~= nil then name = asset:get_fname():to_string() end
    end)
    if name == nil then return nil end
    for _, p in ipairs(PROFILES) do
        if string.find(name, p.meshPattern, 1, true) ~= nil then return p end
    end
    return nil
end

local function visibleMagBone(gun, profile)
    for _, b in ipairs(profile.magBones) do
        local hidden = true
        pcall(function() hidden = gun:IsBoneHiddenByName(fname(b)) end)
        if not hidden then return b end
    end
    return profile.magBones[#profile.magBones]
end

local function magCenterLocal(gun, profile, bone)
    local t = gun:GetSocketTransform(fname(bone), 2) -- component space
    return addV({ X = t.Translation.X, Y = t.Translation.Y, Z = t.Translation.Z }, profile.magCenter)
end

local function hideGunBone(bone)
    if cur.gun == nil then return end
    pcall(function() cur.gun:HideBoneByName(fname(bone), 0) end)
    table.insert(cur.hiddenBones, bone)
end

local function unhideGunBones()
    if cur.gun ~= nil and exists(cur.gun) then
        for _, b in ipairs(cur.hiddenBones) do pcall(function() cur.gun:UnHideBoneByName(fname(b)) end) end
    end
    cur.hiddenBones = {}
end

local function montageOf(anim)
    local m = nil
    pcall(function() m = anim:GetCurrentActiveMontage() end)
    return m
end

local function montageName(m)
    local n = nil
    pcall(function() n = m:get_fname():to_string() end)
    return n
end

local function isReloadMontage(m)
    local n = m ~= nil and montageName(m) or nil
    return n ~= nil and string.find(string.lower(n), "reload", 1, true) ~= nil
end

local function enter(s)
    if s ~= state then log("state " .. state .. " -> " .. s) end
    state = s
    local handBusy = (s == S_HOLD or s == S_INSERT or s == S_RACK)
    -- the left hand works at the gun: keep accessories (proximity grips) off the hand
    suspendAccessories(handBusy or s == S_AWAIT_RACK)
    if not handBusy then setHandPose(false) end
end

-- everything back to normal; resumeGame: the native reload is still paused and should play on at normal speed
local function cleanup(resumeGame, reason)
    log("cleanup (" .. tostring(reason) .. ")")
    if resumeGame then
        pcall(function() if cur.pawnMontage ~= nil then cur.pawnAnim:Montage_Resume(cur.pawnMontage) cur.pawnAnim:Montage_SetPlayRate(cur.pawnMontage, 1.0) end end)
        pcall(function() if cur.gunMontage ~= nil then cur.gunAnim:Montage_Resume(cur.gunMontage) cur.gunAnim:Montage_SetPlayRate(cur.gunMontage, 1.0) end end)
    end
    releaseRackHand(os.clock())
    unhideGunBones()
    if cur.held ~= nil then destroyPart(cur.held) end
    if cur.seated ~= nil then destroyPart(cur.seated) end
    if cur.slide ~= nil then destroyPart(cur.slide) end
    cur.held, cur.seated, cur.slide, cur.insert, cur.rack, cur.grabGlide = nil, nil, nil, nil, nil, nil
    cur.pawnMontage, cur.gunMontage, cur.pawnAnim, cur.gunAnim = nil, nil, nil, nil
    cur.equipment, cur.gun, cur.profile, cur.pawn = nil, nil, nil, nil
    swallowGrip = false
    noInterceptUntil = os.clock() + 0.5
    enter(S_IDLE)
end

-- ---------------------------------------------------------------------------------------------
-- Reload start: catch the native reload, hold it, eject the clip
-- ---------------------------------------------------------------------------------------------
local function tryIntercept(pawn, equipment, gun, profile)
    local pawnAnim = pawn.Mesh and pawn.Mesh.AnimScriptInstance or nil
    if pawnAnim == nil then return end
    local pm = montageOf(pawnAnim)
    if not isReloadMontage(pm) or os.clock() < noInterceptUntil then return end
    -- only a reload that has just started (the clip leaves the gun at 0.43 s; a fast-forwarded one ends at 1.3 s)
    local pos = 0
    pcall(function() pos = pawnAnim:Montage_GetPosition(pm) end)
    if type(pos) ~= "number" or pos > LATE_CATCH_S then return end
    local gunAnim = gun.AnimScriptInstance
    local gm = gunAnim ~= nil and montageOf(gunAnim) or nil
    if not isReloadMontage(gm) then gm = nil end

    pcall(function() pawnAnim:Montage_Pause(pm) end)
    if gm ~= nil then pcall(function() gunAnim:Montage_Pause(gm) end) end

    cur.pawn, cur.equipment, cur.gun, cur.profile = pawn, equipment, gun, profile
    cur.pawnAnim, cur.pawnMontage, cur.gunAnim, cur.gunMontage = pawnAnim, pm, gunAnim, gm
    cur.clipBefore = 0
    pcall(function() cur.clipBefore = equipment.ItemInfo.AmmoInClip end)
    cur.wasEmpty = cur.clipBefore == 0
    cur.magBone = visibleMagBone(gun, profile)
    cur.hiddenBones = {}

    log(string.format("reload caught: pawn %s at %.2f, gun %s; clip %d (%s), clip bone %s", tostring(montageName(pm)), pos,
        tostring(gm and montageName(gm) or "-"), cur.clipBefore, cur.wasEmpty and "empty" or "tactical", cur.magBone))

    nextSparePoll = 0

    -- eject: once the copy is ready it takes the real clip's place and falls out of the well
    local magBone = cur.magBone
    local drop = createPart(gun, magBone, cur.wasEmpty and profile.roundBone or nil, function(p)
        if state == S_IDLE or cur.gun ~= gun then destroyPart(p) return end
        p.comp:K2_SetWorldTransform(gun:K2_GetComponentToWorld(), false, reusable_hit_result, true)
        hideGunBone(magBone)
        startFall(p, mulV(gunDir(gun, profile.magOut), 150.0), magCenterLocal(gun, profile, magBone))
        haptic(0.04, 0.4)
    end)
    if drop == nil then hideGunBone(magBone) end
    enter(S_AWAIT_MAG)
end

-- ---------------------------------------------------------------------------------------------
-- Pouch
-- ---------------------------------------------------------------------------------------------
local function pouchTransform(gun, profile, bone)
    local head = controllers.getControllerLocation(2)
    local hr = controllers.getControllerRotation(2)
    if head == nil or hr == nil then return nil end
    local yaw = hr.Yaw or 0
    local fx, fy, fz = cfgVec("mr_pouch_loc", { 8.0, -24.0, -58.0 })
    local f, r = axes({ Pitch = 0, Yaw = yaw, Roll = 0 })
    local point = { X = head.X + f.X * fx + r.X * fy, Y = head.Y + f.Y * fx + r.Y * fy, Z = head.Z + fz }
    -- the copy is the whole gun frame: upright, barrel forward (mesh +Y), the clip hanging below its top
    local px, py, pz = cfgVec("mr_pouch_rot", { 0.0, 0.0, 0.0 })
    local base = uevrUtils.rotator(0, yaw - 90.0, 0)
    local rr = kismet_math_library:ComposeRotators(uevrUtils.rotator(px, py, pz), base)
    local rot = { Pitch = rr.Pitch, Yaw = rr.Yaw, Roll = rr.Roll }
    local c = rotateV(magCenterLocal(gun, profile, bone), rot)
    return subV(point, c), rot, point
end

local function destroyPouch()
    if pouch ~= nil then destroyPart(pouch) end
    pouch, pouchKey = nil, nil
end

local function updatePouch(gun, profile, show)
    if not show then
        destroyPouch()
        nearPouch = false
        return
    end
    local bone = visibleMagBone(gun, profile)
    local key = tostring(addr(gun)) .. bone
    if pouch == nil or pouchKey ~= key or not exists(pouch.comp) then
        destroyPouch()
        pouch = createPart(gun, bone, nil)
        pouchKey = key
        if pouch == nil then return end
    end
    local loc, rot, point = pouchTransform(gun, profile, bone)
    if loc == nil then return end
    pcall(function() pouch.comp:K2_SetWorldLocationAndRotation(vec(loc.X, loc.Y, loc.Z), uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll), false, reusable_hit_result, true) end)
    local hand = controllers.getControllerLocation(Handed.Left)
    local was = nearPouch
    nearPouch = hand ~= nil and lenV(subV(hand, point)) <= cfgNum("mr_grab_radius", 12.0)
    if nearPouch and not was and state == S_AWAIT_MAG then haptic(0.02, 0.25) end
end

-- ---------------------------------------------------------------------------------------------
-- Clip in the hand
-- ---------------------------------------------------------------------------------------------
local function holdRelative()
    local hx, hy, hz = cfgVec("mr_hold_loc", { 4.0, 0.0, -1.0 })
    -- the hold offsets are relative to the raw controller, and the visible hand sits differently on it per hands mode
    -- (IK: libs/ik end_bone_offset ~6-8 cm back; Hands mode: the hand mesh's own offset) - Hands mode gets a shift
    if not (_G.getHandsMode ~= nil and _G.getHandsMode() == 2) then
        local ax, ay, az = cfgVec("mr_hold_hands_adjust", { -3.0, 0.0, 0.0 })
        hx, hy, hz = hx + ax, hy + ay, hz + az
    end
    local rp, ry, rr = cfgVec("mr_hold_rot", { 0.0, -90.0, 90.0 })
    local rot = { Pitch = rp, Yaw = ry, Roll = rr }
    local c = rotateV(magCenterLocal(cur.gun, cur.profile, cur.magBone), rot)
    return { X = hx - c.X, Y = hy - c.Y, Z = hz - c.Z }, rot
end

local function grabFromPouch()
    local controller = controllers.getController(Handed.Left, true)
    if controller == nil then return false end
    -- the pouch clip itself goes to the hand (a new copy would be invisible for its first frames); the pouch is
    -- rebuilt once the hand is free again
    local part = pouch
    if part == nil or not exists(part.comp) or part.bone ~= cur.magBone then return false end
    pouch, pouchKey = nil, nil
    part.comp:K2_AttachToComponent(controller, fname(""), 1, 1, 1, false) -- keep world
    local rl, rr = part.comp.RelativeLocation, part.comp.RelativeRotation
    cur.grabGlide = { start = os.clock(), loc = copyV(rl), rot = copyR(rr) }
    cur.held = part
    setHandPose(true)
    haptic(0.03, 0.5)
    enter(S_HOLD)
    log("clip taken from the pouch")
    return true
end

local function smooth(t) return t * t * (3 - 2 * t) end

local function updateHeld()
    local part = cur.held
    if part == nil or not exists(part.comp) then return false end
    local loc, rot = holdRelative()
    local g = cur.grabGlide
    local T = cfgNum("mr_grab_glide", 0.10)
    if g ~= nil and T > 0 then
        local a = math.min(1.0, (os.clock() - g.start) / T)
        if a >= 1.0 then cur.grabGlide = nil end
        local e = smooth(a)
        local l = addV(g.loc, mulV(subV(loc, g.loc), e))
        local r = kismet_math_library:RLerp(uevrUtils.rotator(g.rot.Pitch, g.rot.Yaw, g.rot.Roll), uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll), e, true)
        part.comp:K2_SetRelativeLocationAndRotation(vec(l.X, l.Y, l.Z), r, false, reusable_hit_result, true)
    else
        cur.grabGlide = nil
        part.comp:K2_SetRelativeLocationAndRotation(vec(loc.X, loc.Y, loc.Z), uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll), false, reusable_hit_result, true)
    end
    return true
end

local function dropHeld(pawn)
    local part = cur.held
    cur.held, cur.grabGlide = nil, nil
    if part == nil or not exists(part.comp) then return end
    startFall(part, { X = 0, Y = 0, Z = -50 }, magCenterLocal(cur.gun, cur.profile, cur.magBone))
    log("clip let go - dropped")
end

-- the held clip's centre vs the well's (clip centre of the gun), world cm
local function wellDistance()
    local c = magCenterLocal(cur.gun, cur.profile, cur.magBone)
    local held = cur.held.comp
    local hw = kismet_math_library:TransformLocation(held:K2_GetComponentToWorld(), vec(c.X, c.Y, c.Z))
    local gw = gunPoint(cur.gun, c)
    return lenV(subV({ X = hw.X, Y = hw.Y, Z = hw.Z }, gw))
end

-- ---------------------------------------------------------------------------------------------
-- Insert glide: the held copy moves onto the gun (relative identity = exactly where the real clip sits)
-- ---------------------------------------------------------------------------------------------
local function startInsert()
    local part = cur.held
    cur.held, cur.grabGlide = nil, nil
    part.comp:K2_AttachToComponent(cur.gun, fname(""), 1, 1, 1, false) -- keep world
    local rl, rr = part.comp.RelativeLocation, part.comp.RelativeRotation
    cur.seated = part
    local px, py, pz = cfgVec("mr_rock_pivot", { 0.0, 0.0, 0.0 })
    cur.insert = { start = os.clock(), loc = copyV(rl), rot = copyR(rr), depth = cfgNum("mr_insert_depth", 5.0),
        angle = cfgNum("mr_rock_angle", 0.0), pivot = { X = px, Y = py, Z = pz } }
    setHandPose(false)
    enter(S_INSERT)
    log(string.format("insert glide from (%.1f %.1f %.1f), rock %.0f deg", rl.X, rl.Y, rl.Z, cur.insert.angle))
end

-- the copy's relative transform on the gun: seated = identity; depthFrac 1 = held out along magOut by the insert depth;
-- angle = rolled about the gun X axis through the rock pivot (AK: tilted forward, hooked in, rocked back)
local function seatPose(ins, depthFrac, angle)
    local rot = { Pitch = 0, Yaw = 0, Roll = angle }
    local l = mulV(cur.profile.magOut, ins.depth * depthFrac)
    if angle ~= 0 then l = addV(l, subV(ins.pivot, rotateV(ins.pivot, rot))) end
    return l, rot
end

local INSERT_ALIGN_FRACTION = 0.55
local function updateInsert()
    local ins, part = cur.insert, cur.seated
    if ins == nil or part == nil or not exists(part.comp) then return true end
    local T = cfgNum("mr_insert_time", 0.16)
    local a = T > 0 and math.min(1.0, (os.clock() - ins.start) / T) or 1.0
    local l, r
    if a < INSERT_ALIGN_FRACTION then
        -- line up below the well (tilted when rocking in)
        local t = a / INSERT_ALIGN_FRACTION
        local e = 1 - (1 - t) * (1 - t) -- ease out
        local pl, pr = seatPose(ins, 1, ins.angle)
        l = addV(ins.loc, mulV(subV(pl, ins.loc), e))
        local rr = kismet_math_library:RLerp(uevrUtils.rotator(ins.rot.Pitch, ins.rot.Yaw, ins.rot.Roll), uevrUtils.rotator(pr.Pitch, pr.Yaw, pr.Roll), e, true)
        r = { Pitch = rr.Pitch, Yaw = rr.Yaw, Roll = rr.Roll }
    else
        local t = (a - INSERT_ALIGN_FRACTION) / (1 - INSERT_ALIGN_FRACTION)
        if ins.angle == 0 then
            l, r = seatPose(ins, 1 - t * t, 0) -- ease in: slides home
        elseif t < 0.5 then
            local s = t / 0.5
            l, r = seatPose(ins, 1 - s * s, ins.angle) -- push the front in
        else
            local s = (t - 0.5) / 0.5
            l, r = seatPose(ins, 0, ins.angle * (1 - s * s)) -- rock back home
        end
    end
    if a >= 1.0 then l, r = { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 } end
    part.comp:K2_SetRelativeLocationAndRotation(vec(l.X, l.Y, l.Z), uevrUtils.rotator(r.Pitch, r.Yaw, r.Roll), false, reusable_hit_result, true)
    pcall(function() part.comp:SetRelativeScale3D(vec(1, 1, 1)) end)
    return a >= 1.0
end

-- ---------------------------------------------------------------------------------------------
-- Finish: let the paused native reload run fast; parts stay until its montages end
-- ---------------------------------------------------------------------------------------------
local FINISH_TIMEOUT_S = 3.0

local function startFinish()
    local rate = cfgNum("mr_finish_rate", 20.0)
    pcall(function() cur.pawnAnim:Montage_SetPlayRate(cur.pawnMontage, rate) cur.pawnAnim:Montage_Resume(cur.pawnMontage) end)
    if cur.gunMontage ~= nil then
        pcall(function() cur.gunAnim:Montage_SetPlayRate(cur.gunMontage, rate) cur.gunAnim:Montage_Resume(cur.gunMontage) end)
    end
    cur.finishStart = os.clock()
    enter(S_FINISH)
    log(string.format("native reload resumed at %.0fx", rate))
end

local function finishDone()
    local pm = montageOf(cur.pawnAnim)
    local gm = cur.gunAnim ~= nil and montageOf(cur.gunAnim) or nil
    local pawnBusy = pm ~= nil and addr(pm) == addr(cur.pawnMontage)
    local gunBusy = cur.gunMontage ~= nil and gm ~= nil and addr(gm) == addr(cur.gunMontage)
    return not pawnBusy and not gunBusy
end

-- the ammo log waits a moment: the AK's refill lands a tick AFTER its montages end (the Colt's mid-montage)
local ammoCheck = nil -- { at, equipment, before }
local function endFinish(timeout)
    log(string.format("reload finished%s", timeout and " (timeout)" or ""))
    ammoCheck = { at = os.clock() + 0.3, equipment = cur.equipment, before = cur.clipBefore }
    haptic(0.02, 0.3)
    cleanup(false, "done")
end

local function checkAmmoLog(now)
    local c = ammoCheck
    if c == nil or now < c.at then return end
    ammoCheck = nil
    local clip = -1
    pcall(function() if exists(c.equipment) then clip = c.equipment.ItemInfo.AmmoInClip end end)
    log(string.format("ammo: clip %d -> %d", c.before, clip))
end

-- ---------------------------------------------------------------------------------------------
-- Slide rack
-- ---------------------------------------------------------------------------------------------
local function rackPointLocal(pull, profile)
    local x, y, z = cfgVec("mr_rack_point", { 0.0, -3.0, 8.0 })
    return addV({ X = x, Y = y, Z = z }, mulV((profile or cur.profile).slideAxis, pull))
end

local function setSlidePull(pull)
    local part = cur.slide
    if part == nil or not exists(part.comp) then return end
    local o = mulV(cur.profile.slideAxis, pull)
    part.comp:K2_SetRelativeLocationAndRotation(vec(o.X, o.Y, o.Z), uevrUtils.rotator(0, 0, 0), false, reusable_hit_result, true)
end

-- cur.rack + the moving part copy (slide / handle)
local function setupRack()
    if cur.profile.slideBone == nil then
        -- no moving part on this mesh (AK-47: the charging handle is part of the receiver): pull gesture only
        cur.rack = { lockBack = 0, pull = 0, grabbed = false, armed = false, spring = nil, ready = true }
        log("rack: gesture only (no handle bone)")
        return true
    end
    -- the real slide hands over to a copy; where the paused animation holds it (locked back on empty) is kept
    local lockBack, restLoc = 0, nil
    pcall(function()
        local t = cur.gun:GetSocketTransform(fname(cur.profile.slideBone), RTS_COMPONENT)
        lockBack = math.max(0, math.min(cfgNum("mr_slide_travel", 4.4), cur.profile.slideRestY - t.Translation.Y))
        restLoc = { X = t.Translation.X, Y = cur.profile.slideRestY, Z = t.Translation.Z } -- the copy is built closed
    end)
    local slideBone = cur.profile.slideBone
    local part = createPart(cur.gun, slideBone, nil, function(p)
        if cur.slide ~= p then return end
        hideGunBone(slideBone) -- the copy stands in for the real slide from now on
        cur.rack.ready = true
    end, restLoc)
    if part == nil then return false end
    part.comp:K2_AttachToComponent(cur.gun, fname(""), 2, 2, 2, false) -- snap: identity on the gun
    cur.slide = part
    cur.rack = { lockBack = lockBack, pull = lockBack, grabbed = false, armed = false, spring = nil, ready = false }
    setSlidePull(lockBack)
    log(string.format("rack: %s copy ready (held back %.2f cm)", slideBone, lockBack))
    return true
end

local function startAwaitRack()
    if not setupRack() then
        log("slide copy failed - finishing without a rack")
        startFinish()
        return
    end
    enter(S_AWAIT_RACK)
    log("waiting for the rack")
end

-- Left hand on the slide while racking (2026-10-23): while the slide is held, the visible left hand rides on it -
-- placed as if the controller sat on the grab point (+ mr_rack_hand_loc, gun space) with the controller's grab-time
-- rotation relative to the gun, moving with the pull; on release it glides back to the controller.
-- IK modes: libs/ik.lua's accessory channel ("on_accessory_attach" with that controller pose in gun space, as
-- two_handed.lua does; ik.lua blends on and off itself). Hands mode: the glove is re-parented to the gun here and
-- glided (two_handed.lua's way) - libs/hands.lua's accessory channel would compose the arm mesh's base rotation
-- (Pawn.Mesh yaw -90) into the glove rotation a second time.
-- rackHand (declared with the state) = { ik, ctrlRot (gun space), glove, gloveLoc / gloveRot (glove in controller
-- space), snap (the glove's parent + relative transform before), glide, returning }

local function ikHandsMode() return _G.getHandsMode ~= nil and _G.getHandsMode() == 2 end
local function handGlideTime()
    local v = configui.getValue("th_offhand_glide") -- two_handed.lua's off-hand glide
    return type(v) == "number" and v or 0.15
end

-- pose for the current pull, gun space: the virtual controller (IK) or the glove on it (Hands mode).
-- mr_rack_hand_rot turns the virtual controller in its own frame; a preview (rh.preview) sits on the closed slide.
-- IK modes use their own pair (mr_rack_hand_loc_ik / _rot_ik).
local function rackHandTarget(rh)
    local suffix = rh.ik and "_ik" or ""
    local x, y, z = cfgVec("mr_rack_hand_loc" .. suffix, { 0.0, 0.0, 0.0 })
    local p = addV(rackPointLocal(rh.preview and 0 or cur.rack.pull, rh.profile), { X = x, Y = y, Z = z })
    local rp, ry, rr = cfgVec("mr_rack_hand_rot" .. suffix, { 0.0, 0.0, 0.0 })
    local ctrl = copyR(kismet_math_library:ComposeRotators(uevrUtils.rotator(rp, ry, rr),
        uevrUtils.rotator(rh.ctrlRot.Pitch, rh.ctrlRot.Yaw, rh.ctrlRot.Roll)))
    if rh.ik then return p, ctrl end
    local rot = kismet_math_library:ComposeRotators(uevrUtils.rotator(rh.gloveRot.Pitch, rh.gloveRot.Yaw, rh.gloveRot.Roll),
        uevrUtils.rotator(ctrl.Pitch, ctrl.Yaw, ctrl.Roll))
    return addV(p, rotateV(rh.gloveLoc, ctrl)), copyR(rot)
end

-- the left controller's rotation in gun space (the grab-time hand angle)
local function ctrlRotOnGun(ctrl, gun)
    return copyR(kismet_math_library:InverseTransformRotation(gun:K2_GetComponentToWorld(), ctrl:K2_GetComponentRotation()))
end

local function setGloveRelative(glove, loc, rot)
    uevrUtils.set_component_relative_transform(glove, loc, rot, { X = 1, Y = 1, Z = 1 })
end

-- previewGun / previewProfile: mr_rack_hand_preview outside a reload (the hand on the closed slide, no rack)
local function attachRackHand(now, previewGun, previewProfile)
    rackHand = nil
    if configui.getValue("mr_rack_hand") == false or (previewGun == nil and cur.rack == nil) then return end
    local gun = previewGun or cur.gun
    local ok, err = pcall(function()
        local ctrl = controllers.getController(Handed.Left, true)
        if ctrl == nil then return end
        local rh = { ik = ikHandsMode(), ctrlRot = ctrlRotOnGun(ctrl, gun),
            preview = previewGun ~= nil, gun = gun, profile = previewProfile }
        if not rh.ik then
            local glove = hands ~= nil and hands.getHandComponent(Handed.Left) or nil
            if glove == nil or glove.K2_AttachTo == nil then return end
            local ctrlT = ctrl:K2_GetComponentToWorld()
            rh.gloveLoc = copyV(kismet_math_library:InverseTransformLocation(ctrlT, glove:K2_GetComponentLocation()))
            rh.gloveRot = copyR(kismet_math_library:InverseTransformRotation(ctrlT, glove:K2_GetComponentRotation()))
            rh.glove = glove
            rh.snap = { parent = glove.AttachParent, socket = glove.AttachSocketName and glove.AttachSocketName:to_string() or "",
                loc = copyV(glove.RelativeLocation), rot = copyR(glove.RelativeRotation) }
            glove:K2_AttachTo(gun, fname(""), 1, false) -- keep world: glides from where it is
            rh.glide = { t0 = now, dur = handGlideTime(), loc = copyV(glove.RelativeLocation), rot = copyR(glove.RelativeRotation) }
        end
        rackHand = rh
    end)
    if not ok then log("rack hand attach failed: " .. tostring(err)) end
end

-- glide progress (cubic ease-out) of g, or nil once done
local function glideEase(g, now)
    if g == nil or g.dur <= 0 then return nil end
    local a = math.min(1.0, (now - g.t0) / g.dur)
    if a >= 1.0 then return nil end
    return 1 - (1 - a) ^ 3
end

-- every frame (any state): follow the slide, or glide home after the release
local function tickRackHand(now)
    local rh = rackHand
    if rh == nil then return end
    if rh.returning then
        local e = glideEase(rh.glide, now)
        if e == nil then
            setGloveRelative(rh.glove, rh.snap.loc, rh.snap.rot)
            rackHand = nil
            return
        end
        local g = rh.glide
        setGloveRelative(rh.glove, addV(g.loc, mulV(subV(rh.snap.loc, g.loc), e)),
            kismet_math_library:RLerp(uevrUtils.rotator(g.rot.Pitch, g.rot.Yaw, g.rot.Roll), uevrUtils.rotator(rh.snap.rot.Pitch, rh.snap.rot.Yaw, rh.snap.rot.Roll), e, true))
        return
    end
    if rh.preview then
        -- as if grabbed this frame: the hand angle follows the controller
        if not exists(rh.gun) then return end
        local ctrl = controllers.getController(Handed.Left, true)
        if ctrl ~= nil then rh.ctrlRot = ctrlRotOnGun(ctrl, rh.gun) end
    elseif cur.rack == nil or cur.gun == nil then
        return
    end
    local loc, rot = rackHandTarget(rh)
    if rh.ik then
        rh.attached = true
        pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Left, rh.gun, "", 0, loc, rot) end)
        return
    end
    local e = glideEase(rh.glide, now)
    if e ~= nil then
        local g = rh.glide
        setGloveRelative(rh.glove, addV(g.loc, mulV(subV(loc, g.loc), e)),
            kismet_math_library:RLerp(uevrUtils.rotator(g.rot.Pitch, g.rot.Yaw, g.rot.Roll), uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll), e, true))
    else
        rh.glide = nil
        setGloveRelative(rh.glove, loc, rot)
    end
end

-- slide let go (or the reload ended): the hand goes back to the controller
releaseRackHand = function(now)
    local rh = rackHand
    if rh == nil or rh.returning then return end
    if rh.ik then
        rackHand = nil
        if rh.attached then pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left) end) end
        return
    end
    local ok = pcall(function()
        if rh.snap.parent ~= nil then
            rh.glove:K2_AttachTo(rh.snap.parent, fname(rh.snap.socket), 1, false) -- keep world, then glide home
        else
            rh.glove:DetachFromParent(false, false)
            controllers.attachComponentToController(Handed.Left, rh.glove)
        end
        rh.glide = { t0 = now, dur = handGlideTime(), loc = copyV(rh.glove.RelativeLocation), rot = copyR(rh.glove.RelativeRotation) }
        rh.returning = true
    end)
    if not ok then rackHand = nil end
end

-- mr_rack_hand_preview: outside a reload the left hand sits on the closed slide in the rack pose, so
-- mr_rack_hand_loc / _rot can be tuned without reloading. Let go when unticked, on a weapon or hands-mode change,
-- in a cutscene / menu, or when a reload starts (its own rack attaches the hand again).
local function updateRackPreview(now, gun, profile)
    local rh = rackHand
    local want = configui.getValue("mr_rack_hand_preview") == true and configui.getValue("mr_rack_hand") ~= false
        and state == S_IDLE and gun ~= nil and profile ~= nil
    if rh ~= nil and rh.preview and not rh.returning then
        if want and rh.gun == gun and rh.ik == ikHandsMode() then return end
        releaseRackHand(now)
        -- a reload that just started has no hand pose of its own yet (that comes with the clip grab)
        if state == S_IDLE or state == S_AWAIT_MAG then setHandPose(false) end
        if state == S_IDLE then suspendAccessories(false) end
        return
    end
    if want and rh == nil then
        attachRackHand(now, gun, profile)
        if rackHand ~= nil then
            setHandPose(true)
            suspendAccessories(true) -- no proximity grips (the Colt's "Left Hand") on the pinned hand
        end
    end
end

local SPRING_S = 0.05
local function updateRack(now)
    local rk = cur.rack
    if rk == nil then return end
    local travel = cfgNum("mr_slide_travel", 4.4)
    local hand = controllers.getControllerLocation(Handed.Left)

    if rk.spring ~= nil and state ~= S_RACK then -- slide returning by itself
        local a = math.min(1.0, (now - rk.spring.start) / SPRING_S)
        rk.pull = rk.spring.from + (rk.spring.to - rk.spring.from) * a * a
        setSlidePull(rk.pull)
        if a >= 1.0 then
            local closed = rk.spring.to == 0 and rk.spring.armed
            rk.spring = nil
            if closed then
                haptic(0.05, 0.9)
                log("slide racked")
                startFinish()
            end
        end
        return
    end

    local grabWorld = gunPoint(cur.gun, rackPointLocal(rk.pull))
    local wasNear = nearSlide
    nearSlide = hand ~= nil and lenV(subV(hand, grabWorld)) <= cfgNum("mr_rack_radius", 9.0)
    if nearSlide and not wasNear and not rk.grabbed then haptic(0.02, 0.25) end

    if state == S_AWAIT_RACK then
        if gripPressed and nearSlide and hand ~= nil and rk.ready then
            rk.grabbed, rk.armed = true, false
            rk.handStart = copyV(hand)
            rk.pullStart = rk.pull
            setHandPose(true)
            attachRackHand(now)
            enter(S_RACK)
            haptic(0.02, 0.4)
        end
        return
    end

    -- S_RACK: the slide follows the hand along its axis
    if hand ~= nil then
        local axis = gunDir(cur.gun, cur.profile.slideAxis)
        local d = dotV(subV(hand, rk.handStart), axis)
        rk.pull = math.max(rk.lockBack, math.min(travel, rk.pullStart + d))
        setSlidePull(rk.pull)
        if not rk.armed and rk.pull >= travel * cfgNum("mr_rack_done", 0.85) then
            rk.armed = true
            haptic(0.03, 0.6)
        end
    end
    if gripReleased or not gripDown then
        rk.grabbed = false
        setHandPose(false)
        releaseRackHand(now)
        -- let go: pulled far enough = it snaps home and counts; otherwise it returns to where it was held
        rk.spring = { start = now, from = rk.pull, to = rk.armed and 0 or rk.lockBack, armed = rk.armed }
        enter(S_AWAIT_RACK)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Debug: rack grab area (mr_debug_rack). Shown while a supported gun is held, also outside a reload (tuning without
-- ammo): a sphere of mr_rack_radius at the grab point (the zone updateRack tests) and a dot at the left controller
-- point it measures from (not the visible hand). With that point in reach the sphere shrinks to a dot (gun visible).
-- Spheres are components on the pawn, as physical_melee.lua's contact spheres.
-- ---------------------------------------------------------------------------------------------
local DEBUG_SPHERE_MESH = "StaticMesh /Engine/BasicShapes/Sphere.Sphere" -- 100 cm diameter
local DEBUG_SPHERE_MAT = "Material /Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"
local DEBUG_SMC_CLASS = "Class /Script/Engine.StaticMeshComponent"
local DEBUG_DOT_CM, DEBUG_HAND_DOT_CM = 2.0, 1.2 -- diameters
local debugSpheres = {} -- [1] grab area, [2] hand point
local rackDebugGun, rackDebugProfile = nil, nil -- set by tickBody while a supported gun is usable

local function hideRackDebug()
    for _, comp in pairs(debugSpheres) do
        pcall(function() if exists(comp) then comp:SetHiddenInGame(true, false) end end)
    end
end

local function getDebugSphere(index)
    local comp = debugSpheres[index]
    if comp ~= nil and not exists(comp) then comp = nil debugSpheres[index] = nil end
    if comp ~= nil then return comp end
    local pawn = uevr.api:get_local_pawn(0)
    local smcClass = uevr.api:find_uobject(DEBUG_SMC_CLASS)
    if pawn == nil or smcClass == nil then return nil end
    local identityT = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, created = pcall(function() return pawn:AddComponentByClass(smcClass, true, identityT, false) end)
    if not ok or created == nil or created == false then return nil end
    comp = created
    pcall(function() comp:SetMobility(2) end)
    local mesh = uevr.api:find_uobject(DEBUG_SPHERE_MESH)
    if mesh ~= nil then pcall(function() comp:SetStaticMesh(mesh) end) end
    local mat = uevr.api:find_uobject(DEBUG_SPHERE_MAT)
    if mat ~= nil then pcall(function() comp:SetMaterial(0, mat) end) end
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    debugSpheres[index] = comp
    return comp
end

local function placeDebugSphere(index, loc, diameterCm)
    local comp = getDebugSphere(index)
    if comp == nil then return end
    local s = diameterCm / 100.0
    pcall(function()
        comp:SetHiddenInGame(false, false)
        comp:K2_SetWorldLocation(vec(loc.X, loc.Y, loc.Z), false, reusable_hit_result, false)
        comp:SetWorldScale3D(vec(s, s, s))
    end)
end

local function updateRackDebug()
    local gun, profile = rackDebugGun, rackDebugProfile
    if configui.getValue("mr_debug_rack") ~= true or gun == nil or profile == nil or not exists(gun) then
        hideRackDebug()
        return
    end
    -- during a rack the grab point moves with the slide (held back / pulled), as updateRack tests it
    local pull = 0
    if cur.rack ~= nil and cur.gun == gun and (state == S_AWAIT_RACK or state == S_RACK) then pull = cur.rack.pull end
    local x, y, z = cfgVec("mr_rack_point", { 0.0, -3.0, 8.0 })
    local grabWorld = gunPoint(gun, addV({ X = x, Y = y, Z = z }, mulV(profile.slideAxis, pull)))
    local radius = cfgNum("mr_rack_radius", 9.0)
    local hand = controllers.getControllerLocation(Handed.Left)
    local inReach = hand ~= nil and lenV(subV(hand, grabWorld)) <= radius
    placeDebugSphere(1, grabWorld, inReach and DEBUG_DOT_CM or radius * 2)
    if hand ~= nil then placeDebugSphere(2, hand, DEBUG_HAND_DOT_CM)
    elseif debugSpheres[2] ~= nil then pcall(function() if exists(debugSpheres[2]) then debugSpheres[2]:SetHiddenInGame(true, false) end end) end
end

-- ---------------------------------------------------------------------------------------------
-- Input: the left grip that grabs a clip / the slide is kept from the game (and two-handing) until released
-- Priority 14: before the interaction pointer (12) and hands_animation (10), like the pointer's grab.
-- ---------------------------------------------------------------------------------------------
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state_)
    if user_index ~= 0 or state_ == nil then return end
    local down = uevrUtils.isButtonPressed(state_, BTN_LB)
    if down and not gripDown then
        gripPressed = true
        if (state == S_AWAIT_MAG and nearPouch) or (state == S_AWAIT_RACK and nearSlide) then
            swallowGrip = true
            -- lock the hand now so hands_animation does not start its grip curl before the grab pose (next tick)
            if handsAnimation ~= nil then pcall(function() handsAnimation.setInputLocked(Handed.Left, true) end) pressLocked = true end
        end
    elseif not down and gripDown then
        gripReleased = true
    end
    gripDown = down
    if swallowGrip or state == S_HOLD or state == S_INSERT or state == S_RACK then
        state_.Gamepad.wButtons = state_.Gamepad.wButtons & ~BTN_LB
        if not down then swallowGrip = false end
    end
end, 14)

-- ---------------------------------------------------------------------------------------------
-- Tick (once per frame, post-stereo: controller poses of this frame)
-- ---------------------------------------------------------------------------------------------
local lastTick = nil
local lastPawn = nil

local function tickBody(now, dt, pressed, released)
    local pawn = uevr.api:get_local_pawn(0)
    rackDebugGun, rackDebugProfile = nil, nil
    tickParts(now)
    updateFallers(dt, pawn)
    checkAmmoLog(now)

    if pawn ~= lastPawn then
        -- save load / respawn: a new pawn without a level change - the old objects may be gone, touch nothing
        if lastPawn ~= nil and state ~= S_IDLE then
            log("pawn changed - forgetting the reload")
            cur.hiddenBones = {}
            for _, p in ipairs({ cur.held, cur.seated, cur.slide }) do if p ~= nil and not exists(p.comp) then p.comp = nil end end
            cleanup(false, "pawn changed")
        end
        debugSpheres = {} -- they belong to the old pawn
        if rackHand ~= nil and rackHand.preview then rackHand = nil setHandPose(false) suspendAccessories(false) end
        lastPawn = pawn
    end
    if pawn == nil then destroyPouch() return end

    local equipment, gun, profile = nil, nil, nil
    pcall(function() equipment = pawn.CurrentEquipment end)
    if equipment ~= nil then
        pcall(function()
            local root = equipment.RootComponent
            if root ~= nil and (root.SkeletalMesh ~= nil or root.SkinnedAsset ~= nil) then gun = root end
        end)
        if gun ~= nil then profile = profileFor(gun) end
    end
    -- the panel shows the held weapon's settings (configui values exist once the panel is built)
    if profile ~= nil and profile ~= shownProfile and configui.getValue("mr_enabled") ~= nil then loadProfileToUI(profile) end
    saveParamsIfDirty(now)

    local enabled = configui.getValue("mr_enabled") ~= false
    local reason = blockedReason()

    -- a reload in progress
    if state ~= S_IDLE then
        if equipment ~= cur.equipment or gun ~= cur.gun or not exists(cur.gun) then
            cleanup(false, "weapon changed")
        elseif reason == "cutscene" or reason == "video" or not enabled then
            cleanup(true, reason or "disabled")
        elseif state ~= S_FINISH then
            local pm = montageOf(cur.pawnAnim)
            if pm == nil or addr(pm) ~= addr(cur.pawnMontage) then
                cleanup(false, "the game ended its reload")
            elseif cur.gunMontage == nil and cur.gunAnim ~= nil then
                -- the gun's reload montage started a tick after the pawn's: hold it too
                local gm = montageOf(cur.gunAnim)
                if isReloadMontage(gm) then
                    pcall(function() cur.gunAnim:Montage_Pause(gm) end)
                    cur.gunMontage = gm
                    log("gun montage caught late: " .. tostring(montageName(gm)))
                end
            end
        end
    end

    if not enabled or profile == nil or reason ~= nil then
        updateRackPreview(now, nil, nil)
        destroyPouch()
        nearPouch, nearSlide = false, false
        if state == S_IDLE then status(not enabled and "off" or (profile == nil and "no supported gun" or ("paused (" .. reason .. ")"))) end
        return
    end

    rackDebugGun, rackDebugProfile = gun, profile

    if now >= nextSparePoll then
        nextSparePoll = now + 0.5
        pcall(function() spareAmmo = equipment:GetAmmoInInventory() end)
    end

    -- the cube in the left hand (Genesis): no free hand - the game's reload plays as usual, no preview either
    local cubeHeld = _G.hrCubeAim ~= nil and _G.hrCubeAim() ~= nil
    updateRackPreview(now, not cubeHeld and gun or nil, not cubeHeld and profile or nil)
    if state == S_IDLE and not cubeHeld then tryIntercept(pawn, equipment, gun, profile) end

    local showPouch = spareAmmo > 0 and (state == S_IDLE or state == S_AWAIT_MAG)
    updatePouch(gun, profile, showPouch)

    if state == S_IDLE then
        status(string.format("%s ready (%d spare)", profile.label, spareAmmo))
    elseif state == S_AWAIT_MAG then
        status("take a clip from the left hip (left grip)")
        if pressed and nearPouch then
            if not grabFromPouch() then swallowGrip = false end
        end
    elseif state == S_HOLD then
        status("push the clip into the gun")
        if not updateHeld() then
            enter(S_AWAIT_MAG)
        elseif released or not gripDown then
            dropHeld(pawn)
            setHandPose(false)
            enter(S_AWAIT_MAG)
        elseif wellDistance() <= cfgNum("mr_insert_radius", 7.0) then
            startInsert()
        end
    elseif state == S_INSERT then
        if updateInsert() then
            haptic(0.04, 0.8)
            log("clip seated")
            if cur.wasEmpty and configui.getValue("mr_rack") ~= false then startAwaitRack() else startFinish() end
        end
    elseif state == S_AWAIT_RACK or state == S_RACK then
        gripPressed = pressed -- updateRack reads the edges
        gripReleased = released
        status(state == S_RACK and "pull the slide back and let go" or "rack the slide (left grip on the slide)")
        updateRack(now)
        gripPressed, gripReleased = false, false
    elseif state == S_FINISH then
        status("reloading...")
        if finishDone() then endFinish(false)
        elseif now - cur.finishStart > FINISH_TIMEOUT_S then endFinish(true) end
    end
end

local function tick()
    local now = os.clock()
    local dt = lastTick ~= nil and math.min(0.1, now - lastTick) or 0.016
    lastTick = now
    local pressed, released, locked = gripPressed, gripReleased, pressLocked
    gripPressed, gripReleased, pressLocked = false, false, false
    local ok, err = pcall(tickBody, now, dt, pressed, released)
    local okHand, errHand = pcall(tickRackHand, now) -- after the body: the slide's pull of this frame
    if not okHand then log("rack hand: " .. tostring(errHand)) rackHand = nil end
    local okDebug, errDebug = pcall(updateRackDebug) -- after the body: the slide's pull of this frame
    if not okDebug then log("rack debug: " .. tostring(errDebug)) end
    -- a press locked the hand for a grab that did not start: give the hand its input back
    if locked and not poseActive and handsAnimation ~= nil then
        pcall(function() handsAnimation.setInputLocked(Handed.Left, false) end)
    end
    if not ok then log(string.format("tick error (state %s): %s", state, tostring(err))) end
end

local ranThisTick = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisTick = false end)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if ranThisTick or not vr.is_hmd_active() then return end
    ranThisTick = true
    local ok, err = pcall(tick)
    if not ok then log("tick: " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    -- everything belonged to the old world: forget without touching it
    forgetParts()
    fallers = {}
    pouch, pouchKey = nil, nil
    cur.held, cur.seated, cur.slide, cur.hiddenBones = nil, nil, nil, {}
    cur.pawnMontage, cur.gunMontage, cur.pawnAnim, cur.gunAnim = nil, nil, nil, nil
    cur.equipment, cur.gun, cur.profile, cur.pawn, cur.insert, cur.rack, cur.grabGlide = nil, nil, nil, nil, nil, nil, nil
    lastPawn, swallowGrip, nearPouch, nearSlide = nil, false, false, false
    rackHand = nil
    debugSpheres, rackDebugGun, rackDebugProfile = {}, nil, nil
    setHandPose(false)
    suspendAccessories(false)
    state = S_IDLE
end)

print("[manual_reload] loaded")
