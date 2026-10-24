-- Physical melee for Hellraiser (ported from the Outer Worlds 2 profile's contact-mode physical melee).
--
-- While the right hand holds an attachment flagged "Melee" in Attachment Configuration
-- (attachments_parameters.json "melee": true; weaponhook.lua pre-sets it for CoreMeleeWeapon equipment), a
-- physical swing that brings the weapon into an enemy is turned into a short tap of the game's attack button,
-- and the player's melee montage is fast-forwarded through GlobalAnimRateScale on the body mesh (Pawn.Mesh,
-- ABP_AdvancedLocomotionSystem_C) and the weapon mesh so the game's swing resolves close to the physical one.
--
-- HOW THE GAME DECIDES A HIT (live trace 2026-10-07, sawblade): RT activates the weapon's ability
-- (GA_Sawblade_C -> GA_WeaponFire_C, ends with CoreMeleeWeapon.OnAbilityEnd ~12 ticks later). At the start of
-- the swing a Blueprint targeting object, DoTargeting_Fanout_C, fires ~165 Kismet SphereTraceSingle (r=5,
-- channel 7) in ONE tick, all starting at the camera and fanning out up to ~2.3 m around camera forward. The
-- COMP_MeleeTracerSphere components are not used by player swings. So the physical weapon position plays no
-- part in the game's own check - the camera direction does.
-- Contact mode therefore (a) fires the attack when the moving VR weapon ENTERS an enemy capsule (look-ahead
-- pm_lead) and (b) sends that enemy's position to HellraiserAimFix.dll (custom event "HellraiserMeleeTarget"),
-- which rotates the targeting fan of that swing toward it - the hit lands on what the weapon touched, even if
-- you are not looking straight at it. Button (RT) attacks keep the game's camera fan.
--
-- Contact geometry: COMP_MeleeTracerSphere components on the held weapon actor if any (none on the sawblade),
-- otherwise points along a mesh-local axis of the visible weapon mesh (pm_axis / pm_reach / pm_reach_start -
-- tune with the debug spheres). Enemies: Class /Script/Project.EnemyCharacter.
--
-- Swing detection / peak mode / RT injection timing are unchanged from OW2 (see that profile's notes).

local uevrUtils   = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local attachments = require('libs/attachments')
local configui    = require('libs/configui')

local vr = uevr.params.vr

local TRIGGER_MAX_HOLD   = 0.25  -- s: hard cap on the injected button hold (a long hold can become a heavy attack)
local RATE_MAX_SECONDS   = 1.0   -- s: unconditional restore deadline for the anim rate
local RATE_ARM_SECONDS   = 0.35  -- s: give up waiting for a montage to appear after the tap

local ENEMY_CLASS        = "Class /Script/Project.EnemyCharacter"
local CORPSE_CLASS       = "Class /Script/Project.EnemyCorpse"   -- BP_Enemy_Corpse_C (dead bodies)
-- Breakables (2026-10-08, MCP): crates / vases / buckets / chairs (BPD_* geometry collections, BP_Destructable_*) carry
-- Comp_Destructable_C -> Comp_DamageableBP_C -> C++ Comp_Damageable (IsDestructed()); explosive barrels Comp_Damageable.
local BREAKABLE_COMPONENT_CLASS = "Class /Script/Project.Comp_Damageable"
local CORPSE_BONE_RADIUS = 15.0                                   -- cm per bone sphere
local CORPSE_BONES = { "pelvis", "spine_01", "spine_03", "neck_01", "head",
                       "upperarm_l", "lowerarm_l", "hand_l", "upperarm_r", "lowerarm_r", "hand_r",
                       "thigh_l", "calf_l", "foot_l", "thigh_r", "calf_r", "foot_r" }
local corpseBoneFNames = {}
local TRACER_CLASS       = "Class /Script/Project.COMP_MeleeTracerSphere"
local ENEMY_REFRESH_TICKS = 10
local AXIS_SAMPLES       = 6     -- fallback points along the weapon axis
local CONTACT_REARM_SECONDS = 0.12

-- attack button choices (combo index -> injector); raw XInput bitmasks (no lib defines the constants)
local BUTTONS = {
    { label = "Right trigger",     trigger = "right" },
    { label = "Right bumper",      button = 0x0200 }, -- XINPUT_GAMEPAD_RIGHT_SHOULDER
    { label = "X",                 button = 0x4000 }, -- XINPUT_GAMEPAD_X
    { label = "B",                 button = 0x2000 }, -- XINPUT_GAMEPAD_B
    { label = "Right stick click", button = 0x0080 }, -- XINPUT_GAMEPAD_RIGHT_THUMB
}
local buttonLabels = {}
for i, b in ipairs(BUTTONS) do buttonLabels[i] = b.label end

-- ---------------------------------------------------------------------------------------------
-- Config UI
-- ---------------------------------------------------------------------------------------------
_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 3, label = "Physical Melee", layout = {
            { widgetType = "checkbox",     id = "pm_enabled",       label = "Enable physical melee (swing = attack)", initialValue = true },
            { widgetType = "combo",        id = "pm_button",        label = "Game attack button to tap", initialValue = 1, selections = buttonLabels },
            { widgetType = "slider_float", id = "pm_cooldown",      label = "Cooldown between swings (s)", initialValue = 0.35, range = {0.1, 1.5} },
            { widgetType = "slider_float", id = "pm_anim_rate",     label = "Melee anim rate scale", initialValue = 4.0, range = {1.0, 30.0} },
            { widgetType = "slider_int",   id = "pm_trigger_polls", label = "Button tap length (xinput polls)", initialValue = 3, range = {1, 6} },
            { widgetType = "checkbox",     id = "pm_log",           label = "Log to console", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", label = "Contact mode: the attack fires when the moving weapon enters an enemy" },
            { widgetType = "checkbox",     id = "pm_contact_mode",  label = "Contact mode (off = fire on swing peak)", initialValue = true },
            { widgetType = "slider_float", id = "pm_contact_speed", label = "Contact: min weapon speed (cm/s)", initialValue = 200.0, range = {0.0, 600.0} },
            { widgetType = "slider_float", id = "pm_contact_refire", label = "Contact: re-fire interval while still inside (s)", initialValue = 0.6, range = {0.2, 2.0} },
            { widgetType = "slider_float", id = "pm_hit_buffer",    label = "Contact: hit forgiveness (cm)", initialValue = 8.0, range = {0.0, 80.0} },
            { widgetType = "slider_float", id = "pm_lead",          label = "Contact: look-ahead (s)", initialValue = 0.05, range = {0.0, 0.2} },
            { widgetType = "slider_float", id = "pm_window_rate",   label = "Anim rate while the damage window is open", initialValue = 2.0, range = {1.0, 30.0} },
            { widgetType = "slider_float", id = "pm_window_time",   label = "Damage window hold at that rate (s)", initialValue = 0.3, range = {0.0, 0.6} },
            { widgetType = "slider_float", id = "pm_reach",         label = "Weapon contact length (cm)", initialValue = 45.0, range = {10.0, 150.0} },
            { widgetType = "combo",        id = "pm_axis",          label = "Weapon contact axis (mesh-local, check with debug spheres)", initialValue = 3, selections = {"+X", "-X", "+Y", "-Y", "+Z", "-Z"} },
            { widgetType = "slider_float", id = "pm_reach_start",   label = "Contact starts this far along the axis (cm, skips the handle)", initialValue = 0.0, range = {-50.0, 100.0} },
            { widgetType = "slider_float", id = "pm_enemy_range",   label = "Contact: enemy scan range (cm)", initialValue = 400.0, range = {150.0, 1500.0} },
            { widgetType = "checkbox",     id = "pm_hit_corpses",   label = "Contact: also hit dead bodies", initialValue = true },
            { widgetType = "checkbox",     id = "pm_hit_breakables", label = "Contact: also hit breakables (crates, vases, ...)", initialValue = true },
            { widgetType = "checkbox",     id = "pm_aim_touch_point", label = "Contact: game hit aims at the touched spot (off = enemy chest)", initialValue = true },
            { widgetType = "slider_float", id = "pm_fan_spread",    label = "Contact: game hit width around that spot (0 = one line, 1 = game's full fan)", initialValue = 0.35, range = {0.0, 1.0} },
            { widgetType = "checkbox",     id = "pm_fan_from_weapon", label = "Contact: game hit starts at the weapon, not your eyes (needs touched-spot aim)", initialValue = true },
            { widgetType = "checkbox",     id = "pm_swing_items",   label = "Swing to punch (unarmed) / use the bear trap (peak mode)", initialValue = true },
            { widgetType = "checkbox",     id = "pm_no_root_motion", label = "Melee / throw animations do not move the player (root motion off)", initialValue = true },
            { widgetType = "checkbox",     id = "pm_debug_capsule", label = "Debug: show contact spheres (bigger while touching)", initialValue = false },
            { widgetType = "spacing" },
            { widgetType = "text", label = "Peak mode" },
            { widgetType = "slider_float", id = "pm_min_speed",     label = "Peak: min swing speed (cm/s)", initialValue = 220.0, range = {50.0, 600.0} },
            { widgetType = "checkbox",     id = "pm_accept_stab",   label = "Peak: also accept forward stab", initialValue = true },
            { widgetType = "spacing" },
            { widgetType = "text", id = "pm_weapon_label",  label = "Weapon: none" },
            { widgetType = "text", id = "pm_swing_label",   label = "Last swing: -" },
            { widgetType = "text", id = "pm_rate_label",    label = "Anim rate: 1.0" },
            { widgetType = "text", id = "pm_contact_label", label = "Contact: -" },
            { widgetType = "text", id = "pm_timing_label",  label = "Timing: -" },
}})

