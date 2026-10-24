local uevrUtils = require("libs/uevr_utils")

local M = {}

local kismet_math_library = nil
local empty_hitresult = nil

local function init()
    if kismet_math_library == nil then
        local kismet_class = uevr.api:find_uobject("Class /Script/Engine.KismetMathLibrary")
        if kismet_class then
            kismet_math_library = kismet_class:get_class_default_object()
        end
        
        local hitresult_c = uevr.api:find_uobject("ScriptStruct /Script/Engine.HitResult")
        if hitresult_c then
            empty_hitresult = StructObject.new(hitresult_c)
        end
    end
end

--[[
    Calculates and applies the physical two-handed "turret" rotation to a weapon component.
    The weapon will pivot to point its forward axis at the off-hand, while 
    maintaining its existing Up vector to prevent unwanted rolling.
    
    @param weaponRootComponent: The USceneComponent of the weapon (e.g. Mesh).
    @param dominantHandComponent: The USceneComponent representing the dominant hand (grip).
    @param offHandComponent: The USceneComponent representing the off-hand (stabilizer).
]]--
function M.applyTwoHandedRotation(weaponRootComponent, dominantHandComponent, offHandComponent)
    init()
    if not kismet_math_library or not empty_hitresult then return end
    if not weaponRootComponent or not dominantHandComponent or not offHandComponent then return end

    local dominant_hand_pos = dominantHandComponent:K2_GetComponentLocation()
    local off_hand_pos = offHandComponent:K2_GetComponentLocation()
    
    -- Vector pointing from dominant hand TO off hand
    local dir_to_off_hand = (off_hand_pos - dominant_hand_pos):normalized()
    local dominant_hand_rotation = dominantHandComponent:K2_GetComponentRotation()

    local weapon_up_vector = weaponRootComponent:GetUpVector()
    
    -- Target rotation: Forward points at off-hand, Up matches weapon's current Up
    local new_direction_rot = kismet_math_library:MakeRotFromXZ(dir_to_off_hand, weapon_up_vector)

    -- Convert to quaternions
    local target_dir_q = kismet_math_library:Conv_RotatorToQuaternion(new_direction_rot)
    local dominant_hand_q = kismet_math_library:Conv_RotatorToQuaternion(dominant_hand_rotation)

    -- Calculate the rotational delta between where the dominant hand is pointing 
    -- and where it needs to point.
    -- delta_q = Inverse( dominant_hand_q * Inverse(target_dir_q) )
    local delta_q = kismet_math_library:Quat_Inversed(
        kismet_math_library:Multiply_QuatQuat(
            dominant_hand_q, 
            kismet_math_library:Quat_Inversed(target_dir_q)
        )
    )

    -- Apply this delta to the weapon's CURRENT world rotation
    local current_rotation = weaponRootComponent:K2_GetComponentRotation()
    local current_rot_q = kismet_math_library:Conv_RotatorToQuaternion(current_rotation)
    local new_rot_q = kismet_math_library:Multiply_QuatQuat(delta_q, current_rot_q)

    -- Set the new rotation back to the weapon
    local final_rotation = kismet_math_library:Quat_Rotator(new_rot_q)
    weaponRootComponent:K2_SetWorldRotation(final_rotation, false, empty_hitresult, false)
end

return M
