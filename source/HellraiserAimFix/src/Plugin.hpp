#pragma once

#include <windows.h>
#include <intrin.h>

#include <memory>
#include <filesystem>
#include <string>
#include <mutex>
#include <unordered_map>
#include <vector>

#include "uevr/API.hpp"
// uevr_plugin_required_version (exported by uevr/Plugin.hpp) reports the header's minor version, and UEVR unloads
// plugins that ask for a newer minor than it has. The merged headers are 2.41 (owned FName, controller input tail),
// official UEVR is 2.39, and this plugin uses nothing newer than 2.39 - so ask for 2.39.
#undef UEVR_PLUGIN_VERSION_MINOR
#define UEVR_PLUGIN_VERSION_MINOR 39
#include "uevr/Plugin.hpp"

// UE5 FVector / FRotator (doubles)
struct Vec3 { double x{}, y{}, z{}; };
struct Rot3 { double pitch{}, yaw{}, roll{}; };

class HellraiserAimFixPlugin;
extern std::unique_ptr<HellraiserAimFixPlugin> g_plugin;

// Weapon aim fix for Hellraiser (Revival Demo, UE 5.6, no PDB) under UEVR: shots follow the VR gun barrel.
//
// How the game shoots (MCP hook trace 2026-10-07, Colt 1911): the Blueprint gameplay ability GA_Fire_C
// (C++ parent PlayerAbility_FireBase) calls GetAllTraceEndPositions(Weapon, AimTraceLength, MaxTraceLength)
// for the per-bullet end points (camera aim + spread) and then traces with the Kismet nodes
// "Line Trace By Channel" (UKismetSystemLibrary::LineTraceSingle) and "Multi Sphere Trace By Channel"
// (UKismetSystemLibrary::SphereTraceMulti). We hook both natives plus their Blueprint exec thunks: the thunk
// hook reads the FFrame to learn which Blueprint object is calling (only a PlayerAbility_FireBase instance
// is touched), the native hook rewrites Start/End.
//
// Override: a trace that starts at the camera (within StartTolerance) is moved to the muzzle and its
// direction is rotated by the camera-forward -> barrel rotation, so the game's own bullet spread survives.
// Traces starting elsewhere (follow-ups from a hit point) are left alone. Mode=0 only logs.
class HellraiserAimFixPlugin : public uevr::Plugin {
public:
    HellraiserAimFixPlugin() = default;
    virtual ~HellraiserAimFixPlugin() = default;

    void on_initialize() override;
    void on_pre_engine_tick(uevr::API::UGameEngine* engine, float delta) override;
    void on_custom_event(const char* event_name, const char* event_data) override;

