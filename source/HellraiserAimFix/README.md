# HellraiserAimFix: UEVR weapon aim plugin for Hellraiser (Revival Demo, UE 5.6)

Makes the player's shots follow the motion-controller-held gun barrel instead of the camera.
Built from the TownfallAimFix template (same hook pattern; this game ships no PDB).

## How the game fires (MCP hook trace, 2026-10-07, Colt 1911)

Blueprint ability `GA_Fire_C` (C++ parent `PlayerAbility_FireBase`) per shot:
`GetAllTraceEndPositions(Weapon, AimTraceLength, MaxTraceLength)` (end points = camera aim + spread) →
Kismet `LineTraceSingle` ×1 → `SphereTraceMulti` ×2. All from Blueprint, i.e. through the exec thunks.

## What the plugin hooks

| Function | Exec thunk RVA | Native RVA |
|---|---|---|
| `UKismetSystemLibrary::LineTraceSingle` | 0x4195C40 | 0x414F8C0 |
| `UKismetSystemLibrary::SphereTraceMulti` | 0x41B7690 | 0x415A310 |

Thunks are taken from the live UFunctions (RVAs only as fallback). Natives are verified (`thunk calls native`); if
that fails, the native is re-derived as the call whose result is stored from `AL` (`mov byte ptr [r13], al`).
Note: OW2's "last call before RET" heuristic is wrong here, because the last calls free the ActorsToIgnore copies.
Native ABI (both): RCX ctx, RDX &Start, R8 &End, then R9 channel (LineTrace) / XMM3 radius (SphereTrace).

