-- Throwables (bottle / stone) from the VR right hand (2026-10-10).
--
-- Game facts (MCP, 2026-10-10):
--   * Equipped throwable = Pawn.CurrentEquipment BP_ThrowableBottle_C (CoreTool; stones use the same ability). RT runs
--     GA_UseToolThrowableBottle_C.UseTool, which spawns the projectile (deferred spawn) at a camera-based transform:
--     location + forward * SpawnDistanceFromPlayer (120), pitch + SpawnPitchOffset (10).
--   * Projectile = BP_Throwable_Bottle_C / BP_Throwable_Stone_C (parent BP_Throwable_Base_C): ProjectileMovement,
--     InitialSpeed 1700, gravity 1, rotation follows velocity, no bounce. Nothing steers it after the spawn, so the
--     spawn transform is the whole aim.
--
-- VR: ReceiveBeginPlay of the projectile classes is hooked (runs inside the spawn, before the projectile's first
-- tick), and the projectile is moved to the right hand and its velocity replaced there:
--   * "RT throws where the hand points": controller forward + panel trim + upward offset, game speed x multiplier.
--   * "Hold RT, swing, release": RT is kept from the game while held; on release the hand's velocity (relative to the
--     head, so walking / turning does not count) becomes the throw velocity (x scale, clamped) and RT is tapped for the
--     game. A release slower than the minimum speed throws nothing. The game needs some time from RT to the spawn; the
--     projectile is started where it would be by then on the release trajectory (catch-up).
-- Only projectiles that appear close to the player shortly after the player's own RT are touched.

local uevrUtils   = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui    = require('libs/configui')

local vr = uevr.params.vr