local function cfgNum(id, default)
    local v = configui.getValue(id)
    if type(v) ~= "number" then return default end
    return v
end

local function log(text)
    if configui.getValue("pm_log") == true then
        print("[physical_melee] " .. tostring(text))
    end
end

local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

-- ---------------------------------------------------------------------------------------------
-- Melee attachment tracking
-- ---------------------------------------------------------------------------------------------
local meleeHeld      = false
local weaponMesh     = nil
local currentWeaponID = nil

local function updateMeleeState()
    local mesh = attachments.getCurrentGrippedAttachment(Handed.Right)
    local held = alive(mesh) and attachments.isActiveAttachmentMelee(Handed.Right) == true
    weaponMesh = held and mesh or nil
    if held ~= meleeHeld then
        meleeHeld = held
        local id = held and attachments.getActiveAttachmentID(Handed.Right) or nil
        currentWeaponID = (id ~= nil and id ~= "") and id or nil
        configui.setLabel("pm_weapon_label", held and ("Weapon: " .. tostring(currentWeaponID or "?") .. " (melee)") or "Weapon: not melee")
        log(held and ("melee weapon held: " .. tostring(currentWeaponID)) or "melee weapon released")
    end
    return held
end

-- ---------------------------------------------------------------------------------------------
-- Anim rate control
-- ---------------------------------------------------------------------------------------------
local rateActive     = false
local rateSeenMontage = false
local rateStartedAt  = 0
local rateValue      = 1.0
local rateMontageAt  = 0
local rateApplied    = nil

local function getArmsMesh()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return nil end
    local ok, mesh = pcall(function() return pawn.Mesh end)
    if ok and alive(mesh) then return mesh end
    return nil
end

local function setRates(rate)
    rateApplied = rate
    pcall(function()
        local arms = getArmsMesh()
        if arms ~= nil and arms.GlobalAnimRateScale ~= rate then arms.GlobalAnimRateScale = rate end
        if alive(weaponMesh) and weaponMesh.GlobalAnimRateScale ~= nil and weaponMesh.GlobalAnimRateScale ~= rate then weaponMesh.GlobalAnimRateScale = rate end
    end)
end

local function restoreRate(reason)
    if not rateActive then return end
    rateActive = false
    setRates(1.0)
    rateApplied = nil
    configui.setLabel("pm_rate_label", "Anim rate: 1.0")
    log("anim rate restored (" .. tostring(reason) .. ")")
end

local function currentTargetRate(now)
    if not rateSeenMontage then return rateValue end
    local holdTime = cfgNum("pm_window_time", 0.3)
    if holdTime > 0 and (now - rateMontageAt) < holdTime then
        local r = cfgNum("pm_window_rate", 2.0)
        if r < 1.0 then r = 1.0 end
        if r > rateValue then r = rateValue end
        return r
    end
    return rateValue
