-- Videos, the death camera and extra cutscene signals (2026-10-16; ideas taken from another Hellraiser profile and
-- adapted to this one's montage rules).
--
-- Loads after uevrmenus.lua (file name order) because the montage rules below need montage.init() done.
--
--   * Videos: pre-rendered movies play through BinkMediaPlayer (OpenUrl ... CloseUrl). While one plays the VR hands,
--     weapon and the game's body / arms are hidden, input.lua is off (game aim) and the UI is fixed in place like a
--     menu (ui.lua viewLocked, priority 95: below menus.lua's 100, above inspection's / focus puzzles'). If CloseUrl
--     never comes, a player that has stopped playing for 2 s ends it too.
--   * Death camera: Pawn.DeathCauser / Pawn.KillerCauser are set while the game shows the player's death.
--   * Extra signals of scripted sequences: the pawn's collision switched off, or CharacterMovement's
--     bUseControllerDesiredRotation switched off (both on in normal play). Not while seated (uevrmenus.lua sets
--     bUseControllerDesiredRotation off itself there), on a ladder, in a focus puzzle / inspection or a menu - those
--     have their own handling. Must hold for 0.3 s.
--   * Extra cutscene montages by name (case-sensitive): AM_FP_SOM, AM_Forced, AfterFall, Dialogue - not hit reactions
--     (the other profile also counted AM_FP_REC / AM_REC, but here those are the in-combat flinches and knock-backs).
-- The last three drive one montage state rule, "* Rule: Cutscene (death / scripted)", seeded like
-- "* Rule: Cutscene (AnimMontage_*)"; videos have "* Rule: Video playing". Both are tunable in the Montages panel.

local uevrUtils = require('libs/uevr_utils')
local configui  = require('libs/configui')
local montage   = require('libs/montage')
local ui        = require('libs/ui')

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 7.5, label = "Cutscenes & Videos", layout = {
    { widgetType = "checkbox", id = "cx_video",    label = "Videos: hide hands / weapon, game aim, UI fixed in place", initialValue = true },
    { widgetType = "checkbox", id = "cx_death",    label = "Death camera counts as a cutscene", initialValue = true },
    { widgetType = "checkbox", id = "cx_signals",  label = "Collision off / controller rotation off count as a cutscene", initialValue = true },
    { widgetType = "checkbox", id = "cx_montages", label = "Montages AM_FP_SOM / AM_Forced / AfterFall / Dialogue count as a cutscene", initialValue = true },
    { widgetType = "text", id = "cx_status", label = "Status: -" },
}})

local POLL_S = 0.1
local SIGNAL_HOLD_S = 0.3
local VIDEO_STOPPED_S = 2.0
local VIDEO_UI_PRIORITY = 95
local CUTSCENE_MONTAGE_PARTS = { "AM_FP_SOM", "AM_Forced", "AfterFall", "Dialogue" }
local NOT_CUTSCENE_PARTS = { "FP_NAV", "Crouch", "Shoot", "Release", "TakeOut", "Takeout" }

local function enabled(id) return configui.getValue(id) ~= false end

local state = {
    video = false, videoPlayer = nil, videoOpenedAt = 0, videoStoppedSince = nil,
    death = false, signals = false, signalSince = nil, montage = false,
    cutscene = false, videoActive = false, uiOwned = false, nextPoll = 0,
}

-- ---------------------------------------------------------------------------------------------
-- Bink videos
-- ---------------------------------------------------------------------------------------------
local BINK_CLASS = "Class /Script/BinkMediaPlayer.BinkMediaPlayer"
local binkHooked = false
local function hookBink()
    if binkHooked then return end
    local ok, err = pcall(function()
        local class = uevr.api:find_uobject(BINK_CLASS)
        if class == nil then return end
        local open, close = class:find_function("OpenUrl"), class:find_function("CloseUrl")
        if open == nil or close == nil then return end
        open:hook_ptr(nil, function(fn, obj, locals, result)
            state.video, state.videoPlayer, state.videoOpenedAt, state.videoStoppedSince = true, obj, os.clock(), nil
            print("[video_cutscenes] video opened")
        end)
        close:hook_ptr(nil, function(fn, obj, locals, result)
            if state.video then print("[video_cutscenes] video closed") end
            state.video, state.videoPlayer, state.videoStoppedSince = false, nil, nil
        end)
        binkHooked = true
        print("[video_cutscenes] BinkMediaPlayer OpenUrl / CloseUrl hooked")
    end)
    if not ok then print("[video_cutscenes] Bink hook failed: " .. tostring(err)) end
end
hookBink()

-- fallback end: the player stopped playing (no CloseUrl), or it is gone
local function checkVideoStillPlaying(now)
    if not state.video then return end
    if now - state.videoOpenedAt < 1.0 then return end
    local playing = nil
    pcall(function()
        local p = state.videoPlayer
        if p == nil or not UEVR_UObjectHook.exists(p) then playing = false return end
        if p.IsPlaying ~= nil then
            playing = p:IsPlaying() == true
        elseif p.GetTime ~= nil then
            -- no IsPlaying: the play position not moving counts as stopped
            local ticks = p:GetTime().Ticks
            playing = ticks ~= state.videoLastTicks
            state.videoLastTicks = ticks
        end
    end)
    if playing == false then
        state.videoStoppedSince = state.videoStoppedSince or now
        if now - state.videoStoppedSince >= VIDEO_STOPPED_S then
            state.video, state.videoPlayer, state.videoStoppedSince = false, nil, nil
            print("[video_cutscenes] video ended (player stopped)")
        end
    else
        state.videoStoppedSince = nil
    end
end