    struct Config {
        bool enabled{true};
        int mode{1};                         // 0 = log only, 1 = override
        bool debug{true};                    // first builds: log every fire-ability trace (turn off once confirmed)
        bool redirect_sphere_traces{true};
        double start_tolerance{60.0};        // cm: trace start must be this close to the camera to be redirected
        double max_angle_from_aim{30.0};     // deg: and point within this of camera forward (bullet spread is ~2 deg)
        std::wstring fire_ability_class{L"Class /Script/Project.PlayerAbility_FireBase"};
        std::wstring ranged_weapon_class{L"Class /Script/Project.CoreRangedWeapon"};
        std::wstring muzzle_socket{L"MuzzleFlashSocket"};
        std::wstring barrel_axis{L"+Y"};     // axis of the weapon's root mesh along the barrel (Colt: +Y)
        double muzzle_forward_offset{0.0};
        double pitch_offset_deg{0.0};        // + = aim up
        double yaw_offset_deg{0.0};          // + = aim right
        // RVAs (module base relative), build 2026-10-07. Natives are verified against the thunks.
        uintptr_t rva_exec_line_trace_single{0x4195C40};
        uintptr_t rva_line_trace_single{0x414F8C0};
        uintptr_t rva_exec_sphere_trace_multi{0x41B7690};
        uintptr_t rva_sphere_trace_multi{0x415A310};
        // Melee: the swing's targeting fan (Kismet SphereTraceSingle from these Blueprint classes) follows the
        // enemy physical_melee.lua reports via custom event "HellraiserMeleeTarget" for melee_target_window s.
        bool melee_follow{true};
        double melee_target_window{0.6};
        // A followed fan is narrowed onto the target: each ray's direction = lerp(target dir, game ray rotated to the
        // target, spread) (0 = every ray on the camera -> target line, 1 = the game's full fan). Lua can send its own
        // spread as a 4th value of "HellraiserMeleeTarget". Rays reach at least melee_follow_extra_reach cm past it.
        double melee_follow_spread{0.35};
        double melee_follow_extra_reach{30.0};
        // If Lua also sends the weapon point just before contact (values 5-7, "x,y,z,spread,sx,sy,sz"), the followed
        // fan's rays start there instead of at the camera, each aimed at the same spot around the target the
        // narrowed camera ray would reach; the pawn and its equipment are added to the rays' ActorsToIgnore.
        bool melee_from_weapon{true};
        std::wstring melee_targeting_classes{L"DoTargeting_Fanout_C"};
        // Melee discovery (log only): bursts of SphereTraceSingle from non-fire callers
        bool discover_melee{true};
        int discover_melee_max_lines{5000};
        uintptr_t rva_exec_sphere_trace_single{0x41B83E0};
        uintptr_t rva_sphere_trace_single{0x415AA70};
        // Genesis cube telekinesis: the native targeting (COMP_TelekinesisTargeting) aims from the left controller
        // pose Lua sends as custom event "HellraiserLeftAim" ("x,y,z,pitch,yaw,roll"), if it is at most
        // left_aim_max_age old. The targeting update is resolved from the component's vtable (slot below, a thunk
        // that tail-jumps to it); rva_telekinesis_update is the fallback (build 2026-10-07).
        bool telekinesis_left_hand{true};
        double left_aim_max_age{0.25};
        int telekinesis_tick_vtable_index{128};
        uintptr_t rva_telekinesis_update{0x57A0B00};
        // The targeting's aim ray (cached per frame) = PlayerController deprojection of the SCREEN CENTRE
        // (GetViewportSize + DeprojectScreenPositionToWorld) - the crosshair. Its world location/direction outputs
        // are replaced by the left controller pose. Build 2026-10-07; prologue bytes are verified before hooking.
        uintptr_t rva_telekinesis_aim_ray{0x579D370};
        // Blueprint classes whose camera queries (K2_GetComponentLocation / GetForwardVector of the pawn's
        // FPCameraActor) get the left controller pose: the telekinesis puzzle cubes (CalculateTargetCoordinateLine/
        // Circle: camera ray x plane) and the puzzle ability (drop angle). Thrown objects are re-aimed in Lua
        // (genesis_cube.lua) - their Blueprint never queries the camera this way.
        std::wstring telekinesis_camera_callers{L"TASK_TelekinesisCube_BaseActor,GA_TelekinesisPuzzle_C"};
        // Seated interactions (chair puzzle): InteractManager picks the focused interactable from the pawn's
        // FPCameraActor transform (raw ComponentToWorld). While Lua sends a fresh head pose (custom event
        // "HellraiserHeadAim", only while seated), that transform is swapped for the head pose during the candidate
        // scan (OnLocal_CheckInteractionComponents) and the focus check (CheckCurrentInteraction). Build 2026-10-07
        // RVAs, prologue bytes verified before hooking.
        bool interact_head_aim{true};
        uintptr_t rva_interact_scan{0x58831A0};
        uintptr_t rva_interact_check_current{0x5869990};
        // InteractManager's "prompt on screen" test (ProjectWorldLocationToScreen through the real game camera, which
        // stays put while seated): during a head swap it becomes "within this cone of the head direction"
        uintptr_t rva_interact_on_screen{0x5880070};
        double interact_head_cone_deg{40.0};
        int axis_index{1};
        double axis_sign{1.0};
    };

    // Shot context captured by the exec-thunk hook (game thread) for the native hook it wraps
    struct ShotContext {
        bool valid{false};          // caller is the player's fire ability and we have muzzle + camera
        bool from_fire_ability{false};
        uevr::API::UObject* caller{};
        uevr::API::UObject* weapon_actor{};
        Vec3 muzzle{};
        Vec3 barrel{};
        Vec3 cam_loc{};
        Vec3 cam_fwd{};
    };

private:
    void load_config(const std::filesystem::path& file);
    void install_hooks();
    bool capture_context(void* stack, ShotContext& ctx);
    bool redirect(const ShotContext& ctx, Vec3* start, Vec3* end, const char* what);