end

local function armsMontageName()
    local name = nil
    pcall(function()
        local arms = getArmsMesh()
        local ai = arms and arms.AnimScriptInstance
        if ai == nil or ai.GetCurrentActiveMontage == nil then return end
        local m = ai:GetCurrentActiveMontage()
        if m ~= nil then name = uevrUtils.getShortName(m) end
    end)
    return name
end

local function startRate()
    rateValue = cfgNum("pm_anim_rate", 4.0)
    if rateValue <= 1.0 then return end
    rateActive = true
    rateSeenMontage = false
    rateStartedAt = os.clock()
    rateMontageAt = 0
    rateApplied = nil
    setRates(rateValue)
    configui.setLabel("pm_rate_label", string.format("Anim rate: %.1f", rateValue))
end

local function updateRate()
    if not rateActive then return end
    local now = os.clock()
    local elapsed = now - rateStartedAt
    if elapsed > RATE_MAX_SECONDS then restoreRate("deadline") return end
    local name = armsMontageName()
    if name ~= nil then
        if not rateSeenMontage then
            rateSeenMontage = true
            rateMontageAt = now
            log(string.format("montage: %s (%.0f ms after tap)", name, elapsed * 1000))
        end
        local target = currentTargetRate(now)
        if rateApplied ~= target then
            setRates(target)
            configui.setLabel("pm_rate_label", string.format("Anim rate: %.1f", target))
        end
    elseif rateSeenMontage then
        configui.setLabel("pm_timing_label", string.format("Timing: tap->montage %.0f ms, montage %.0f ms",
            (rateMontageAt - rateStartedAt) * 1000, (now - rateMontageAt) * 1000))
        restoreRate("montage ended")
    elseif elapsed > RATE_ARM_SECONDS then
        restoreRate("no montage started")
    end
end

-- ---------------------------------------------------------------------------------------------
-- Button injection
-- ---------------------------------------------------------------------------------------------
local triggerPollsLeft = 0
local triggerDeadline  = 0

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    if triggerPollsLeft <= 0 then return end
    if os.clock() > triggerDeadline then
        triggerPollsLeft = 0
        return
    end
    local b = BUTTONS[configui.getValue("pm_button") or 1] or BUTTONS[1]
    if b.trigger == "right" then
        state.Gamepad.bRightTrigger = 255
    elseif b.button ~= nil then
        state.Gamepad.wButtons = state.Gamepad.wButtons | b.button
    end
    triggerPollsLeft = triggerPollsLeft - 1
end, 20) -- before hands_animation (10) so the trigger pose plays too, before two_handed (5) and remap (0)

local function fireAttack(kind, speed)
    triggerPollsLeft = math.floor(cfgNum("pm_trigger_polls", 3) + 0.5)
    if triggerPollsLeft < 1 then triggerPollsLeft = 1 end
    triggerDeadline = os.clock() + TRIGGER_MAX_HOLD
    startRate()
    if _G.hrStopCameraShakes ~= nil then pcall(_G.hrStopCameraShakes) end
    configui.setLabel("pm_swing_label", string.format("Last swing: %s %.0f cm/s", kind, speed))
    log(string.format("%s swing %.0f cm/s -> attack tap", kind, speed))
end

-- ---------------------------------------------------------------------------------------------
-- Weapon contact geometry
-- ---------------------------------------------------------------------------------------------
local tracerClass = nil
local tracers = {}          -- COMP_MeleeTracerSphere components of the held weapon actor
local tracerOwner = nil
local contactRadius = 8.0   -- radius used for the axis fallback / tracers without a readable radius

local function readTracerRadius(c)
    for _, prop in ipairs({ "SphereRadius", "Radius", "TraceRadius", "SweepRadius" }) do
        local ok, v = pcall(function() return c[prop] end)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return nil
end