-- ---------------------------------------------------------------------------------------------
-- Cutscene montages by name
-- ---------------------------------------------------------------------------------------------
local function hasAnyPart(name, parts)
    for _, p in ipairs(parts) do
        if string.find(name, p, 1, true) ~= nil then return true end
    end
    return false
end
uevrUtils.registerMontageChangeCallback(function(m, montageName)
    state.montage = montageName ~= nil and hasAnyPart(montageName, CUTSCENE_MONTAGE_PARTS) and not hasAnyPart(montageName, NOT_CUTSCENE_PARTS)
end)

-- ---------------------------------------------------------------------------------------------
-- Poll
-- ---------------------------------------------------------------------------------------------
local function otherHandlingActive(pawn)
    if _G.hrIsInMenu ~= nil and _G.hrIsInMenu() then return true end
    if _G.hrIsSeated ~= nil and _G.hrIsSeated() then return true end
    if _G.hrIsInFocusPuzzle ~= nil and _G.hrIsInFocusPuzzle() then return true end
    return pawn.LadderReference ~= nil
end

local function poll(now)
    checkVideoStillPlaying(now)
    local pawn = uevr.api:get_local_pawn(0)
    local isPlayer = pawn ~= nil and pawn:get_class():get_fname():to_string() == "CH_FirstPersonPlayable_C"

    state.death = false
    if isPlayer then
        pcall(function() state.death = pawn.DeathCauser ~= nil or pawn.KillerCauser ~= nil end)
    end

    local signal = false
    if isPlayer and not otherHandlingActive(pawn) then
        pcall(function()
            local cmc = pawn.CharacterMovement
            signal = pawn.bActorEnableCollision == false or (cmc ~= nil and cmc.bUseControllerDesiredRotation == false)
        end)
    end
    if signal then
        state.signalSince = state.signalSince or now
    else
        state.signalSince = nil
    end
    state.signals = signal and now - state.signalSince >= SIGNAL_HOLD_S

    local cutscene = (enabled("cx_death") and state.death) or (enabled("cx_signals") and state.signals)
        or (enabled("cx_montages") and state.montage and isPlayer)
    if cutscene ~= state.cutscene then
        print("[video_cutscenes] cutscene " .. (cutscene and string.format("started (death %s, signals %s, montage %s)",
            tostring(state.death), tostring(state.signals), tostring(state.montage)) or "ended"))
    end
    state.cutscene = cutscene

    local videoActive = enabled("cx_video") and state.video
    state.videoActive = videoActive
    -- UI fixed in place while a video plays (ui.lua has one slot per key, shared with menus.lua - see uevrmenus.lua)
    local inMenu = _G.hrIsInMenu ~= nil and _G.hrIsInMenu()
    if videoActive and not inMenu then
        ui.setCustomState("viewLocked", true, VIDEO_UI_PRIORITY)
        state.uiOwned = true
    elseif state.uiOwned and not inMenu then
        ui.setCustomState("viewLocked", nil)
        state.uiOwned = false
    elseif inMenu then
        state.uiOwned = false
    end

    configui.setLabel("cx_status", string.format("Status: video %s, death %s, signals %s, montage %s",
        state.video and "yes" or "no", state.death and "yes" or "no", state.signals and "yes" or "no", state.montage and "yes" or "no"))
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local now = os.clock()
    if now < state.nextPoll then return end
    state.nextPoll = now + POLL_S
    local ok, err = pcall(poll, now)
    if not ok then print("[video_cutscenes] " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    if state.uiOwned then pcall(function() ui.setCustomState("viewLocked", nil) end) end
    state.uiOwned = false
    state.death, state.signals, state.signalSince, state.montage, state.cutscene = false, false, nil, false, false
    hookBink() -- no-op once hooked
end)

-- ---------------------------------------------------------------------------------------------
-- Montage state rules (cached booleans: predicates run every pre-engine tick)
-- ---------------------------------------------------------------------------------------------
montage.addStateRule("rule_video", "* Rule: Video playing", function() return state.videoActive end, {
    handsWhenActive = 2,               handsWhenActivePriority = "100",
    inputWhenActive = 3,               inputWhenActivePriority = "100",
    pawnBodyWhenActive = 2,            pawnBodyWhenActivePriority = "100",
    pawnArmsWhenActive = 2,            pawnArmsWhenActivePriority = "100",
    aimMethodWhenActive = 2,           aimMethodWhenActivePriority = "100",
    weaponWhenActive = 2,              weaponWhenActivePriority = "100",
})
montage.addStateRule("rule_cutscene_state", "* Rule: Cutscene (death / scripted)", function() return state.cutscene end, {
    handsWhenActive = 2,               handsWhenActivePriority = "0",
    inputWhenActive = 3,               inputWhenActivePriority = "0",
    leftArmWhenActive = 1,             leftArmWhenActivePriority = "0",
    rightArmWhenActive = 1,            rightArmWhenActivePriority = "0",
    pawnBodyWhenActive = 1,            pawnBodyWhenActivePriority = "0",
    pawnArmsWhenActive = 3,            pawnArmsWhenActivePriority = "0",
    pawnArmBonesWhenActive = 3,        pawnArmBonesWhenActivePriority = "0",
    motionSicknessCompensationWhenActive = 1, motionSicknessCompensationWhenActivePriority = "0",
    leftAccessoryWhenActive = "",      leftAccessoryWhenActivePriority = "0",
    rightAccessoryWhenActive = "",     rightAccessoryWhenActivePriority = "0",
    aimMethodWhenActive = 2,           aimMethodWhenActivePriority = "0",
    weaponWhenActive = 2,              weaponWhenActivePriority = "0",
})

_G.hrIsVideoPlaying = function() return state.videoActive end

print("[video_cutscenes] loaded")