local PROJECTILE_CLASSES = {
    "BlueprintGeneratedClass /Game/Blueprints/Actors/Interactables/Throwable/BP_Throwable_Base.BP_Throwable_Base_C",
    "BlueprintGeneratedClass /Game/Blueprints/Actors/Interactables/Throwable/BP_Throwable_Bottle.BP_Throwable_Bottle_C",
    "BlueprintGeneratedClass /Game/Blueprints/Actors/Interactables/Throwable/BP_Throwable_Stone.BP_Throwable_Stone_C",
}
local EQUIP_NAME_PATTERN  = "Throwable"  -- in the class name of Pawn.CurrentEquipment
local EQUIP_POLL_S        = 0.2
local RT_THRESHOLD        = 100          -- 0..255
local RT_TO_SPAWN_MAX_S   = 3.0          -- a projectile later than this after RT is not ours
local SPAWN_NEAR_PLAYER   = 350.0        -- cm from the HMD: the game spawns it 120 cm in front of the camera
local TAP_POLLS           = 3
local TAP_MAX_HOLD_S      = 0.25
local GRAVITY_Z           = -980.0
local SAMPLE_WINDOW_S     = 0.06         -- hand velocity = motion over this window
local PEAK_WINDOW_S       = 0.12         -- best windowed velocity this long before the release counts
local CATCHUP_MAX_S       = 0.15         -- never start the projectile further along than this
local RATE_MAX_S          = 1.0          -- unconditional restore deadline for the animation speed
local REAPPLY_S           = 0.2          -- keep our velocity this long if the game writes its own again
local SAME_DIR_DOT        = 0.9986       -- ~3 deg

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 5.7, label = "Throwables", layout = {
    { widgetType = "checkbox", id = "thr_enabled", label = "Throw bottles / stones from the right hand", initialValue = true },
    { widgetType = "combo", id = "thr_mode", label = "Throw mode", initialValue = 2, selections = { "RT throws where the hand points", "Hold RT, swing, release" } },
    { widgetType = "slider_float", id = "thr_spawn_dist", label = "Start this far from the hand (cm)", initialValue = 30.0, range = {0.0, 120.0}, speed = 0.5 },
    { widgetType = "spacing" },
    { widgetType = "text", label = "RT throw (hand points)" },
    { widgetType = "slider_float", id = "thr_yaw", label = "Aim left/right (deg, + = right)", initialValue = 0.0, range = {-30.0, 30.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "thr_pitch", label = "Aim down/up (deg, + = up)", initialValue = 0.0, range = {-30.0, 30.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "thr_arc", label = "Extra upward angle (deg, game 10)", initialValue = 10.0, range = {0.0, 30.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "thr_speed", label = "Speed (x game speed)", initialValue = 1.0, range = {0.3, 2.0}, speed = 0.01 },
    { widgetType = "spacing" },
    { widgetType = "text", label = "Swing and release" },
    { widgetType = "slider_float", id = "thr_phys_scale", label = "Throw speed (x hand speed)", initialValue = 4.5, range = {1.0, 8.0}, speed = 0.05 },
    { widgetType = "slider_float", id = "thr_phys_floor", label = "Slowest throw (cm/s)", initialValue = 1000.0, range = {300.0, 1700.0}, speed = 10.0 },
    { widgetType = "slider_float", id = "thr_phys_assist", label = "Aim assist: pull the throw toward where you look (0 = hand only)", initialValue = 0.5, range = {0.0, 1.0}, speed = 0.01 },
    { widgetType = "slider_float", id = "thr_phys_arc", label = "Extra upward angle (deg)", initialValue = 8.0, range = {0.0, 30.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "thr_phys_min", label = "Slowest hand speed that still throws (cm/s)", initialValue = 120.0, range = {30.0, 400.0}, speed = 1.0 },
    { widgetType = "slider_float", id = "thr_phys_max", label = "Fastest throw (cm/s, game 1700)", initialValue = 2500.0, range = {800.0, 4000.0}, speed = 10.0 },
    { widgetType = "checkbox", id = "thr_phys_catchup", label = "Start the projectile where it would be by now (hides the game's delay)", initialValue = true },
    { widgetType = "spacing" },
    { widgetType = "slider_float", id = "thr_anim_rate", label = "Throw animation speed until the projectile appears (cuts the game's delay)", initialValue = 20.0, range = {1.0, 30.0}, speed = 0.1 },
    { widgetType = "checkbox", id = "thr_debug_log", label = "Debug: write data/throwables_log.txt", initialValue = false },
    { widgetType = "text", id = "thr_status", label = "Throwable: -" },
    { widgetType = "text", id = "thr_last", label = "Last throw: -" },
}})

local function cfgNum(id, default)
    local v = configui.getValue(id)
    if type(v) ~= "number" then return default end
    return v
end

local logLines = {}
local function log(text)
    if configui.getValue("thr_debug_log") ~= true then return end -- off for release (new id: the old thr_log was saved on)
    print("[throwables] " .. tostring(text))
    table.insert(logLines, string.format("%.3f %s", os.clock(), tostring(text)))
    while #logLines > 200 do table.remove(logLines, 1) end
    pcall(function() fs.write("throwables_log.txt", table.concat(logLines, "\n") .. "\n") end)
end

local function alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
    return ok and r
end

local function vlen(v) return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end

local function isPhysicalMode() return configui.getValue("thr_mode") ~= 1 end

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------
local throwableEquipped = false
local nextEquipPoll = 0
local rtHeld = false          -- real RT, as the player holds it
local rtGameTime = nil        -- when the game last got an RT press with a throwable out (real or injected)
local tapPollsLeft, tapDeadline = 0, 0
local releaseRequested = false -- set by the input callback (physical mode), consumed by the sampler
local pending = nil           -- physical throw waiting for the spawn: { pos, vel, at, handSpeed }
local corrected = nil         -- { actor, pmc, vel, gameDir, at }
local hooked = {}             -- class address -> true

-- ---------------------------------------------------------------------------------------------
-- Hand velocity (relative to the head), sampled once per tick from the post-stereo callback (valid poses)
-- ---------------------------------------------------------------------------------------------
local samples = {}            -- { t, X, Y, Z } of hand - head, newest last
local lastGaze = nil          -- HMD forward at the newest sample
local rtPressPending = false  -- RT throw mode: the press reached the game (set by the input callback)
local lastHand = nil          -- world position of the hand at the newest sample
local bestVel = nil           -- { t, X, Y, Z }: fastest windowed velocity within PEAK_WINDOW_S

local function clearSamples()
    samples, bestVel, lastHand, lastGaze = {}, nil, nil, nil
end

local function sampleHand()
    local hand = controllers.getController(Handed.Right, true)
    local head = controllers.getHMDController()
    if not alive(hand) or not alive(head) then clearSamples() return end
    local hp, hd = hand:K2_GetComponentLocation(), head:K2_GetComponentLocation()
    if hp == nil or hd == nil then clearSamples() return end
    local now = os.clock()
    local newest = samples[#samples]
    if newest ~= nil and now - newest.t > 0.1 then clearSamples() end
    lastHand = { X = hp.X, Y = hp.Y, Z = hp.Z }
    local g = kismet_math_library:GetForwardVector(head:K2_GetComponentRotation())
    lastGaze = { X = g.X, Y = g.Y, Z = g.Z }
    table.insert(samples, { t = now, X = hp.X - hd.X, Y = hp.Y - hd.Y, Z = hp.Z - hd.Z })
    while #samples > 1 and now - samples[1].t > 0.3 do table.remove(samples, 1) end

    -- velocity over the last SAMPLE_WINDOW_S
    local cur = samples[#samples]
    local old = nil
    for i = #samples - 1, 1, -1 do
        old = samples[i]
        if cur.t - old.t >= SAMPLE_WINDOW_S then break end
    end
    if old == nil or cur.t - old.t < 0.005 then return end
    local dt = cur.t - old.t
    local v = { t = now, X = (cur.X - old.X) / dt, Y = (cur.Y - old.Y) / dt, Z = (cur.Z - old.Z) / dt }
    if bestVel == nil or now - bestVel.t > PEAK_WINDOW_S or vlen(v) >= vlen(bestVel) then bestVel = v end
end

-- ---------------------------------------------------------------------------------------------
-- Animation speed: the game spawns the projectile from the throw animation, ~0.55 s after RT at normal speed (log
-- 2026-10-10). The arms animate faster from RT until the projectile appears.
-- ---------------------------------------------------------------------------------------------
local rate = { mesh = nil, at = 0 }

local function restoreRate()
    local mesh = rate.mesh
    rate.mesh = nil
    if mesh ~= nil and alive(mesh) then pcall(function() mesh.GlobalAnimRateScale = 1.0 end) end
end

local function startRate()
    local r = cfgNum("thr_anim_rate", 20.0)
    if r <= 1.0 then return end
    pcall(function()
        local mesh = uevr.api:get_local_pawn(0).Mesh
        if mesh == nil then return end
        mesh.GlobalAnimRateScale = r
        rate.mesh, rate.at = mesh, os.clock()
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Input: RT bookkeeping, and in swing mode RT held back until the release
-- ---------------------------------------------------------------------------------------------
local function throwsActive()
    if configui.getValue("thr_enabled") == false or not throwableEquipped then return false end
    if _G.hrCutsceneActive == true then return false end
    if _G.hrIsInMenu ~= nil and _G.hrIsInMenu() then return false end
    return true
end

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    local down = state.Gamepad.bRightTrigger > RT_THRESHOLD
    if not throwsActive() then
        rtHeld, tapPollsLeft = down, 0
        return
    end
    if isPhysicalMode() then
        if rtHeld and not down then releaseRequested = true end
        rtHeld = down
        state.Gamepad.bRightTrigger = 0
        if tapPollsLeft > 0 then
            if os.clock() > tapDeadline then
                tapPollsLeft = 0
            else
                state.Gamepad.bRightTrigger = 255
                tapPollsLeft = tapPollsLeft - 1
            end
        end
    else
        if down and not rtHeld then rtGameTime = os.clock() rtPressPending = true end
        rtHeld = down
    end
end, 20)

local function handleRelease()
    releaseRequested = false
    local v = bestVel
    if v == nil or lastHand == nil or os.clock() - v.t > PEAK_WINDOW_S then
        configui.setLabel("thr_last", "Last throw: no hand motion measured")
        return
    end
    local handSpeed = vlen(v)
    if handSpeed < cfgNum("thr_phys_min", 120.0) then
        configui.setLabel("thr_last", string.format("Last throw: hand too slow (%.0f cm/s) - nothing thrown", handSpeed))
        log(string.format("release at %.0f cm/s: below the minimum, nothing thrown", handSpeed))
        return
    end
    local speed = math.min(math.max(handSpeed * cfgNum("thr_phys_scale", 4.5), cfgNum("thr_phys_floor", 1000.0)), cfgNum("thr_phys_max", 2500.0))
    -- direction: the hand's, pulled toward the gaze (a late release bends the swing down / sideways), then raised
    local d = { X = v.X / handSpeed, Y = v.Y / handSpeed, Z = v.Z / handSpeed }
    local a = cfgNum("thr_phys_assist", 0.5)
    if lastGaze ~= nil and a > 0 then
        d = { X = d.X + (lastGaze.X - d.X) * a, Y = d.Y + (lastGaze.Y - d.Y) * a, Z = d.Z + (lastGaze.Z - d.Z) * a }
    end
    local r = kismet_math_library:Conv_VectorToRotator(uevrUtils.vector(d.X, d.Y, d.Z))
    local f = kismet_math_library:GetForwardVector(uevrUtils.rotator(math.min(r.Pitch + cfgNum("thr_phys_arc", 8.0), 89.0), r.Yaw, 0))
    pending = { pos = lastHand, vel = { X = f.X * speed, Y = f.Y * speed, Z = f.Z * speed }, at = os.clock(), handSpeed = handSpeed }
    startRate()
    tapPollsLeft, tapDeadline = TAP_POLLS, os.clock() + TAP_MAX_HOLD_S
    rtGameTime = os.clock()
    log(string.format("release: hand %.0f cm/s -> throw %.0f cm/s, RT tapped", handSpeed, speed))
end

-- ---------------------------------------------------------------------------------------------
-- The spawn: runs inside the projectile's BeginPlay
-- ---------------------------------------------------------------------------------------------
local function aimThrow()
    local ctrl = controllers.getController(Handed.Right, true)
    if not alive(ctrl) then return nil end
    local loc, rot = ctrl:K2_GetComponentLocation(), ctrl:K2_GetComponentRotation()
    local yaw, pitch = cfgNum("thr_yaw", 0.0), cfgNum("thr_pitch", 0.0)
    if yaw ~= 0 or pitch ~= 0 then
        rot = kismet_math_library:ComposeRotators(uevrUtils.rotator(pitch, yaw, 0), rot)
    end
    -- the upward offset is a world pitch, as in the game
    local dir = kismet_math_library:GetForwardVector(uevrUtils.rotator(rot.Pitch + cfgNum("thr_arc", 10.0), rot.Yaw, 0))
    return { X = loc.X, Y = loc.Y, Z = loc.Z }, { X = dir.X, Y = dir.Y, Z = dir.Z }
end

-- start point along the release trajectory after `t` seconds; stops short of anything in the way
local function catchUp(pos, vel, t, ignore)
    local p = { X = pos.X + vel.X * t, Y = pos.Y + vel.Y * t, Z = pos.Z + vel.Z * t + 0.5 * GRAVITY_Z * t * t }
    local v = { X = vel.X, Y = vel.Y, Z = vel.Z + GRAVITY_Z * t }
    local d = { X = p.X - pos.X, Y = p.Y - pos.Y, Z = p.Z - pos.Z }
    local dist = vlen(d)
    if dist < 1 then return pos, vel end
    local n = { X = d.X / dist, Y = d.Y / dist, Z = d.Z / dist }
    local hit = nil
    pcall(function()
        hit = uevrUtils.getTargetLocation(uevrUtils.vector(pos.X, pos.Y, pos.Z), uevrUtils.vector(n.X, n.Y, n.Z), 0, ignore, false, 0, dist)
    end)
    if hit ~= nil then
        local hd = vlen({ X = hit.X - pos.X, Y = hit.Y - pos.Y, Z = hit.Z - pos.Z })
        if hd < dist - 1 then
            local back = math.max(hd - 10, 0)
            return { X = pos.X + n.X * back, Y = pos.Y + n.Y * back, Z = pos.Z + n.Z * back }, vel
        end
    end
    return p, v
end

local function onProjectileSpawn(actor)
    if actor == nil or not throwsActive() then return end
    if corrected ~= nil and corrected.actor == actor then return end -- child + parent hook on the same spawn
    local now = os.clock()
    if rtGameTime == nil or now - rtGameTime > RT_TO_SPAWN_MAX_S then return end
    local pmc = actor.ProjectileMovement
    if pmc == nil then return end
    local head = controllers.getHMDController()
    if not alive(head) then return end
    local hd, at = head:K2_GetComponentLocation(), actor:K2_GetActorLocation()
    if vlen({ X = at.X - hd.X, Y = at.Y - hd.Y, Z = at.Z - hd.Z }) > SPAWN_NEAR_PLAYER then return end -- someone else's

    local gv = pmc.Velocity
    local gameSpeed = vlen(gv)
    if gameSpeed < 1 then gameSpeed = pmc.InitialSpeed or 1700.0 end
    local gameDir = { X = gv.X / gameSpeed, Y = gv.Y / gameSpeed, Z = gv.Z / gameSpeed }
    local delay = now - rtGameTime
    local pawn = uevr.api:get_local_pawn(0)

    local pos, vel, what = nil, nil, nil
    if isPhysicalMode() and pending ~= nil then
        local p = pending
        pending = nil
        pos, vel = p.pos, p.vel
        local speed = vlen(vel)
        local dist = cfgNum("thr_spawn_dist", 30.0)
        pos = { X = pos.X + vel.X / speed * dist, Y = pos.Y + vel.Y / speed * dist, Z = pos.Z + vel.Z / speed * dist }
        if configui.getValue("thr_phys_catchup") ~= false then
            pos, vel = catchUp(pos, vel, math.min(now - p.at, CATCHUP_MAX_S), { pawn, actor })
        end
        what = string.format("swing %.0f -> %.0f cm/s", p.handSpeed, speed)
    else
        local loc, dir = aimThrow()
        if loc == nil then return end
        local speed = gameSpeed * cfgNum("thr_speed", 1.0)
        local dist = cfgNum("thr_spawn_dist", 30.0)
        pos = { X = loc.X + dir.X * dist, Y = loc.Y + dir.Y * dist, Z = loc.Z + dir.Z * dist }
        vel = { X = dir.X * speed, Y = dir.Y * speed, Z = dir.Z * speed }
        what = string.format("hand aim %.0f cm/s", speed)
    end

    local rot = kismet_math_library:Conv_VectorToRotator(uevrUtils.vector(vel.X, vel.Y, vel.Z))
    actor:K2_SetActorLocationAndRotation(uevrUtils.vector(pos.X, pos.Y, pos.Z), rot, false, reusable_hit_result, true)
    pmc.Velocity.X, pmc.Velocity.Y, pmc.Velocity.Z = vel.X, vel.Y, vel.Z
    corrected = { actor = actor, pmc = pmc, vel = vel, gameDir = gameDir, at = now }
    restoreRate()

    configui.setLabel("thr_last", string.format("Last throw: %s, game took %.0f ms from RT", what, delay * 1000))
    log(string.format("%s: %s; RT->spawn %.0f ms; game dir (%.2f %.2f %.2f) speed %.0f at (%.0f %.0f %.0f) -> vel (%.0f %.0f %.0f) at (%.0f %.0f %.0f)",
        actor:get_class():get_fname():to_string(), what, delay * 1000, gameDir.X, gameDir.Y, gameDir.Z, gameSpeed,
        at.X, at.Y, at.Z, vel.X, vel.Y, vel.Z, pos.X, pos.Y, pos.Z))
end

local function spawnHook(fn, obj, locals, result)
    local ok, err = pcall(onProjectileSpawn, obj)
    if not ok then log("spawn hook: " .. tostring(err)) end
end

-- The projectile classes are loaded whenever a throwable is equipped (the ability references them), so the lookup
-- only runs then - a find_uobject miss costs hundreds of ms on this backend.
local function ensureHooks()
    for _, name in ipairs(PROJECTILE_CLASSES) do
        local ok, err = pcall(function()
            local class = uevr.api:find_uobject(name)
            if class == nil then return end
            local key = class:get_address()
            if hooked[key] then return end
            local fn = class:find_function("ReceiveBeginPlay")
            if fn == nil then return end
            fn:hook_ptr(nil, spawnHook)
            hooked[key] = true
            log("hooked ReceiveBeginPlay of " .. name)
        end)
        if not ok then log("hook failed for " .. name .. ": " .. tostring(err)) end
    end
end

-- ---------------------------------------------------------------------------------------------
-- Ticks
-- ---------------------------------------------------------------------------------------------
local function pollEquipment()
    local equipped, label = false, "none"
    pcall(function()
        local pawn = uevr.api:get_local_pawn(0)
        local equipment = pawn ~= nil and pawn.CurrentEquipment or nil
        if equipment == nil then return end
        local name = equipment:get_class():get_fname():to_string()
        if string.find(name, EQUIP_NAME_PATTERN, 1, true) ~= nil then equipped, label = true, name end
    end)
    if equipped and not throwableEquipped then ensureHooks() end
    if equipped ~= throwableEquipped then
        throwableEquipped = equipped
        pending, releaseRequested, tapPollsLeft = nil, false, 0
        configui.setLabel("thr_status", "Throwable: " .. label)
    end
end

-- the game writing its own velocity again right after the spawn: put ours back; anything else (a hit) ends it
local function holdVelocity()
    local c = corrected
    if c == nil then return end
    if os.clock() - c.at > REAPPLY_S or not alive(c.actor) then corrected = nil return end
    local v = c.pmc.Velocity
    local speed = vlen(v)
    if speed < 1 then corrected = nil return end
    if (v.X * c.gameDir.X + v.Y * c.gameDir.Y + v.Z * c.gameDir.Z) / speed >= SAME_DIR_DOT
        and vlen({ X = v.X - c.vel.X, Y = v.Y - c.vel.Y, Z = v.Z - c.vel.Z }) > 50 then
        v.X, v.Y, v.Z = c.vel.X, c.vel.Y, c.vel.Z
        log("the game re-applied its own velocity - ours put back")
    end
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if os.clock() >= nextEquipPoll then
        nextEquipPoll = os.clock() + EQUIP_POLL_S
        pollEquipment()
    end
    if rtPressPending then
        rtPressPending = false
        if throwsActive() then startRate() end
    end
    if rate.mesh ~= nil and os.clock() - rate.at > RATE_MAX_S then restoreRate() end
    if pending ~= nil and os.clock() - pending.at > RT_TO_SPAWN_MAX_S then
        pending = nil
        log("no projectile appeared after the release")
    end
end)

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    local ok, err = pcall(holdVelocity)
    if not ok then corrected = nil end
end)

local ranThisTick = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisTick = false end)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if ranThisTick or not vr.is_hmd_active() then return end
    ranThisTick = true
    if not throwsActive() or not isPhysicalMode() then
        releaseRequested = false
        if #samples > 0 then clearSamples() end
        return
    end
    local ok, err = pcall(function()
        sampleHand()
        if releaseRequested then handleRelease() end
    end)
    if not ok then print("[throwables] " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    throwableEquipped, nextEquipPoll = false, 0
    pending, corrected, releaseRequested, tapPollsLeft, rtGameTime = nil, nil, false, 0, nil
    rate.mesh, rtPressPending = nil, false
    clearSamples()
end)

print("[throwables] loaded")