local function refreshTracers()
    if not alive(weaponMesh) then tracers = {} tracerOwner = nil return end
    local owner = nil
    pcall(function() owner = weaponMesh:GetOwner() end)
    if owner == tracerOwner then return end
    tracerOwner = owner
    tracers = {}
    if owner == nil then return end
    if tracerClass == nil then tracerClass = uevrUtils.get_class(TRACER_CLASS) end
    pcall(function()
        local comps = owner.BlueprintCreatedComponents
        for i = 1, (comps and #comps or 0) do
            local c = comps[i]
            if c ~= nil and tracerClass ~= nil and c:is_a(tracerClass) then table.insert(tracers, c) end
        end
    end)
    if #tracers == 0 then
        -- native (C++ constructor) components are not in BlueprintCreatedComponents: scan the weapon mesh tree
        local function scan(comp)
            pcall(function()
                if tracerClass ~= nil and comp:is_a(tracerClass) then table.insert(tracers, comp) end
                local ch = comp.AttachChildren
                for i = 1, (ch and #ch or 0) do scan(ch[i]) end
            end)
        end
        pcall(function() scan(owner.RootComponent) end)
    end
    log(string.format("weapon %s: %d melee tracer sphere(s)", tostring(owner and owner:get_full_name()), #tracers))
end

-- list of { X, Y, Z, r } contact spheres in world space
local function contactPoints()
    if not alive(weaponMesh) then return nil end
    local pts = {}
    for _, t in ipairs(tracers) do
        pcall(function()
            local loc = t:K2_GetComponentLocation()
            if loc ~= nil then pts[#pts + 1] = { X = loc.X, Y = loc.Y, Z = loc.Z, r = readTracerRadius(t) or contactRadius } end
        end)
    end
    if #pts > 0 then return pts end
    -- no tracer spheres (player melee weapons have none - their hits come from a sphere-trace burst, see the
    -- header): points along a mesh-local axis chosen in the panel. Melee meshes are static (e.g. SM_Saw), and
    -- their blade axis differs per asset, so tune pm_axis / pm_reach / pm_reach_start with the debug spheres.
    local base, axis = nil, nil
    pcall(function()
        base = weaponMesh:K2_GetComponentLocation()
        local sel = configui.getValue("pm_axis") or 3
        local v
        if sel <= 2 then v = weaponMesh:GetForwardVector()
        elseif sel <= 4 then v = weaponMesh:GetRightVector()
        else v = weaponMesh:GetUpVector() end
        local sign = (sel % 2 == 0) and -1 or 1
        axis = { X = v.X * sign, Y = v.Y * sign, Z = v.Z * sign }
    end)
    if base == nil or axis == nil then return nil end
    local reach = cfgNum("pm_reach", 45.0)
    local first = cfgNum("pm_reach_start", 0.0)
    for i = 0, AXIS_SAMPLES - 1 do
        local t = first + reach * (i / (AXIS_SAMPLES - 1))
        pts[#pts + 1] = { X = base.X + axis.X * t, Y = base.Y + axis.Y * t, Z = base.Z + axis.Z * t, r = contactRadius }
    end
    return pts
end

-- ---------------------------------------------------------------------------------------------
-- Debug spheres
-- ---------------------------------------------------------------------------------------------
local SPHERE_MESH_PATH = "StaticMesh /Engine/BasicShapes/Sphere.Sphere"   -- 100 UU diameter
local SPHERE_MAT_PATH  = "Material /Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"
local SMC_CLASS_PATH   = "Class /Script/Engine.StaticMeshComponent"
local debugSpheres = {}
local debugTouching = false

local function hideDebugSpheres()
    for _, comp in ipairs(debugSpheres) do
        pcall(function() if alive(comp) then comp:SetHiddenInGame(true, false) end end)
    end
end

local function getDebugSphere(index)
    local comp = debugSpheres[index]
    if comp ~= nil and not alive(comp) then comp = nil debugSpheres[index] = nil end
    if comp ~= nil then return comp end
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then return nil end
    local smcClass = uevr.api:find_uobject(SMC_CLASS_PATH)
    if smcClass == nil then return nil end
    local identityT = { Rotation = {X=0,Y=0,Z=0,W=1}, Translation = {X=0,Y=0,Z=0}, Scale3D = {X=1,Y=1,Z=1} }
    local ok, created = pcall(function() return pawn:AddComponentByClass(smcClass, true, identityT, false) end)
    if not ok or created == nil or created == false then return nil end
    comp = created
    pcall(function() comp:SetMobility(2) end)
    local mesh = uevr.api:find_uobject(SPHERE_MESH_PATH)
    if mesh ~= nil then pcall(function() comp:SetStaticMesh(mesh) end) end
    local mat = uevr.api:find_uobject(SPHERE_MAT_PATH)
    if mat ~= nil then pcall(function() comp:SetMaterial(0, mat) end) end
    pcall(function() comp:SetCollisionEnabled(0) end)
    pcall(function() comp:SetCastShadow(false) end)
    pcall(function() comp:SetRenderInMainPass(true) end)
    debugSpheres[index] = comp
    return comp
end

local function updateDebugSpheres(pts)
    if configui.getValue("pm_debug_capsule") ~= true then
        if #debugSpheres > 0 then hideDebugSpheres() end
        return
    end
    if pts == nil then hideDebugSpheres() return end
    for i, pt in ipairs(pts) do
        local radius = pt.r + cfgNum("pm_hit_buffer", 8.0)
        if debugTouching then radius = radius * 2 end
        local scale = (radius * 2) / 100.0
        local comp = getDebugSphere(i)
        if comp ~= nil then
            pcall(function()
                comp:SetHiddenInGame(false, false)
                comp:K2_SetWorldLocation({ X = pt.X, Y = pt.Y, Z = pt.Z }, false, {}, false)
                comp:SetWorldScale3D({ X = scale, Y = scale, Z = scale })
            end)
        end
    end
    for i = #pts + 1, #debugSpheres do
        pcall(function() if alive(debugSpheres[i]) then debugSpheres[i]:SetHiddenInGame(true, false) end end)
    end
end

-- ---------------------------------------------------------------------------------------------
-- Enemy cache
-- ---------------------------------------------------------------------------------------------
local enemies = {}          -- { X, Y, Z, r, hh, actor }
local enemyRefreshTick = 0

local function isDead(actor)
    local dead = false
    pcall(function()
        if actor.IsDead ~= nil then dead = actor:IsDead() == true
        elseif actor.bIsDead ~= nil then dead = actor.bIsDead == true end
    end)
    return dead
end

-- Target scan (perf pass 2026-10-17). Called every ENEMY_REFRESH_TICKS ticks while a melee weapon is held. Before, every
-- call scanned the level three times (enemies, corpses, breakables), asked EVERY breakable in the level for its owner,
-- destruction state and location before the range check, and re-read 17 bone positions of every nearby corpse. Now:
--   * live enemies: scanned every call as before (they move; positions are also refreshed every tick);
--   * corpses: scanned every CORPSE_SCAN_S; bone points cached per corpse actor (corpses do not move - re-sampled only
--     if the actor's location changed);
--   * breakables: the level list (owner, location, bounds) is rebuilt every BREAKABLE_SCAN_S; in between, the range
--     check uses the cached location (pure Lua) and only breakables in range are asked whether they are destructed.
-- At most one of the two slow scans runs per call. Caches are cleared on level change (addresses get reused).
local CORPSE_SCAN_S = 0.5
local BREAKABLE_SCAN_S = 2.0
local liveTargets, corpseTargets, breakableTargets = {}, {}, {}
local corpseCache = {}     -- address -> { X, Y, Z, points }
local breakableList = {}   -- { owner, comp, X, Y, Z, ox, oy, oz, ex, ey, ez }
local nextCorpseScan, nextBreakableScan = 0, 0

local function addressOf(obj)
    local ok, a = pcall(function() return obj:get_address() end)
    return ok and a or nil
end

local function scanLive(pawn, ploc, range2)
    local list = uevrUtils.find_all_of(ENEMY_CLASS, false) or {}
    local out = {}
    for _, actor in ipairs(list) do
        if actor ~= pawn then
            local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
            if ok and loc ~= nil then
                local dx, dy, dz = loc.X - ploc.X, loc.Y - ploc.Y, loc.Z - ploc.Z
                if dx * dx + dy * dy + dz * dz <= range2 and not isDead(actor) then
                    local r, hh = 40.0, 90.0
                    pcall(function()
                        local cap = actor.CapsuleComponent
                        if cap ~= nil then
                            if type(cap.CapsuleRadius) == "number" and cap.CapsuleRadius > 0 then r = cap.CapsuleRadius end
                            if type(cap.CapsuleHalfHeight) == "number" and cap.CapsuleHalfHeight > 0 then hh = cap.CapsuleHalfHeight end
                        end
                    end)
                    out[#out + 1] = { X = loc.X, Y = loc.Y, Z = loc.Z, r = r, hh = hh, actor = actor }
                end
            end
        end
    end
    liveTargets = out
end

-- Corpses (2026-10-08): a killed enemy is replaced by a BP_Enemy_Corpse_C actor (C++ EnemyCorpse, not an
-- EnemyCharacter) lying on the floor - CorpseSkeletalMesh posed flat (not physics-simulated, collision on), about
-- 1.7 m from feet to head, and a COMP_FleshWounds component (corpses take hits / gore). A capsule cannot describe
-- a body lying down, so each corpse is a set of spheres on its skeleton bones. Toggle: pm_hit_corpses.
local function scanCorpses(ploc, range)
    local out = {}
    local seen = {}
    for _, actor in ipairs(uevrUtils.find_all_of(CORPSE_CLASS, false) or {}) do
        pcall(function()
            local loc = actor:K2_GetActorLocation()
            if loc == nil then return end
            local dx, dy, dz = loc.X - ploc.X, loc.Y - ploc.Y, loc.Z - ploc.Z
            -- the actor sits near the middle of the body; allow its 1.7 m length on top of the scan range
            local reach = range + 100
            if dx * dx + dy * dy + dz * dz > reach * reach then return end
            local key = addressOf(actor)
            local cached = key ~= nil and corpseCache[key] or nil
            if cached ~= nil and math.abs(cached.X - loc.X) + math.abs(cached.Y - loc.Y) + math.abs(cached.Z - loc.Z) > 5 then
                cached = nil -- moved (or a new corpse at a reused address): sample again
            end
            if cached == nil then
                local mesh = actor.CorpseSkeletalMesh
                if mesh == nil then return end
                local points = {}
                for _, bone in ipairs(CORPSE_BONES) do
                    local fname = corpseBoneFNames[bone]
                    if fname == nil then fname = uevrUtils.fname_from_string(bone) corpseBoneFNames[bone] = fname end
                    local p = mesh:GetSocketLocation(fname)
                    if p ~= nil and (p.X ~= 0 or p.Y ~= 0 or p.Z ~= 0) then
                        points[#points + 1] = { X = p.X, Y = p.Y, Z = p.Z }
                    end
                end
                if #points == 0 then return end
                cached = { X = loc.X, Y = loc.Y, Z = loc.Z, points = points }
                if key ~= nil then corpseCache[key] = cached end
            end
            if key ~= nil then seen[key] = true end
            out[#out + 1] = { X = loc.X, Y = loc.Y, Z = loc.Z, actor = actor, corpse = true, points = cached.points }
        end)
    end
    for key in pairs(corpseCache) do
        if not seen[key] then corpseCache[key] = nil end -- out of range or gone: drop (re-sampled if it comes back)
    end
    corpseTargets = out
end

-- Breakables (2026-10-08): actors owning a Comp_Damageable that is not destructed yet, as their colliding bounds
-- box (GetActorBounds; out structs filled in place). The level list is static until something breaks.
local function rebuildBreakables(pawn)
    local list = {}
    local seen = {}
    for _, comp in ipairs(uevrUtils.find_all_of(BREAKABLE_COMPONENT_CLASS, false) or {}) do
        pcall(function()
            local owner = comp:GetOwner()
            if owner == nil or owner == pawn then return end
            local key = addressOf(owner)
            if key == nil or seen[key] then return end
            seen[key] = true
            local loc = owner:K2_GetActorLocation()
            if loc == nil then return end
            local origin, extent = uevrUtils.vector(0, 0, 0), uevrUtils.vector(0, 0, 0)
            owner:GetActorBounds(true, origin, extent, false)
            if extent.X <= 0 and extent.Y <= 0 and extent.Z <= 0 then return end
            list[#list + 1] = { owner = owner, comp = comp, X = loc.X, Y = loc.Y, Z = loc.Z,
                ox = origin.X, oy = origin.Y, oz = origin.Z, ex = extent.X, ey = extent.Y, ez = extent.Z }
        end)
    end
    breakableList = list
end

local function filterBreakables(ploc, range2)
    local out = {}
    for _, b in ipairs(breakableList) do
        local dx, dy, dz = b.X - ploc.X, b.Y - ploc.Y, b.Z - ploc.Z
        if dx * dx + dy * dy + dz * dz <= range2 then
            local intact = false
            pcall(function()
                intact = not (b.comp.IsDestructed ~= nil and b.comp:IsDestructed() == true)
            end)
            if intact then
                out[#out + 1] = { X = b.ox, Y = b.oy, Z = b.oz, actor = b.owner, breakable = true, ex = b.ex, ey = b.ey, ez = b.ez }
            end
        end
    end
    breakableTargets = out
end

local function refreshEnemies()
    local pawn = uevr.api:get_local_pawn(0)
    if pawn == nil then enemies = {} return end
    local okp, ploc = pcall(function() return pawn:K2_GetActorLocation() end)
    if not okp or ploc == nil then enemies = {} return end
    local range = cfgNum("pm_enemy_range", 400.0)
    local range2 = range * range
    local now = os.clock()

    scanLive(pawn, ploc, range2)

    local slowScanDone = false
    if configui.getValue("pm_hit_breakables") ~= false then
        if now >= nextBreakableScan then
            nextBreakableScan = now + BREAKABLE_SCAN_S
            rebuildBreakables(pawn)
            slowScanDone = true
        end
        filterBreakables(ploc, range2)
    else
        breakableTargets = {}
    end
    if configui.getValue("pm_hit_corpses") ~= false then
        if now >= nextCorpseScan and not slowScanDone then
            nextCorpseScan = now + CORPSE_SCAN_S
            scanCorpses(ploc, range)
        end
    else
        corpseTargets = {}
    end

    local all = {}
    for _, e in ipairs(liveTargets) do all[#all + 1] = e end
    for _, e in ipairs(corpseTargets) do all[#all + 1] = e end
    for _, e in ipairs(breakableTargets) do all[#all + 1] = e end
    enemies = all
end

local function refreshEnemyPositions()
    for _, e in ipairs(enemies) do
        if not e.corpse and not e.breakable then -- corpses / breakables are static; refreshed by the scan
            pcall(function()
                if e.actor ~= nil then
                    local loc = e.actor:K2_GetActorLocation()
                    if loc ~= nil then e.X, e.Y, e.Z = loc.X, loc.Y, loc.Z end
                end
            end)
        end
    end
end

local handVelocity = { X = 0, Y = 0, Z = 0 }

local TOUCH_POINT_RADIUS = 0.6 -- share of the capsule radius the touched spot may lie off the capsule axis

-- true if the weapon point touches the enemy; a corpse also records which bone point was touched (e.hitPoint),
-- a live enemy the touched spot (e.touchPoint = the weapon point pulled into the capsule)
local function pointHitsEnemy(pt, e, buffer)
    if e.breakable then
        local pad = pt.r + buffer
        return math.abs(pt.X - e.X) <= e.ex + pad and math.abs(pt.Y - e.Y) <= e.ey + pad and math.abs(pt.Z - e.Z) <= e.ez + pad
    end
    if e.corpse then
        local r = CORPSE_BONE_RADIUS + pt.r + buffer
        local r2 = r * r
        for _, b in ipairs(e.points) do
            local dx, dy, dz = pt.X - b.X, pt.Y - b.Y, pt.Z - b.Z
            if dx * dx + dy * dy + dz * dz <= r2 then e.hitPoint = b return true end
        end
        return false
    end
    local dx, dy, dz = pt.X - e.X, pt.Y - e.Y, pt.Z - e.Z
    local r = e.r + pt.r + buffer
    local h2 = dx * dx + dy * dy
    if h2 > r * r then return false end
    if math.abs(dz) >= (e.hh + pt.r + buffer) then return false end
    -- the contact test is forgiving (weapon radius + buffer), so the point can lie outside the capsule; and the
    -- capsule is wider than the body, so the spot is kept within TOUCH_POINT_RADIUS of it horizontally - the narrowed
    -- fan (pm_fan_spread) would otherwise pass beside the mesh at the capsule edge. Height is kept as touched.
    local h = math.sqrt(h2)
    local maxH = e.r * TOUCH_POINT_RADIUS
    local k = h > maxH and maxH / h or 1.0
    e.touchPoint = { X = e.X + dx * k, Y = e.Y + dy * k, Z = e.Z + math.max(-e.hh, math.min(e.hh, dz)) }
    return true
end

local touchedEnemy = nil -- enemy entry the weapon touched on the last sample (target sent to the aim plugin)

local FROM_WEAPON_BACK = 20.0 -- cm back along the swing from the touching weapon point = where the hit rays start

-- Where the game's hit rays start when they come from the weapon (pm_fan_from_weapon): the touching weapon point,
-- stepped back along the swing so the rays begin before the body, not inside it. Live enemies only.
local function touchStart(pt, e)
    e.touchFrom = nil
    if e.corpse or e.breakable then return end
    local vx, vy, vz = handVelocity.X, handVelocity.Y, handVelocity.Z
    local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
    if speed < 1.0 then return end
    local k = FROM_WEAPON_BACK / speed
    e.touchFrom = { X = pt.X - vx * k, Y = pt.Y - vy * k, Z = pt.Z - vz * k }
end

local function weaponTouchesEnemy()
    local pts = contactPoints()
    local touching = false
    touchedEnemy = nil
    if pts ~= nil and #enemies > 0 then
        local buffer = cfgNum("pm_hit_buffer", 8.0)
        local lead = cfgNum("pm_lead", 0.05)
        local lx, ly, lz = handVelocity.X * lead, handVelocity.Y * lead, handVelocity.Z * lead
        for _, e in ipairs(enemies) do
            for _, pt in ipairs(pts) do
                local probe = { X = pt.X + lx, Y = pt.Y + ly, Z = pt.Z + lz, r = pt.r }
                if pointHitsEnemy(pt, e, buffer) or pointHitsEnemy(probe, e, buffer) then
                    touching = true
                    touchStart(pt, e)
                    break
                end
            end
            if touching then touchedEnemy = e break end
        end
    end
    debugTouching = touching
    updateDebugSpheres(pts)
    return touching
end

-- The game's melee hit check is a camera-centred targeting fan (see header). HellraiserAimFix.dll turns that
-- fan toward this point for the swing we are about to trigger: the spot on the enemy's capsule the weapon touched
-- (pm_aim_touch_point; off = the capsule's upper chest). The fan's rays hit whatever bone lies around that
-- direction, and the game picks one ray per enemy by bone priority - aiming at the chest spread the hits over the
-- whole upper body wherever the weapon was (plugin bone log 2026-10-23).
-- Corpses: the touched bone point itself (the fan then aims down at the body on the floor).
-- pm_fan_from_weapon (live enemies, touched-spot aim only): the rays also START at the weapon (e.touchFrom) instead
-- of the eyes, so an arm between the eyes and the touched spot no longer takes the hit.
local function sendMeleeTarget(e)
    if e == nil then return end
    pcall(function()
        local x, y, z = e.X, e.Y, e.Z + (e.hh or 90) * 0.3
        local fromWeapon = nil
        if e.touchPoint ~= nil and configui.getValue("pm_aim_touch_point") ~= false then
            x, y, z = e.touchPoint.X, e.touchPoint.Y, e.touchPoint.Z
            if configui.getValue("pm_fan_from_weapon") == true then fromWeapon = e.touchFrom end
        end
        if e.corpse and e.hitPoint ~= nil then x, y, z = e.hitPoint.X, e.hitPoint.Y, e.hitPoint.Z end
        if e.breakable then x, y, z = e.X, e.Y, e.Z end -- bounds centre
        -- 4th value: how wide the plugin keeps the fan around this point; 5-7: where the rays start (older plugin
        -- builds ignore the extra values)
        local data = string.format("%.1f,%.1f,%.1f,%.2f", x, y, z, cfgNum("pm_fan_spread", 0.35))
        if fromWeapon ~= nil then
            data = data .. string.format(",%.1f,%.1f,%.1f", fromWeapon.X, fromWeapon.Y, fromWeapon.Z)
        end
        uevr.api:dispatch_custom_event("HellraiserMeleeTarget", data)
    end)
end

local function haptic()
    pcall(function()
        vr.trigger_haptic_vibration(0, 0.12, 0.8, 1.0, vr.get_right_joystick_source())
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Swing detection
-- ---------------------------------------------------------------------------------------------
local prevHandPos, prevHeadPos, prevHeadYaw = nil, nil, nil
local prevSampleTime = nil
local peakSpeed, peakDir = 0, nil
local cooldownUntil = 0
local contactLabelTick = 0
local inContact       = false
local contactLostAt   = nil
local lastContactFire = 0

local function clearMotion()
    prevHandPos, prevHeadPos, prevHeadYaw = nil, nil, nil
    prevSampleTime = nil
    peakSpeed, peakDir = 0, nil
end

local function clearContact()
    inContact = false
    contactLostAt = nil
end

local function rotateInverseYaw(v, yawDeg)
    local r = -math.rad(yawDeg)
    local c, s = math.cos(r), math.sin(r)
    return { X = v.X * c - v.Y * s, Y = v.X * s + v.Y * c, Z = v.Z }
end

local function classify(dir)
    local ax, ay, az = math.abs(dir.X), math.abs(dir.Y), math.abs(dir.Z)
    if az >= ax and az >= ay then
        if dir.Z > 0 then return nil end
        return "down"
    elseif ay >= ax then
        return dir.Y < 0 and "left" or "right"
    else
        if dir.X < 0 then return nil end
        if configui.getValue("pm_accept_stab") == false then return nil end
        return "stab"
    end
end

local swingItemEquipped -- defined with the swing items below

local function contactStep(now, speed)
    local touching = weaponTouchesEnemy()
    local minSpeed = cfgNum("pm_contact_speed", 200.0)
    local fire = false
    if touching then
        if not inContact then
            local reArmed = contactLostAt == nil or (now - contactLostAt) >= CONTACT_REARM_SECONDS
            inContact = true
            contactLostAt = nil
            if reArmed and speed >= minSpeed then fire = true end
        else
            local refire = cfgNum("pm_contact_refire", 0.6)
            if speed >= minSpeed and (now - lastContactFire) >= refire then fire = true end
        end
    elseif inContact then
        inContact = false
        contactLostAt = now
    end

    if fire and now >= cooldownUntil then
        lastContactFire = now
        sendMeleeTarget(touchedEnemy) -- before the tap: the fan runs in the tick the attack starts
        fireAttack("contact", speed)
        haptic()
        cooldownUntil = now + cfgNum("pm_cooldown", 0.35)
        configui.setLabel("pm_contact_label", string.format("Contact: HIT %.0f cm/s (%d enemies in range)", speed, #enemies))
        return
    end

    contactLabelTick = contactLabelTick + 1
    if contactLabelTick % 15 == 0 then
        configui.setLabel("pm_contact_label", string.format("Contact: %s, %d enemies in range, %d tracer(s), weapon %.0f cm/s",
            touching and "touching" or "clear", #enemies, #tracers, speed))
    end
end

local function detect(forcePeak)
    local now = os.clock()
    local contactMode = not forcePeak and configui.getValue("pm_contact_mode") ~= false

    local hand = controllers.getController(1, true)
    local head = controllers.getHMDController()
    if not alive(hand) or not alive(head) then clearMotion() clearContact() return end

    local handPos = hand:K2_GetComponentLocation()
    local headPos = head:K2_GetComponentLocation()
    local headRot = head:K2_GetComponentRotation()
    if handPos == nil or headPos == nil or headRot == nil then clearMotion() clearContact() return end

    local hp = { X = handPos.X, Y = handPos.Y, Z = handPos.Z }
    local hd = { X = headPos.X, Y = headPos.Y, Z = headPos.Z }
    local yaw = headRot.Yaw

    if prevHandPos == nil or prevSampleTime == nil then
        prevHandPos, prevHeadPos, prevHeadYaw, prevSampleTime = hp, hd, yaw, now
        return
    end

    local dt = now - prevSampleTime
    prevSampleTime = now
    if dt <= 0.0005 then return end
    if dt > 0.1 then
        prevHandPos, prevHeadPos, prevHeadYaw = hp, hd, yaw
        peakSpeed, peakDir = 0, nil
        return
    end

    local dYaw = math.abs(yaw - prevHeadYaw)
    if dYaw > 180 then dYaw = 360 - dYaw end
    if dYaw > 45 then
        prevHandPos, prevHeadPos, prevHeadYaw = hp, hd, yaw
        peakSpeed, peakDir = 0, nil
        return
    end

    local dw = { X = (hp.X - prevHandPos.X) - (hd.X - prevHeadPos.X),
                 Y = (hp.Y - prevHandPos.Y) - (hd.Y - prevHeadPos.Y),
                 Z = (hp.Z - prevHandPos.Z) - (hd.Z - prevHeadPos.Z) }
    local dl = rotateInverseYaw(dw, yaw)
    local dist = math.sqrt(dl.X * dl.X + dl.Y * dl.Y + dl.Z * dl.Z)
    local speed = dist / dt
    prevHandPos, prevHeadPos, prevHeadYaw = hp, hd, yaw
    handVelocity.X, handVelocity.Y, handVelocity.Z = dw.X / dt, dw.Y / dt, dw.Z / dt

    if contactMode then
        contactStep(now, speed)
        return
    end
    if #debugSpheres > 0 then hideDebugSpheres() end

    if now < cooldownUntil then
        peakSpeed, peakDir = 0, nil
        return
    end
    local minSpeed = cfgNum("pm_min_speed", 220.0)
    if speed > minSpeed and speed > peakSpeed and dist > 0 then
        peakSpeed = speed
        peakDir = { X = dl.X / dist, Y = dl.Y / dist, Z = dl.Z / dist }
        return
    end
    if peakSpeed > 0 and peakDir ~= nil then
        local kind = classify(peakDir)
        local pk, pd = peakSpeed, peakDir
        peakSpeed, peakDir = 0, nil
        if kind ~= nil then
            fireAttack(kind, pk)
            cooldownUntil = now + cfgNum("pm_cooldown", 0.35)
        else
            log(string.format("ignored swing %.0f cm/s dir(%.2f %.2f %.2f)", pk, pd.X, pd.Y, pd.Z))
        end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Items without a melee attachment that are used with RT (2026-10-16, idea from another Hellraiser profile): unarmed
-- (BP_Unarmed_C - punch) and the bear trap. There is no weapon mesh to touch an enemy with, so these use peak mode: a
-- swing of the right hand taps the attack button, whatever pm_contact_mode says. Equipment class polled every 0.25 s.
-- ---------------------------------------------------------------------------------------------
local SWING_ITEM_PATTERNS = { "Unarmed", "BearTrap" }
local swingItem = { equipped = false, nextCheck = 0 }
swingItemEquipped = function()
    if configui.getValue("pm_swing_items") == false then return false end
    if _G.hrCutsceneActive == true or (_G.hrIsInMenu ~= nil and _G.hrIsInMenu()) then return false end
    local now = os.clock()
    if now >= swingItem.nextCheck then
        swingItem.nextCheck = now + 0.25
        local equipped = false
        pcall(function()
            local equipment = uevr.api:get_local_pawn(0).CurrentEquipment
            if equipment == nil then return end
            local name = equipment:get_class():get_fname():to_string()
            for _, p in ipairs(SWING_ITEM_PATTERNS) do
                if string.find(name, p, 1, true) ~= nil then equipped = true end
            end
        end)
        if equipped ~= swingItem.equipped then
            swingItem.equipped = equipped
            clearMotion()
            log(equipped and "swing item equipped (peak mode)" or "swing item gone")
        end
    end
    return swingItem.equipped
end

-- Root motion off for melee and throw montages (2026-10-16, idea from another Hellraiser profile). The attack
-- montages (AM_FP_ATT_*1Handed* / *2Handed* / *MeleeAbility* / *GenesisKnife*, not the TakeOut draws) and throw
-- montages (*Throwables*) can carry root motion: in VR that lunges / turns the player with every swing. Their
-- bEnableRootMotionTranslation / Rotation are switched off when they start (montage assets, so once per asset); the
-- game values are kept and put back if the checkbox is unticked.
local ROOT_MOTION_MELEE_PARTS = { "1Handed", "2Handed", "MeleeAbility", "GenesisKnife" }
local ROOT_MOTION_SKIP_PARTS = { "FP_NAV", "Crouch", "Shoot", "Release", "TakeOut", "Takeout" }
local rootMotionChanged = {} -- montage full name -> { montage, translation, rotation }
local function hasAnyPart(name, parts)
    for _, p in ipairs(parts) do
        if string.find(name, p, 1, true) ~= nil then return true end
    end
    return false
end
uevrUtils.registerMontageChangeCallback(function(montage, montageName)
    if montage == nil or montageName == nil or configui.getValue("pm_no_root_motion") == false then return end
    local melee = string.find(montageName, "AM_FP_ATT", 1, true) ~= nil and hasAnyPart(montageName, ROOT_MOTION_MELEE_PARTS)
    local throw = string.find(montageName, "Throwables", 1, true) ~= nil
    if not (melee or throw) or hasAnyPart(montageName, ROOT_MOTION_SKIP_PARTS) then return end
    pcall(function()
        local key = montage:get_full_name()
        local t, r = montage.bEnableRootMotionTranslation, montage.bEnableRootMotionRotation
        if t ~= true and r ~= true then return end
        if rootMotionChanged[key] == nil then rootMotionChanged[key] = { montage = montage, translation = t, rotation = r } end
        montage.bEnableRootMotionTranslation = false
        montage.bEnableRootMotionRotation = false
        log("root motion off: " .. montageName)
    end)
end)
configui.onUpdate("pm_no_root_motion", function(value)
    if value ~= false then return end
    for key, e in pairs(rootMotionChanged) do
        pcall(function()
            if UEVR_UObjectHook.exists(e.montage) then
                e.montage.bEnableRootMotionTranslation = e.translation
                e.montage.bEnableRootMotionRotation = e.rotation
            end
        end)
    end
    rootMotionChanged = {}
end)

-- ---------------------------------------------------------------------------------------------
-- Per-tick body: once per tick from the post-stereo callback (valid controller poses)
-- ---------------------------------------------------------------------------------------------
local ranThisTick = false

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    ranThisTick = false
end)

local function tick()
    if configui.getValue("pm_enabled") == false then
        restoreRate("disabled")
        clearMotion()
        clearContact()
        return
    end
    local held = updateMeleeState()
    updateRate()
    local swingItem = not held and swingItemEquipped()
    if not held and not swingItem then
        clearMotion()
        clearContact()
        if #debugSpheres > 0 then hideDebugSpheres() end
        return
    end
    if swingItem then
        if #debugSpheres > 0 then hideDebugSpheres() end
        detect(true)
        return
    end
    if configui.getValue("pm_contact_mode") ~= false then
        refreshTracers()
        enemyRefreshTick = enemyRefreshTick + 1
        if enemyRefreshTick >= ENEMY_REFRESH_TICKS then
            enemyRefreshTick = 0
            local ok, err = pcall(refreshEnemies)
            if not ok then log("enemy refresh failed: " .. tostring(err)) end
        else
            refreshEnemyPositions()
        end
    end
    detect()
end

uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if not vr.is_hmd_active() then return end
    if ranThisTick then return end
    ranThisTick = true
    local ok, err = pcall(tick)
    if not ok then print("[physical_melee] " .. tostring(err)) end
end)

uevrUtils.registerUEVRCallback("attachment_grip_changed", function(id, gripHand, attachment)
    if gripHand == Handed.Right then
        restoreRate("weapon changed")
        triggerPollsLeft = 0
        clearMotion()
        clearContact()
        meleeHeld = false
        weaponMesh = nil
        tracers = {}
        tracerOwner = nil
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    rateActive = false
    triggerPollsLeft = 0
    clearMotion()
    clearContact()
    meleeHeld = false
    weaponMesh = nil
    tracers = {}
    tracerOwner = nil
    enemies = {}
    liveTargets, corpseTargets, breakableTargets = {}, {}, {}
    corpseCache, breakableList = {}, {}
    nextCorpseScan, nextBreakableScan = 0, 0
    debugSpheres = {}
end)

configui.onUpdate("pm_debug_capsule", function(value)
    if value ~= true then hideDebugSpheres() end
end)

print("[physical_melee] loaded")
