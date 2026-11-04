-- Boss grab (Mingled Terror strangle, EP_6 church, 2026-11-03): the game aims the escape shots.
--
-- The boss grabs the player (player ability GA_PC_BeingStrangledByMt_C, boss ability GA_MingledTerror_Strangle_C).
-- With a ranged weapon the player escapes by dealing enough damage to the boss (boss GA TotalDamageReceivedToEscape vs
-- DamageRequiredToEscapeStrangle) before the kill timer; with the knife by a stab (worked in VR as it was). The
-- ability blocks aiming (Character.Blocked.Aiming) and steers the shot itself: GA_Fire fires a special point-blank
-- shot (its 24 pellet sweeps are zero-length at the camera - MCP + aim-fix log 2026-11-03). In VR none of it landed
-- (TotalDamageReceivedToEscape stayed 0 over 3 grabs, 4 shots each): input.lua kept setting the control rotation
-- from the head, and HellraiserAimFix.dll moved the shot to the barrel.
-- So while the player's strangle ability is active:
--   * a montage state rule hands the aim to the game (aimMethodWhenActive = Game - libs/montage.lua tells input.lua
--     to stand down and sets VR_AimMethod 0, restored afterwards),
--   * custom event "HellraiserGameAim" every tick makes the aim-fix plugin leave the fire traces as the game made them.
-- Start: the first AM_FP_MT_Strangle* montage (pawn montage callback); the ability instance is then looked up once
-- (class objects, outer = the pawn) and its bIsActive ends the state. If it cannot be found, the state ends 15 s
-- after the last strangle montage.
-- Loads after uevrmenus.lua (file name order): the montage state rule needs montage.init() done.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local montage = require('libs/montage')

_G.HR_SECTIONS = _G.HR_SECTIONS or {}
table.insert(_G.HR_SECTIONS, { order = 6.9, label = "Boss Grab", layout = {
    { widgetType = "checkbox", id = "sg_game_aim", label = "Grabbed by the Mingled Terror: the game aims the escape shots", initialValue = true },
}})

local ABILITY_CLASS = "BlueprintGeneratedClass /Game/Gameplay/Abilities/Player/GA_PC_BeingStrangledByMt.GA_PC_BeingStrangledByMt_C"
local FALLBACK_HOLD_S = 15.0
local state = { active = false, ability = nil, lastStrangleMontage = 0, cls = nil }

local function findAbility(pawn)
    if state.cls == nil then state.cls = uevr.api:find_uobject(ABILITY_CLASS) end
    if state.cls == nil or pawn == nil then return nil end
    for _, obj in ipairs(state.cls:get_objects_matching(false)) do
        if obj:get_outer() == pawn and obj.bIsActive == true then return obj end
    end
    return nil
end

local function stop(reason)
    if not state.active then return end
    state.active, state.ability = false, nil
    print("[vr_strangle_game_aim] ended (" .. reason .. ")")
end

uevrUtils.registerMontageChangeCallback(function(m, montageName)
    if montageName == nil or string.find(montageName, "_MT_Strangle", 1, true) == nil then return end
    state.lastStrangleMontage = os.clock()
    if state.active then return end
    state.active = true
    pcall(function() state.ability = findAbility(uevr.api:get_local_pawn(0)) end)
    print("[vr_strangle_game_aim] strangle started (" .. montageName .. "), ability " .. (state.ability ~= nil and "found" or "NOT found - montage timeout"))
end)

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if not state.active then return end
    if state.ability ~= nil then
        local ok, isActive = pcall(function() return state.ability.bIsActive end)
        if not ok or isActive ~= true then stop("ability ended") return end
    elseif os.clock() - state.lastStrangleMontage > FALLBACK_HOLD_S then
        stop("no strangle montage for " .. FALLBACK_HOLD_S .. " s")
        return
    end
    if configui.getValue("sg_game_aim") ~= false then
        uevr.api:dispatch_custom_event("HellraiserGameAim", "1")
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    stop("level change")
end)

_G.hrIsStrangled = function() return state.active end

montage.addStateRule("rule_strangled", "* Rule: Grabbed by the Mingled Terror (game aims)", function()
    return state.active and configui.getValue("sg_game_aim") ~= false
end, {
    aimMethodWhenActive = 2, aimMethodWhenActivePriority = "100",
})

print("[vr_strangle_game_aim] loaded")