    using ExecFn = void (*)(uevr::API::UObject* ctx, void* stack, void* result);
    using LineTraceSingleFn = bool (*)(uevr::API::UObject* ctx, Vec3* start, Vec3* end, uint32_t channel,
        bool complex, void* ignore, uint32_t draw_debug, void* out_hit, bool ignore_self,
        void* trace_color, void* trace_hit_color, float draw_time);
    using SphereTraceMultiFn = bool (*)(uevr::API::UObject* ctx, Vec3* start, Vec3* end, float radius,
        uint32_t channel, bool complex, void* ignore, uint32_t draw_debug, void* out_hits, bool ignore_self,
        void* trace_color, void* trace_hit_color, float draw_time);

    static void on_exec_line_trace_single(uevr::API::UObject* ctx, void* stack, void* result);
    static void on_exec_sphere_trace_multi(uevr::API::UObject* ctx, void* stack, void* result);
    static bool on_line_trace_single(uevr::API::UObject* ctx, Vec3* start, Vec3* end, uint32_t channel,
        bool complex, void* ignore, uint32_t draw_debug, void* out_hit, bool ignore_self,
        void* trace_color, void* trace_hit_color, float draw_time);
    static bool on_sphere_trace_multi(uevr::API::UObject* ctx, Vec3* start, Vec3* end, float radius,
        uint32_t channel, bool complex, void* ignore, uint32_t draw_debug, void* out_hits, bool ignore_self,
        void* trace_color, void* trace_hit_color, float draw_time);

    using SphereTraceSingleFn = bool (*)(uevr::API::UObject* ctx, Vec3* start, Vec3* end, float radius,
        uint32_t channel, bool complex, void* ignore, uint32_t draw_debug, void* out_hit, bool ignore_self,
        void* trace_color, void* trace_hit_color, float draw_time);
    static void on_exec_sphere_trace_single(uevr::API::UObject* ctx, void* stack, void* result);
    static bool on_sphere_trace_single(uevr::API::UObject* ctx, Vec3* start, Vec3* end, float radius,
        uint32_t channel, bool complex, void* ignore, uint32_t draw_debug, void* out_hit, bool ignore_self,
        void* trace_color, void* trace_hit_color, float draw_time);
    // What a fan trace hit (discovery log): owning actor / component / bone of the FHitResult
    struct HitInfo { bool valid{false}; std::wstring actor, component, bone; Vec3 impact{}; bool start_penetrating{false}; };
    HitInfo read_hit(const void* out_hit);
    void log_melee_trace(uevr::API::UObject* caller, const Vec3& start, const Vec3& end, float radius, uint32_t channel, bool hit, bool followed,
        const void* out_hit);
    void update_melee_burst(uevr::API::UObject* caller);
    bool is_melee_targeting(uevr::API::UObject* caller);
    Vec3 m_melee_target{};
    double m_melee_target_time{-1.0};
    double m_melee_target_spread{-1.0}; // < 0 = melee_follow_spread
    Vec3 m_melee_target_start{};
    bool m_melee_target_has_start{false};
    bool m_burst_logged{false};
    bool m_burst_follow{false};
    Vec3 m_burst_follow_dir{};
    double m_burst_follow_dist{0.0};
    double m_burst_follow_spread{1.0};
    bool m_burst_from_weapon{false};
    Vec3 m_burst_start{};
    uevr::API::UObject* m_burst_pawn{};
    uevr::API::UObject* m_burst_equipment{};
    uevr::API::UObject* m_melee_targeting_class_cache{};
    bool m_melee_targeting_class_match{false};
    inline static ExecFn m_orig_exec_sts{};
    inline static SphereTraceSingleFn m_orig_sts{};
    void log_melee_line(const Vec3& start, const Vec3& end, float radius, uint32_t channel, bool hit, bool followed, const HitInfo& info);
    struct BufferedTrace { Vec3 start, end; float radius; uint32_t channel; bool hit; bool followed; HitInfo info; };
    // FHitResult field offsets, resolved once by reflection (fallbacks = UE 5.6 layout read live 2026-10-23)
    bool m_hit_offsets_resolved{false};
    int m_hit_impact_point_offset{40};
    int m_hit_flags_offset{173};
    int m_hit_component_offset{216};
    int m_hit_bone_offset{240};
    std::vector<BufferedTrace> m_burst_buffer;
    uevr::API::UObject* m_burst_caller{};
    int m_burst_count{0};
    std::unordered_map<std::wstring, uint32_t> m_sts_callers;
    double m_last_caller_log{0.0};
    double m_melee_burst_time{-1.0};
    int m_melee_burst_index{0};
    int m_melee_lines{0};
    Vec3 m_burst_cam{}, m_burst_fwd{}, m_burst_weapon{};