Gate: the exec hook reads `FFrame->Object` (+0x18) and only touches traces called by a `PlayerAbility_FireBase`
instance while the pawn's `CurrentEquipment` is a `CoreRangedWeapon`.
Override: start within `StartTolerance` (60 cm) of the camera → start = `MuzzleFlashSocket` on the weapon's
RootComponent, direction = original direction rotated by camera-forward → barrel (`BarrelAxis` +Y), same length
(keeps the game's spread). The gun is appended to a stack copy of ActorsToIgnore. Other traces are left alone.

How the RVAs were found (no PDB): the `{ "LineTraceSingle", &execLineTraceSingle }` native-registration pairs in
.rdata (search the ANSI name, then the qword referencing it; the next qword is the thunk), then
`dumpbin /disasm /range:` on the thunk. MCP `uevr_hook_add` replaces UFunction::Func with a stub, so read thunks
before hooking via MCP (or offline as above).

## Melee (physical melee follow)

`DoTargeting_Fanout_C` swing fans (Kismet `SphereTraceSingle`, RVAs 0x41B83E0 / 0x415AA70) are rotated about the
camera toward the enemy `physical_melee.lua` reports via custom event `HellraiserMeleeTarget` ("x,y,z"), for
`MeleeTargetWindow` s, and narrowed onto it: ray direction = lerp(target direction, rotated game ray, spread) with
spread = optional 4th event value ("x,y,z,spread", physical_melee.lua slider) else `MeleeFollowSpread` (0.35;
0 = one line, 1 = full game fan); every ray reaches `MeleeFollowExtraReach` (30) cm past the target. With values 5-7
("x,y,z,spread,sx,sy,sz" = the touching weapon point just before contact) and `MeleeFromWeapon` (1), the rays START
there instead, each aimed at the spot its narrowed camera ray would reach (target-behind-camera check skipped), with
the pawn and its CurrentEquipment added to ActorsToIgnore. `DiscoverMelee` logs SphereTraceSingle bursts by caller, each HIT line followed by the hit
actor / component / bone, impact point (camera-local), impact-to-weapon distance and START-PENETRATING;
`DiscoverMeleeMaxLines` caps it (default 5000 lines per session).

## Genesis cube telekinesis from the left hand (2026-10-08)

Pose: custom event `HellraiserLeftAim` ("x,y,z,pitch,yaw,roll"), sent every pre-engine tick by
`scripts/genesis_cube.lua` while the cube is in the VR left hand (left controller + the panel's grab/target trim).
Poses older than `LeftAimMaxAge` (0.25 s) are ignored, so stopping the sends gives the game its camera aim back.

* **Target pick** - `COMP_TelekinesisTargeting` (on the pawn). Its tick override (vtable slot 128) tail-jumps to the
  targeting update (RVA 0x57A0B00, resolved from the CDO vtable). The aim ray (RVA 0x579D370, prologue-verified) is
  the PlayerController deprojection of the SCREEN CENTRE (GetViewportSize + DeprojectScreenPositionToWorld), cached
  per update: its world location / direction outputs are replaced. During the update the camera transforms it reads
  raw (`PlayerCameraActorRef` +0x110 and its ChildActor's RootComponent; ComponentToWorld quat +0x1E0 / loc +0x200)
  are swapped for the hand pose and restored afterwards.
* **Moving world objects** - `BP_TASK_TelekinesisCube_BaseActor_C` (CalculateTargetCoordinateLine/Circle: camera ray
  x plane) and `GA_TelekinesisPuzzle_C` (drop angle) read `K2_GetComponentLocation` / `GetForwardVector` of the
  pawn's `FPCameraActor`. The SceneComponent exec thunks are hooked: for callers in `TelekinesisCameraCallers` asking
  `FPCameraActor`, the result is the hand pose.
* **Throws** are NOT done here: `BP_TelekinesisBase_C` aims the launch internally from the camera, and
  `genesis_cube.lua` re-aims the projectile's velocity on the release frame instead.

## Seated interactions aimed with the head (2026-10-08)

Chair puzzle (EP_1 cell): `InteractManager::CheckCurrentInteraction` (RVA 0x5869990) takes TargetLocation / TargetForward
from the pawn's `FPCameraActor` ComponentToWorld (raw) and compares the angle to each interactable (`GetPreciseAngle`,
`InteractAngle` / `InteractPrecision`). While Lua (`uevrmenus.lua`, only while seated = MovementMode 5 off-ladder) sends
custom event `HellraiserHeadAim`, that transform is swapped for the head pose during the candidate scan
(`OnLocal_CheckInteractionComponents`, RVA 0x58831A0) and the focus check, then restored. Prologues verified.
The scan and the focus check also require the prompt ON SCREEN (RVA 0x5880070: ProjectWorldLocationToScreen through
the real game camera, which stays put while seated): during a head swap that test becomes "within
`InteractHeadConeDeg` (40) of the head direction". (Installed inside the TelekinesisLeftHand block.)

## Config: `<profile>\plugins\HellraiserAimFix.txt` (optional)

`Enabled`, `Mode` (0 log / 1 override), `Debug` (default 1 for now: logs every fire trace), `RedirectSphereTraces`,
`StartTolerance`, `FireAbilityClass`, `RangedWeaponClass`, `MuzzleSocket`, `BarrelAxis`, `MuzzleForwardOffset`,
`PitchOffset`, `YawOffset`, `MeleeFollow`, `MeleeTargetWindow`, `MeleeFollowSpread`, `MeleeFollowExtraReach`, `MeleeFromWeapon`, `MeleeTargetingClasses`, `DiscoverMelee`,
`TelekinesisLeftHand`, `LeftAimMaxAge`, `TelekinesisTickVtableIndex`, `TelekinesisCameraCallers`, `InteractHeadAim`, `InteractHeadConeDeg`, `RVA_*`
(incl. `RVA_TelekinesisUpdate`, `RVA_TelekinesisAimRay`, `RVA_InteractScan`, `RVA_InteractCheckCurrent`, `RVA_InteractOnScreen`).

## Build

`_build.bat` (VS 2026, offline FetchContent from the Cronos `_deps`, glm from OW2AimFixProject, UEVR headers from
`D:\UEVR Dev\UEVR-PureDark-AFW-Joey-Merged-updated\include`). Output `build\Release\HellraiserAimFix.dll` →
profile `plugins\`. Fully restart the game after deploying.