    // Telekinesis targeting from the left hand
    using TelekinesisUpdateFn = void (*)(void* self);
    static void on_telekinesis_update(void* self);
    uintptr_t resolve_telekinesis_update(uintptr_t base);
    inline static TelekinesisUpdateFn m_orig_tk_update{};
    using TelekinesisAimRayFn = bool (*)(void* self, double* screen, double* center, Vec3* world_loc, Vec3* world_dir);
    static bool on_telekinesis_aim_ray(void* self, double* screen, double* center, Vec3* world_loc, Vec3* world_dir);
    inline static TelekinesisAimRayFn m_orig_tk_aim_ray{};
    bool get_left_aim(Vec3& loc, Rot3& rot);
    // Camera queries from the telekinesis puzzle (SceneComponent Blueprint thunks)
    std::mutex m_class_cache_mutex; // the SceneComponent thunks can also run on animation worker threads
    std::unordered_map<void*, bool> m_cac_class_cache;     // class -> is a ChildActorComponent
    std::unordered_map<void*, bool> m_tk_caller_cache;     // class -> in telekinesis_camera_callers
    bool class_chain_has(std::unordered_map<void*, bool>& cache, uevr::API::UObject* obj, const std::wstring& name);
    // `names` = comma-separated list (list_contains)
    bool class_chain_has_any(std::unordered_map<void*, bool>& cache, uevr::API::UObject* obj, const std::wstring& names);
    std::unordered_map<std::wstring, bool> m_camera_query_logged;
    static void on_exec_get_component_location(uevr::API::UObject* ctx, void* stack, void* result);
    static void on_exec_get_forward_vector(uevr::API::UObject* ctx, void* stack, void* result);
    bool telekinesis_camera_query(uevr::API::UObject* ctx, void* stack, Vec3& loc, Rot3& rot, const char* fn);
    inline static ExecFn m_orig_exec_get_loc{};
    inline static ExecFn m_orig_exec_get_fwd{};
    uint32_t m_tk_camera_queries{0};
    uint32_t m_tk_rays{0};

    // Seated interactions aimed with the head
    using InteractScanFn = void (*)(void* self);
    using InteractCheckFn = bool (*)(void* self);
    static void on_interact_scan(void* self);
    static bool on_interact_check_current(void* self);
    inline static InteractScanFn m_orig_interact_scan{};
    inline static InteractCheckFn m_orig_interact_check{};
    struct CameraSwap { uint8_t* comp{}; uint8_t saved[56]{}; };
    bool begin_head_swap(CameraSwap& s);  // false = nothing swapped
    void end_head_swap(CameraSwap& s);
    int m_head_swap_depth{0};
    using InteractOnScreenFn = bool (*)(void* self, void* interact_comp);
    static bool on_interact_on_screen(void* self, void* interact_comp);
    inline static InteractOnScreenFn m_orig_interact_on_screen{};
    bool m_head_swap_active{false};   // the outermost swap is in place (head pose below is what was swapped in)
    Vec3 m_head_swap_loc{};
    Rot3 m_head_swap_rot{};
    Vec3 m_head_aim_loc{};
    Rot3 m_head_aim_rot{};
    double m_head_aim_time{-1.0};
    uint32_t m_head_swaps{0};
    Vec3 m_left_aim_loc{};
    Rot3 m_left_aim_rot{};
    double m_left_aim_time{-1.0};
    uint32_t m_tk_updates{0};
    uint32_t m_tk_redirects{0};

    inline static ExecFn m_orig_exec_lts{};
    inline static ExecFn m_orig_exec_stm{};
    inline static LineTraceSingleFn m_orig_lts{};
    inline static SphereTraceMultiFn m_orig_stm{};

    Config m_cfg{};
    bool m_hooks_ok{false};
    uevr::API::UClass* m_fire_ability_class{};
    uevr::API::UClass* m_ranged_weapon_class{};

    mutable std::mutex m_mutex;
    double m_last_debug_log{0.0};
    uint32_t m_fire_traces{0};
    uint32_t m_overrides{0};
    uint32_t m_skipped_far{0};
    uint32_t m_skipped_angle{0};
    uint32_t m_no_muzzle{0};
};
