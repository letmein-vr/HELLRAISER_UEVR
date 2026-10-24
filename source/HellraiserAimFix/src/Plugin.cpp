#include <fstream>
#include <string>
#include <filesystem>
#include <cmath>
#include <chrono>
#include <algorithm>
#include <iterator>
#include <cstring>
#include <cstdio>

#include <utility/Module.hpp>

#include <bddisasm.h>

#include "Plugin.hpp"

using namespace uevr;

std::unique_ptr<HellraiserAimFixPlugin> g_plugin = std::make_unique<HellraiserAimFixPlugin>();

namespace {

// FFrame (UE 5.6 stock layout, same as Townfall): FOutputDevice base, Node @0x10, Object @0x18, Code @0x20.
constexpr size_t FFRAME_NODE = 0x10;
constexpr size_t FFRAME_OBJECT = 0x18;

// Shot context of the trace node currently executing on this thread (set by the exec hooks around the
// original thunk, read by the native hooks it calls).
thread_local HellraiserAimFixPlugin::ShotContext t_ctx{};
// Blueprint object calling the SphereTraceSingle node currently executing on this thread (melee discovery)
thread_local API::UObject* t_sts_caller{};

double now_seconds() {
    using clock = std::chrono::steady_clock;
    static const auto t0 = clock::now();
    return std::chrono::duration<double>(clock::now() - t0).count();
}

double deg2rad(double d) { return d * 3.14159265358979323846 / 180.0; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
double length(const Vec3& v) { return std::sqrt(dot(v, v)); }
Vec3 sub(const Vec3& a, const Vec3& b) { return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 add_scaled(const Vec3& a, const Vec3& d, double s) { return Vec3{a.x + d.x * s, a.y + d.y * s, a.z + d.z * s}; }

Vec3 normalize(const Vec3& v) {
    const double len = length(v);
    if (len < 1e-9) return Vec3{1.0, 0.0, 0.0};
    return Vec3{v.x / len, v.y / len, v.z / len};
}

Vec3 cross(const Vec3& a, const Vec3& b) {
    return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

// Rodrigues rotation of v around unit axis k by angle (radians)
Vec3 rotate_axis(const Vec3& v, const Vec3& k, double angle) {
    const double c = std::cos(angle), s = std::sin(angle);
    const Vec3 kxv = cross(k, v);
    const double kdv = dot(k, v);
    return Vec3{
        v.x * c + kxv.x * s + k.x * kdv * (1.0 - c),
        v.y * c + kxv.y * s + k.y * kdv * (1.0 - c),
        v.z * c + kxv.z * s + k.z * kdv * (1.0 - c),
    };
}

// Rotate v by the rotation that takes unit vector `from` onto unit vector `to`.
Vec3 rotate_from_to(const Vec3& v, const Vec3& from, const Vec3& to) {
    const Vec3 axis = cross(from, to);
    const double s = length(axis);
    const double c = std::clamp(dot(from, to), -1.0, 1.0);
    if (s < 1e-9) return c > 0.0 ? v : Vec3{-v.x, -v.y, -v.z};
    return rotate_axis(v, Vec3{axis.x / s, axis.y / s, axis.z / s}, std::atan2(s, c));
}

Vec3 rotator_forward(const Rot3& r) {
    const double p = deg2rad(r.pitch), y = deg2rad(r.yaw);
    const double cp = std::cos(p);
    return Vec3{cp * std::cos(y), cp * std::sin(y), std::sin(p)};
}

bool near_zero(const Vec3& v) {
    return std::fabs(v.x) + std::fabs(v.y) + std::fabs(v.z) < 1.0;
}

std::string trim(std::string s) {
    const auto b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    const auto e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

std::string narrow(const std::wstring& w) {
    std::string out;
    out.reserve(w.size());
    for (auto c : w) out.push_back(c < 128 ? (char)c : '?');
    return out;
}

// True if `name` is one of the comma-separated entries of `list`.
bool list_contains(const std::wstring& list, const std::wstring& name) {
    if (name.empty()) return false;
    size_t pos = 0;
    while (pos <= list.size()) {
        const auto comma = list.find(L',', pos);
        auto item = list.substr(pos, comma == std::wstring::npos ? std::wstring::npos : comma - pos);
        item.erase(0, item.find_first_not_of(L' '));
        item.erase(item.find_last_not_of(L' ') + 1);
        if (!item.empty() && item == name) return true;
        if (comma == std::wstring::npos) break;
        pos = comma + 1;
    }
    return false;
}

// Null-checked object property read (API::UObject::get_property dereferences blindly).
API::UObject* get_object_prop(API::UObject* obj, std::wstring_view name) {
    if (obj == nullptr) return nullptr;
    auto data = obj->get_property_data<API::UObject*>(name);
    return data != nullptr ? *data : nullptr;
}

std::wstring object_name(API::UObject* obj) {
    if (obj == nullptr) return L"<null>";
    auto fname = obj->get_fname();
    return fname != nullptr ? fname->to_string() : L"<?>";
}

// True if the function contains a direct call (E8) to `target` before its first RET.
bool thunk_calls(uintptr_t fn, uintptr_t target) {
    uintptr_t ip = fn;
    const uintptr_t end = ip + 0x1000;
    while (ip < end) {
        INSTRUX ix{};
        if (!ND_SUCCESS(NdDecodeEx(&ix, (const ND_UINT8*)ip, ND_MAX_INSTRUCTION_LENGTH, ND_CODE_64, ND_DATA_64))) return false;
        if (ix.Instruction == ND_INS_CALLNR && ip + ix.Length + (intptr_t)(int32_t)ix.RelativeOffset == target) return true;
        if (ix.Instruction == ND_INS_RETN) return false;
        ip += ix.Length;
    }
    return false;
}

// Fallback for a changed build: the native call inside a bool-returning Kismet exec thunk is the direct
// call whose result is stored to memory from AL within the next 3 instructions (`mov byte ptr [r13], al`).
// NOT "the last call before RET" (OW2's heuristic): here the last calls free the ActorsToIgnore copies.
uintptr_t find_bool_result_call(uintptr_t thunk) {
    uintptr_t ip = thunk;
    const uintptr_t end = ip + 0x1000;
    while (ip < end) {
        INSTRUX ix{};
        if (!ND_SUCCESS(NdDecodeEx(&ix, (const ND_UINT8*)ip, ND_MAX_INSTRUCTION_LENGTH, ND_CODE_64, ND_DATA_64))) return 0;
        if (ix.Instruction == ND_INS_RETN) return 0;
        if (ix.Instruction == ND_INS_CALLNR) {
            const uintptr_t target = ip + ix.Length + (intptr_t)(int32_t)ix.RelativeOffset;
            uintptr_t ip2 = ip + ix.Length;
            for (int k = 0; k < 3; ++k) {
                INSTRUX n{};
                if (!ND_SUCCESS(NdDecodeEx(&n, (const ND_UINT8*)ip2, ND_MAX_INSTRUCTION_LENGTH, ND_CODE_64, ND_DATA_64))) break;
                if (n.Instruction == ND_INS_MOV && n.OperandsCount >= 2 &&
                    n.Operands[0].Type == ND_OP_MEM && n.Operands[0].Size == 1 &&
                    n.Operands[1].Type == ND_OP_REG && n.Operands[1].Info.Register.Type == ND_REG_GPR &&
                    n.Operands[1].Info.Register.Reg == NDR_AL && n.Operands[1].Size == 1) {
                    return target;
                }
                if (n.Instruction == ND_INS_CALLNR || n.Instruction == ND_INS_RETN) break;
                ip2 += n.Length;
            }
        }
        ip += ix.Length;
    }
    return 0;
}

bool install_inline_hook(uintptr_t target, void* dest, void** orig, const char* name) {
    void* original = nullptr;
    const auto id = API::get()->param()->functions->register_inline_hook((void*)target, dest, &original);
    if (id < 0 || original == nullptr) {
        API::get()->log_error("HellraiserAimFix: inline hook failed for %s at 0x%p", name, (void*)target);
        return false;
    }
    *orig = original;
    API::get()->log_info("HellraiserAimFix: hooked %s at 0x%p (RVA 0x%llX, hook id %d)", name, (void*)target,
        (unsigned long long)(target - (uintptr_t)utility::get_executable()), id);
    return true;
}

// The engine-registered native thunk of Class::Function, or `fallback` if not found.
uintptr_t ufunction_thunk(const wchar_t* class_name, const wchar_t* fn_name, uintptr_t fallback) {
    if (auto klass = API::get()->find_uobject<API::UClass>(class_name); klass != nullptr) {
        if (auto fn = klass->find_function(fn_name); fn != nullptr && fn->get_native_function() != nullptr) {
            return (uintptr_t)fn->get_native_function();
        }
    }
    return fallback;
}

// Resolve + verify thunk/native for one Kismet trace function.
bool resolve_pair(const wchar_t* fn_name, uintptr_t base, uintptr_t rva_exec, uintptr_t rva_native,
                  uintptr_t& exec, uintptr_t& native) {
    exec = ufunction_thunk(L"Class /Script/Engine.KismetSystemLibrary", fn_name, base + rva_exec);
    native = base + rva_native;
    if (thunk_calls(exec, native)) return true;
    const auto found = find_bool_result_call(exec);
    if (found != 0) {
        API::get()->log_info("HellraiserAimFix: %ls native not at configured RVA 0x%llX; decoded RVA 0x%llX from the thunk",
            fn_name, (unsigned long long)rva_native, (unsigned long long)(found - base));
        native = found;
        return true;
    }
    API::get()->log_error("HellraiserAimFix: could not resolve native %ls (thunk 0x%p) - game build changed?", fn_name, (void*)exec);
    return false;
}

void parse_axis(HellraiserAimFixPlugin::Config& c) {
    const auto& axis = c.barrel_axis;
    c.axis_sign = (!axis.empty() && axis[0] == L'-') ? -1.0 : 1.0;
    const wchar_t letter = axis.empty() ? L'Y' : (wchar_t)towupper(axis.back());
    c.axis_index = letter == L'X' ? 0 : (letter == L'Z' ? 2 : 1);
}

// TArray<AActor*> as the engine reads it (const&): {Data, Num, Max}
struct ActorArray { API::UObject** data; int32_t num; int32_t max; };

} // namespace

// ------------------------------------------------------------------------------------------------

void HellraiserAimFixPlugin::on_initialize() {
    API::get()->log_info("HellraiserAimFix: on_initialize");
    load_config(API::get()->get_persistent_dir() / "plugins" / "HellraiserAimFix.txt");
    parse_axis(m_cfg);

    API::get()->log_info("HellraiserAimFix: config enabled=%d mode=%d debug=%d spheres=%d startTol=%.0f socket=%s axis=%s fwdOff=%.1f pitch=%.2f yaw=%.2f",
        (int)m_cfg.enabled, m_cfg.mode, (int)m_cfg.debug, (int)m_cfg.redirect_sphere_traces, m_cfg.start_tolerance,
        narrow(m_cfg.muzzle_socket).c_str(), narrow(m_cfg.barrel_axis).c_str(), m_cfg.muzzle_forward_offset,
        m_cfg.pitch_offset_deg, m_cfg.yaw_offset_deg);

    if (!m_cfg.enabled) {
        API::get()->log_info("HellraiserAimFix: disabled by config");
        return;
    }
    install_hooks();
}

void HellraiserAimFixPlugin::install_hooks() {
    const auto base = (uintptr_t)utility::get_executable();

    uintptr_t exec{}, native{};
    if (resolve_pair(L"LineTraceSingle", base, m_cfg.rva_exec_line_trace_single, m_cfg.rva_line_trace_single, exec, native) &&
        install_inline_hook(native, (void*)&on_line_trace_single, (void**)&m_orig_lts, "LineTraceSingle") &&
        install_inline_hook(exec, (void*)&on_exec_line_trace_single, (void**)&m_orig_exec_lts, "execLineTraceSingle")) {
        m_hooks_ok = true;
    }
    if (m_cfg.redirect_sphere_traces &&
        resolve_pair(L"SphereTraceMulti", base, m_cfg.rva_exec_sphere_trace_multi, m_cfg.rva_sphere_trace_multi, exec, native) &&
        install_inline_hook(native, (void*)&on_sphere_trace_multi, (void**)&m_orig_stm, "SphereTraceMulti") &&
        install_inline_hook(exec, (void*)&on_exec_sphere_trace_multi, (void**)&m_orig_exec_stm, "execSphereTraceMulti")) {
        m_hooks_ok = true;
    }
    if ((m_cfg.discover_melee || m_cfg.melee_follow) &&
        resolve_pair(L"SphereTraceSingle", base, m_cfg.rva_exec_sphere_trace_single, m_cfg.rva_sphere_trace_single, exec, native) &&
        install_inline_hook(native, (void*)&on_sphere_trace_single, (void**)&m_orig_sts, "SphereTraceSingle") &&
        install_inline_hook(exec, (void*)&on_exec_sphere_trace_single, (void**)&m_orig_exec_sts, "execSphereTraceSingle")) {
        API::get()->log_info("HellraiserAimFix: melee discovery on (logs SphereTraceSingle from gameplay abilities)");
    }
    if (m_cfg.telekinesis_left_hand) {
        const auto update = resolve_telekinesis_update(base);
        if (update != 0 && install_inline_hook(update, (void*)&on_telekinesis_update, (void**)&m_orig_tk_update, "TelekinesisTargeting update")) {
            API::get()->log_info("HellraiserAimFix: telekinesis targeting follows the left hand (custom event HellraiserLeftAim)");
        }
        // camera queries from the telekinesis puzzle (SceneComponent Blueprint thunks)
        struct { const wchar_t* fn; void* hook; void** orig; const char* name; } k_scene_hooks[] = {
            {L"K2_GetComponentLocation", (void*)&on_exec_get_component_location, (void**)&m_orig_exec_get_loc, "execK2_GetComponentLocation"},
            {L"GetForwardVector", (void*)&on_exec_get_forward_vector, (void**)&m_orig_exec_get_fwd, "execGetForwardVector"},
        };
        for (const auto& h : k_scene_hooks) {
            const auto thunk = ufunction_thunk(L"Class /Script/Engine.SceneComponent", h.fn, 0);
            if (thunk == 0) { API::get()->log_error("HellraiserAimFix: SceneComponent.%ls not found", h.fn); continue; }
            install_inline_hook(thunk, h.hook, h.orig, h.name);
        }
        // seated interactions aimed with the head
        if (m_cfg.interact_head_aim) {
            static const uint8_t k_scan_prologue[] = {0x40, 0x53, 0x48, 0x83, 0xEC, 0x20, 0x48, 0x8B, 0xD9, 0xE8};
            static const uint8_t k_check_prologue[] = {0x48, 0x8B, 0xC4, 0x48, 0x89, 0x58, 0x10, 0x57, 0x48, 0x81, 0xEC, 0xC0, 0x00, 0x00, 0x00};
            static const uint8_t k_on_screen_prologue[] = {0x48, 0x89, 0x5C, 0x24, 0x08, 0x48, 0x89, 0x74, 0x24, 0x10, 0x57, 0x48, 0x81, 0xEC, 0x80, 0x00, 0x00, 0x00};
            const auto scan = base + m_cfg.rva_interact_scan;
            const auto check = base + m_cfg.rva_interact_check_current;
            const auto on_screen = base + m_cfg.rva_interact_on_screen;
            if (std::memcmp((const void*)scan, k_scan_prologue, sizeof(k_scan_prologue)) != 0 ||
                std::memcmp((const void*)check, k_check_prologue, sizeof(k_check_prologue)) != 0 ||
                std::memcmp((const void*)on_screen, k_on_screen_prologue, sizeof(k_on_screen_prologue)) != 0) {
                API::get()->log_error("HellraiserAimFix: InteractManager functions not found at RVA 0x%llX / 0x%llX / 0x%llX (game build changed?) - seated interactions keep the camera aim",
                    (unsigned long long)m_cfg.rva_interact_scan, (unsigned long long)m_cfg.rva_interact_check_current,
                    (unsigned long long)m_cfg.rva_interact_on_screen);
            } else {
                install_inline_hook(scan, (void*)&on_interact_scan, (void**)&m_orig_interact_scan, "InteractManager::OnLocal_CheckInteractionComponents");
                install_inline_hook(check, (void*)&on_interact_check_current, (void**)&m_orig_interact_check, "InteractManager::CheckCurrentInteraction");
                install_inline_hook(on_screen, (void*)&on_interact_on_screen, (void**)&m_orig_interact_on_screen, "InteractManager on-screen check");
            }
        }
        // aim ray: verify the prologue (mov [rsp+18h],rbx; push rbp/rsi/rdi; sub rsp,90h; cmp byte [rcx+170h],0)
        static const uint8_t k_ray_prologue[] = {0x48, 0x89, 0x5C, 0x24, 0x18, 0x55, 0x56, 0x57, 0x48, 0x81, 0xEC, 0x90, 0x00, 0x00, 0x00,
                                                 0x80, 0xB9, 0x70, 0x01, 0x00, 0x00, 0x00};
        const auto ray = base + m_cfg.rva_telekinesis_aim_ray;
        if (std::memcmp((const void*)ray, k_ray_prologue, sizeof(k_ray_prologue)) != 0) {
            API::get()->log_error("HellraiserAimFix: telekinesis aim ray not found at RVA 0x%llX (game build changed?) - crosshair aim stays",
                (unsigned long long)m_cfg.rva_telekinesis_aim_ray);
        } else {
            install_inline_hook(ray, (void*)&on_telekinesis_aim_ray, (void**)&m_orig_tk_aim_ray, "TelekinesisTargeting aim ray");
        }
    }
    API::get()->log_info("HellraiserAimFix: hooks %s", m_hooks_ok ? "installed" : "NOT installed");
}

// ------------------------------------------------------------------------------------------------
// Telekinesis (Genesis cube abilities): targeting is native. COMP_TelekinesisTargeting's tick override
// (vtable slot 128, RVA 0x57982F0 on build 2026-10-07) checks its six refs and tail-jumps to the targeting
// update (RVA 0x57A0B00). Everything in there aims from PlayerCameraActorRef (+0x110, the pawn's FPCameraActor
// ChildActorComponent) and its ChildActor's RootComponent, read RAW from their ComponentToWorld (quat @+0x1E0,
// translation @+0x200, doubles) - no virtual call to intercept (disassembly 2026-10-08). So for the duration of
// the update both transforms are swapped for the left controller pose from Lua and restored afterwards.

namespace {
constexpr size_t TK_CAMERA_REF = 0x110;         // COMP_TelekinesisTargeting::PlayerCameraActorRef
constexpr size_t CAC_CHILD_ACTOR = 0x248;       // UChildActorComponent::ChildActor
constexpr size_t ACTOR_ROOT = 0x1B8;            // AActor::RootComponent
constexpr size_t SC_C2W_ROT = 0x1E0;            // USceneComponent::ComponentToWorld.Rotation (FQuat, doubles)
constexpr size_t SC_C2W_LOC = 0x200;            // USceneComponent::ComponentToWorld.Translation (FVector)

struct Quat4 { double x, y, z, w; };

// FRotator::Quaternion (UE)
Quat4 rotator_to_quat(const Rot3& r) {
    const double h = 3.14159265358979323846 / 360.0;
    const double sp = std::sin(r.pitch * h), cp = std::cos(r.pitch * h);
    const double sy = std::sin(r.yaw * h), cy = std::cos(r.yaw * h);
    const double sr = std::sin(r.roll * h), cr = std::cos(r.roll * h);
    return Quat4{
        cr * sp * sy - sr * cp * cy,
        -cr * sp * cy - sr * cp * sy,
        cr * cp * sy - sr * sp * cy,
        cr * cp * cy + sr * sp * sy,
    };
}

struct SavedTransform { uint8_t* comp; Quat4 rot; Vec3 loc; };

bool readable_object(const void* p) {
    return p != nullptr && !IsBadReadPtr(p, 0x260);
}
} // namespace

uintptr_t HellraiserAimFixPlugin::resolve_telekinesis_update(uintptr_t base) {
    const uintptr_t fallback = base + m_cfg.rva_telekinesis_update;
    auto cdo = API::get()->find_uobject<API::UObject>(L"COMP_TelekinesisTargeting /Script/Project.Default__COMP_TelekinesisTargeting");
    if (cdo == nullptr) {
        API::get()->log_info("HellraiserAimFix: COMP_TelekinesisTargeting CDO not found; using RVA 0x%llX", (unsigned long long)m_cfg.rva_telekinesis_update);
        return fallback;
    }
    const auto vtable = *(const uintptr_t* const*)cdo;
    const uintptr_t slot = vtable[m_cfg.telekinesis_tick_vtable_index];
    // the slot is a short guard that ends in `jmp update`
    uintptr_t ip = slot;
    for (int i = 0; i < 64; ++i) {
        INSTRUX ix{};
        if (!ND_SUCCESS(NdDecodeEx(&ix, (const ND_UINT8*)ip, ND_MAX_INSTRUCTION_LENGTH, ND_CODE_64, ND_DATA_64))) break;
        if (ix.Instruction == ND_INS_JMPNR && ix.Length == 5) {
            const uintptr_t target = ip + ix.Length + (intptr_t)(int32_t)ix.RelativeOffset;
            if (target - base != m_cfg.rva_telekinesis_update) {
                API::get()->log_info("HellraiserAimFix: telekinesis update decoded at RVA 0x%llX (configured 0x%llX)",
                    (unsigned long long)(target - base), (unsigned long long)m_cfg.rva_telekinesis_update);
            }
            return target;
        }
        if (ix.Instruction == ND_INS_RETN) break;
        ip += ix.Length;
    }
    API::get()->log_info("HellraiserAimFix: no tail jump in vtable slot %d (RVA 0x%llX); using RVA 0x%llX",
        m_cfg.telekinesis_tick_vtable_index, (unsigned long long)(slot - base), (unsigned long long)m_cfg.rva_telekinesis_update);
    return fallback;
}

// Fresh left controller pose from Lua (HMD active, sent within LeftAimMaxAge)
bool HellraiserAimFixPlugin::get_left_aim(Vec3& loc, Rot3& rot) {
    {
        std::scoped_lock _{m_mutex};
        if (m_left_aim_time < 0.0 || now_seconds() - m_left_aim_time > m_cfg.left_aim_max_age) return false;
        loc = m_left_aim_loc;
        rot = m_left_aim_rot;
    }
    return API::VR::is_hmd_active();
}

// The aim ray the targeting traces along: game = screen-centre deprojection; here = the left controller.
bool HellraiserAimFixPlugin::on_telekinesis_aim_ray(void* self, double* screen, double* center, Vec3* world_loc, Vec3* world_dir) {
    const bool ok = m_orig_tk_aim_ray(self, screen, center, world_loc, world_dir);
    Vec3 loc{};
    Rot3 rot{};
    if (ok && world_loc != nullptr && world_dir != nullptr && g_plugin->get_left_aim(loc, rot)) {
        *world_loc = loc;
        *world_dir = normalize(rotator_forward(rot));
        ++g_plugin->m_tk_rays;
    }
    return ok;
}

void HellraiserAimFixPlugin::on_telekinesis_update(void* self) {
    auto& p = *g_plugin;
    ++p.m_tk_updates;

    Vec3 loc{};
    Rot3 rot{};
    const bool fresh = p.get_left_aim(loc, rot);

    SavedTransform saved[2]{};
    int n = 0;
    if (fresh && self != nullptr) {
        auto camera_ref = *(uint8_t**)((uint8_t*)self + TK_CAMERA_REF);
        if (readable_object(camera_ref)) {
            saved[n++].comp = camera_ref;
            auto child = *(uint8_t**)(camera_ref + CAC_CHILD_ACTOR);
            if (readable_object(child)) {
                auto root = *(uint8_t**)(child + ACTOR_ROOT);
                if (readable_object(root) && root != camera_ref) saved[n++].comp = root;
            }
        }
        const Quat4 q = rotator_to_quat(rot);
        for (int i = 0; i < n; ++i) {
            auto c = saved[i].comp;
            std::memcpy(&saved[i].rot, c + SC_C2W_ROT, sizeof(Quat4));
            std::memcpy(&saved[i].loc, c + SC_C2W_LOC, sizeof(Vec3));
            std::memcpy(c + SC_C2W_ROT, &q, sizeof(Quat4));
            std::memcpy(c + SC_C2W_LOC, &loc, sizeof(Vec3));
        }
        if (n > 0) ++p.m_tk_redirects;
    }

    m_orig_tk_update(self);

    for (int i = 0; i < n; ++i) {
        std::memcpy(saved[i].comp + SC_C2W_ROT, &saved[i].rot, sizeof(Quat4));
        std::memcpy(saved[i].comp + SC_C2W_LOC, &saved[i].loc, sizeof(Vec3));
    }
}

// ------------------------------------------------------------------------------------------------
// Seated interactions (chair puzzle) aimed with the head. InteractManager::CheckCurrentInteraction (disassembly
// 2026-10-08) takes TargetLocation = pawn FPCameraActor (+0xC08) ComponentToWorld translation and TargetForward =
// its forward (0x143D13790, from the ComponentToWorld quat), compares the angle to the interactable
// (GetPreciseAngle) with InteractAngle / InteractPrecision. While Lua sends a fresh head pose (only while seated:
// the game turns its camera with the right stick there and UEVR shows the head on top), that transform is swapped
// for the head pose during the candidate scan and the focus check, and restored afterwards. Nested calls (the scan
// may run the check) swap once.

bool HellraiserAimFixPlugin::begin_head_swap(CameraSwap& s) {
    if (!m_cfg.interact_head_aim) return false;
    if (m_head_swap_depth++ > 0) return false; // outer call already swapped
    Vec3 loc{};
    Rot3 rot{};
    {
        std::scoped_lock _{m_mutex};
        if (m_head_aim_time < 0.0 || now_seconds() - m_head_aim_time > m_cfg.left_aim_max_age) return false;
        loc = m_head_aim_loc;
        rot = m_head_aim_rot;
    }
    if (!API::VR::is_hmd_active()) return false;
    auto comp = (uint8_t*)get_object_prop(API::get()->get_local_pawn(0), L"FPCameraActor");
    if (!readable_object(comp)) return false;
    s.comp = comp;
    std::memcpy(s.saved, comp + SC_C2W_ROT, sizeof(s.saved)); // quat (32) + translation (24)
    const Quat4 q = rotator_to_quat(rot);
    std::memcpy(comp + SC_C2W_ROT, &q, sizeof(Quat4));
    std::memcpy(comp + SC_C2W_LOC, &loc, sizeof(Vec3));
    m_head_swap_active = true;
    m_head_swap_loc = loc;
    m_head_swap_rot = rot;
    ++m_head_swaps;
    return true;
}

void HellraiserAimFixPlugin::end_head_swap(CameraSwap& s) {
    if (m_head_swap_depth > 0) --m_head_swap_depth;
    if (s.comp == nullptr) return;
    std::memcpy(s.comp + SC_C2W_ROT, s.saved, sizeof(s.saved));
    s.comp = nullptr;
    m_head_swap_active = false;
}

// "Is the prompt on screen" (projection through the real game camera) -> "is the interactable within
// InteractHeadConeDeg of the head direction", only while a head swap is in place.
bool HellraiserAimFixPlugin::on_interact_on_screen(void* self, void* interact_comp) {
    auto& p = *g_plugin;
    if (!p.m_head_swap_active || !readable_object(interact_comp)) return m_orig_interact_on_screen(self, interact_comp);
    Vec3 target{};
    std::memcpy(&target, (const uint8_t*)interact_comp + SC_C2W_LOC, sizeof(Vec3));
    const Vec3 to = normalize(sub(target, p.m_head_swap_loc));
    const Vec3 fwd = normalize(rotator_forward(p.m_head_swap_rot));
    return dot(to, fwd) >= std::cos(deg2rad(p.m_cfg.interact_head_cone_deg));
}

void HellraiserAimFixPlugin::on_interact_scan(void* self) {
    CameraSwap s{};
    g_plugin->begin_head_swap(s);
    m_orig_interact_scan(self);
    g_plugin->end_head_swap(s);
}

bool HellraiserAimFixPlugin::on_interact_check_current(void* self) {
    CameraSwap s{};
    g_plugin->begin_head_swap(s);
    const bool r = m_orig_interact_check(self);
    g_plugin->end_head_swap(s);
    return r;
}

// ------------------------------------------------------------------------------------------------
// Melee: the player's melee hit check is a camera-centred targeting fan. DoTargeting_Fanout_C (a Blueprint
// targeting object) fires ~165 Kismet SphereTraceSingle (r=5, channel 7) in ONE tick at the start of a swing,
// all starting at the camera and fanning out up to ~2.3 m around camera forward (log 2026-10-07). Where the
// weapon physically is plays no part.
// Physical melee (scripts/physical_melee.lua) fires the attack when the VR weapon enters an enemy and sends
// that enemy's position as custom event "HellraiserMeleeTarget" ("x,y,z"). For MeleeTargetWindow seconds after
// that, every fan trace that starts at the camera is rotated about the camera by camera-forward ->
// (camera -> target), so the fan is centred on the enemy the weapon touched. Button attacks keep the game's fan.

void HellraiserAimFixPlugin::on_custom_event(const char* event_name, const char* event_data) {
    if (event_name == nullptr || event_data == nullptr) return;
    if (std::strcmp(event_name, "HellraiserHeadAim") == 0) {
        Vec3 l{};
        Rot3 r{};
        if (std::sscanf(event_data, "%lf,%lf,%lf,%lf,%lf,%lf", &l.x, &l.y, &l.z, &r.pitch, &r.yaw, &r.roll) != 6) return;
        std::scoped_lock _{m_mutex};
        m_head_aim_loc = l;
        m_head_aim_rot = r;
        m_head_aim_time = now_seconds();
        return;
    }
    if (std::strcmp(event_name, "HellraiserLeftAim") == 0) {
        Vec3 l{};
        Rot3 r{};
        if (std::sscanf(event_data, "%lf,%lf,%lf,%lf,%lf,%lf", &l.x, &l.y, &l.z, &r.pitch, &r.yaw, &r.roll) != 6) return;
        std::scoped_lock _{m_mutex};
        m_left_aim_loc = l;
        m_left_aim_rot = r;
        m_left_aim_time = now_seconds();
        return;
    }
    if (std::strcmp(event_name, "HellraiserMeleeTarget") != 0) return;
    Vec3 p{}, s{};
    double spread = -1.0;
    const int n = std::sscanf(event_data, "%lf,%lf,%lf,%lf,%lf,%lf,%lf", &p.x, &p.y, &p.z, &spread, &s.x, &s.y, &s.z);
    if (n < 3) return;
    std::scoped_lock _{m_mutex};
    m_melee_target = p;
    m_melee_target_time = now_seconds();
    m_melee_target_spread = n >= 4 ? spread : -1.0;
    m_melee_target_has_start = n == 7;
    m_melee_target_start = s;
    if (m_cfg.debug) {
        if (n == 7) {
            API::get()->log_info("HellraiserAimFix[melee] target from Lua (%.0f %.0f %.0f) spread %.2f from weapon (%.0f %.0f %.0f)",
                p.x, p.y, p.z, spread, s.x, s.y, s.z);
        } else {
            API::get()->log_info("HellraiserAimFix[melee] target from Lua (%.0f %.0f %.0f) spread %.2f", p.x, p.y, p.z, spread);
        }
    }
}

void HellraiserAimFixPlugin::on_exec_sphere_trace_single(API::UObject* ctx, void* stack, void* result) {
    API::UObject* caller = nullptr;
    if (stack != nullptr) caller = *(API::UObject* const*)((const uint8_t*)stack + FFRAME_OBJECT);
    const auto previous = t_sts_caller;
    t_sts_caller = caller;
    m_orig_exec_sts(ctx, stack, result);
    t_sts_caller = previous;
}

// Starts a new burst (> 50 ms since the last trace or another caller): samples camera + held weapon once.
void HellraiserAimFixPlugin::update_melee_burst(API::UObject* caller) {
    const double t = now_seconds();
    const bool new_burst = m_melee_burst_time < 0.0 || t - m_melee_burst_time > 0.05 || caller != m_burst_caller;
    m_melee_burst_time = t;
    if (!new_burst) return;
    m_burst_caller = caller;
    m_burst_buffer.clear();
    m_burst_count = 0;
    m_burst_logged = false;
    m_burst_follow = false;
    m_burst_from_weapon = false;
    m_burst_cam = {}; m_burst_fwd = {1, 0, 0}; m_burst_weapon = {};
    auto pc = API::get()->get_player_controller(0);
    if (auto cm = get_object_prop(pc, L"PlayerCameraManager"); cm != nullptr) {
        struct { Vec3 ret; } cl{};
        struct { Rot3 ret; } cr{};
        cm->call_function(L"GetCameraLocation", &cl);
        cm->call_function(L"GetCameraRotation", &cr);
        m_burst_cam = cl.ret;
        m_burst_fwd = normalize(rotator_forward(cr.ret));
    }
    // the visible weapon: melee weapons keep it in the static child (the skeletal root is empty)
    m_burst_pawn = API::get()->get_local_pawn(0);
    auto weapon = get_object_prop(m_burst_pawn, L"CurrentEquipment");
    m_burst_equipment = weapon;
    auto visible = get_object_prop(weapon, L"FirstPersonEqupableStatic");
    if (visible == nullptr) visible = get_object_prop(weapon, L"RootComponent");
    if (visible != nullptr) {
        struct { Vec3 ret; } wl{};
        visible->call_function(L"K2_GetComponentLocation", &wl);
        m_burst_weapon = wl.ret;
    }

    // follow target from physical melee (fresh, and in front of the camera rather than behind it - unless the rays
    // start at the weapon, where the camera direction no longer matters)
    if (m_cfg.melee_follow && is_melee_targeting(caller)) {
        Vec3 target{}, weapon_start{};
        double age = 1e9;
        double spread = -1.0;
        bool has_start = false;
        {
            std::scoped_lock _{m_mutex};
            target = m_melee_target;
            age = m_melee_target_time < 0.0 ? 1e9 : t - m_melee_target_time;
            spread = m_melee_target_spread;
            has_start = m_melee_target_has_start;
            weapon_start = m_melee_target_start;
        }
        if (age <= m_cfg.melee_target_window) {
            const Vec3 to_target = normalize(sub(target, m_burst_cam));
            const bool from_weapon = has_start && m_cfg.melee_from_weapon;
            // NOT consumed: one swing runs TWO targeting passes ~0.23 s apart (log 2026-10-07: the second one fell
            // back to the camera when the target was consumed by the first) - both follow within the window.
            if (from_weapon || dot(to_target, m_burst_fwd) > -0.2) {
                m_burst_follow = true;
                m_burst_follow_dir = to_target;
                m_burst_follow_dist = length(sub(target, m_burst_cam));
                if (spread < 0.0) spread = m_cfg.melee_follow_spread;
                m_burst_follow_spread = spread < 0.0 ? 0.0 : (spread > 1.0 ? 1.0 : spread);
                m_burst_from_weapon = from_weapon;
                m_burst_start = weapon_start;
            }
        }
        if (m_cfg.debug) {
            API::get()->log_info("HellraiserAimFix[melee] swing fan: %s (target age %.2f s, spread %.2f, target %.0f cm%s)",
                m_burst_follow ? "FOLLOWS the touched enemy" : "camera (game default)", age > 1e8 ? -1.0 : age,
                m_burst_follow ? m_burst_follow_spread : 1.0, m_burst_follow ? m_burst_follow_dist : 0.0,
                m_burst_from_weapon ? ", rays FROM THE WEAPON" : "");
        }
    }
}

bool HellraiserAimFixPlugin::is_melee_targeting(API::UObject* caller) {
    if (caller == nullptr) return false;
    auto cls = (API::UObject*)caller->get_class();
    if (cls == m_melee_targeting_class_cache) return m_melee_targeting_class_match;
    m_melee_targeting_class_cache = cls;
    m_melee_targeting_class_match = list_contains(m_cfg.melee_targeting_classes, object_name(cls));
    return m_melee_targeting_class_match;
}

bool HellraiserAimFixPlugin::on_sphere_trace_single(API::UObject* ctx, Vec3* start, Vec3* end, float radius,
    uint32_t channel, bool complex, void* ignore, uint32_t draw_debug, void* out_hit, bool ignore_self,
    void* trace_color, void* trace_hit_color, float draw_time) {
    auto& p = *g_plugin;
    auto caller = t_sts_caller; // nullptr = called from C++ (no Blueprint thunk on this thread)
    bool followed = false;
    ActorArray with_player{};
    API::UObject* buffer[64]{};
    if (caller != nullptr && start != nullptr && end != nullptr && p.is_melee_targeting(caller)) {
        p.update_melee_burst(caller);
        if (p.m_burst_follow && length(sub(*start, p.m_burst_cam)) <= p.m_cfg.start_tolerance) {
            const Vec3 d = sub(*end, *start);
            const double len = length(d);
            // the game's fan is ~30 cm wide where it meets the body (bone log 2026-10-23): narrowed by the spread so
            // the rays land around the touched spot; every ray reaches past it (the edge rays are short by design)
            const Vec3 rotated = normalize(rotate_from_to(normalize(d), p.m_burst_fwd, p.m_burst_follow_dir));
            const double s = p.m_burst_follow_spread;
            const Vec3 nd = normalize(add_scaled(add_scaled(Vec3{}, rotated, s), p.m_burst_follow_dir, 1.0 - s));
            if (p.m_burst_from_weapon) {
                // same spot on the body as the narrowed camera ray, reached from the weapon point just before
                // contact: only what lies between the blade and the touched spot can take the hit
                const Vec3 aim = add_scaled(p.m_burst_cam, nd, p.m_burst_follow_dist);
                const Vec3 dir = normalize(sub(aim, p.m_burst_start));
                const double reach = length(sub(aim, p.m_burst_start)) + p.m_cfg.melee_follow_extra_reach;
                *start = p.m_burst_start;
                *end = add_scaled(*start, dir, reach);
                // the rays now start next to the player: neither the pawn nor what it holds may block them
                const auto original = (const ActorArray*)ignore;
                const int32_t n = (original != nullptr && original->data != nullptr) ? original->num : 0;
                if (n >= 0 && n + 2 <= (int32_t)std::size(buffer)) {
                    for (int32_t i = 0; i < n; ++i) buffer[i] = original->data[i];
                    int32_t count = n;
                    if (p.m_burst_pawn != nullptr) buffer[count++] = p.m_burst_pawn;
                    if (p.m_burst_equipment != nullptr) buffer[count++] = p.m_burst_equipment;
                    with_player = ActorArray{buffer, count, (int32_t)std::size(buffer)};
                    ignore = &with_player;
                }
            } else {
                const double reach = (std::max)(len, p.m_burst_follow_dist + p.m_cfg.melee_follow_extra_reach);
                *end = add_scaled(*start, nd, reach);
            }
            followed = true;
        }
    }
    const bool hit = m_orig_sts(ctx, start, end, radius, channel, complex, ignore, draw_debug, out_hit, ignore_self,
        trace_color, trace_hit_color, draw_time);
    if (p.m_cfg.discover_melee && start != nullptr && end != nullptr) {
        p.log_melee_trace(caller, *start, *end, radius, channel, hit, followed, hit ? out_hit : nullptr);
    }
    return hit;
}

// Reads the FHitResult the trace just wrote. The hit component is alive this tick, so its weak pointer's object
// index is looked up directly; its outer is the owning actor.
HellraiserAimFixPlugin::HitInfo HellraiserAimFixPlugin::read_hit(const void* out_hit) {
    HitInfo info{};
    if (out_hit == nullptr) return info;
    if (!m_hit_offsets_resolved) {
        m_hit_offsets_resolved = true;
        if (auto s = API::get()->find_uobject<API::UScriptStruct>(L"ScriptStruct /Script/Engine.HitResult"); s != nullptr) {
            auto offset = [&](const wchar_t* name, int fallback) {
                auto prop = s->find_property(name);
                return prop != nullptr ? prop->get_offset() : fallback;
            };
            m_hit_impact_point_offset = offset(L"ImpactPoint", m_hit_impact_point_offset);
            m_hit_flags_offset = offset(L"bStartPenetrating", m_hit_flags_offset);
            m_hit_component_offset = offset(L"Component", m_hit_component_offset);
            m_hit_bone_offset = offset(L"BoneName", m_hit_bone_offset);
        }
        API::get()->log_info("HellraiserAimFix[melee] HitResult offsets: ImpactPoint=%d flags=%d Component=%d BoneName=%d",
            m_hit_impact_point_offset, m_hit_flags_offset, m_hit_component_offset, m_hit_bone_offset);
    }
    const auto h = (const uint8_t*)out_hit;
    info.valid = true;
    info.impact = *(const Vec3*)(h + m_hit_impact_point_offset);
    info.start_penetrating = (h[m_hit_flags_offset] & 0x02) != 0; // bBlockingHit:1, bStartPenetrating:1
    info.bone = ((const API::FName*)(h + m_hit_bone_offset))->to_string();
    const int32_t index = *(const int32_t*)(h + m_hit_component_offset);
    API::UObject* component = nullptr;
    if (index > 0) {
        if (auto objects = API::FUObjectArray::get(); objects != nullptr) component = objects->get_object(index);
    }
    info.component = object_name(component);
    info.actor = object_name(component != nullptr ? component->get_outer() : nullptr);
    return info;
}

// Discovery log (DiscoverMelee=1): bursts of >= 10 SphereTraceSingle from one non-fire caller.
void HellraiserAimFixPlugin::log_melee_trace(API::UObject* caller, const Vec3& start, const Vec3& end, float radius,
                                             uint32_t channel, bool hit, bool followed, const void* out_hit) {
    if (m_fire_ability_class == nullptr) m_fire_ability_class = API::get()->find_uobject<API::UClass>(m_cfg.fire_ability_class);
    if (caller != nullptr && m_fire_ability_class != nullptr && caller->is_a(m_fire_ability_class)) return;

    const std::wstring cls = caller != nullptr ? object_name((API::UObject*)caller->get_class()) : L"<native>";
    ++m_sts_callers[cls];
    if (m_melee_lines >= m_cfg.discover_melee_max_lines) return;

    update_melee_burst(caller);
    ++m_burst_count;
    const HitInfo info = out_hit != nullptr ? read_hit(out_hit) : HitInfo{};
    if (m_burst_count < 10) {
        m_burst_buffer.push_back({start, end, radius, channel, hit, followed, info});
        return;
    }
    if (!m_burst_logged) {
        m_burst_logged = true;
        ++m_melee_burst_index;
        const Vec3 w = sub(m_burst_weapon, m_burst_cam);
        API::get()->log_info("HellraiserAimFix[melee] burst #%d caller=%s (%s) follow=%d cam=(%.0f %.0f %.0f) camFwd=(%.3f %.3f %.3f) weaponFromCam=(%.1f %.1f %.1f)",
            m_melee_burst_index, narrow(object_name(caller)).c_str(), narrow(cls).c_str(), (int)m_burst_follow,
            m_burst_cam.x, m_burst_cam.y, m_burst_cam.z, m_burst_fwd.x, m_burst_fwd.y, m_burst_fwd.z, w.x, w.y, w.z);
        ++m_melee_lines;
        for (const auto& b : m_burst_buffer) log_melee_line(b.start, b.end, b.radius, b.channel, b.hit, b.followed, b.info);
        m_burst_buffer.clear();
    }
    log_melee_line(start, end, radius, channel, hit, followed, info);
}

void HellraiserAimFixPlugin::log_melee_line(const Vec3& start, const Vec3& end, float radius, uint32_t channel, bool hit, bool followed,
                                            const HitInfo& info) {
    if (m_melee_lines >= m_cfg.discover_melee_max_lines) return;
    // camera frame: X forward, Y right, Z up (UE: right = Z x forward)
    const Vec3 right = normalize(cross(Vec3{0, 0, 1}, m_burst_fwd));
    const Vec3 up = cross(m_burst_fwd, right);
    auto local = [&](const Vec3& p) { const Vec3 d = sub(p, m_burst_cam); return Vec3{dot(d, m_burst_fwd), dot(d, right), dot(d, up)}; };
    const Vec3 ls = local(start), le = local(end);
    API::get()->log_info("HellraiserAimFix[melee]   #%d %s%s r=%.1f ch=%u camLocal start=(%.1f %.1f %.1f) end=(%.1f %.1f %.1f) startToWeapon=%.1f",
        m_melee_burst_index, hit ? "HIT " : "miss", followed ? " FOLLOW" : "", radius, channel, ls.x, ls.y, ls.z, le.x, le.y, le.z,
        length(sub(start, m_burst_weapon)));
    ++m_melee_lines;
    if (info.valid) {
        const Vec3 li = local(info.impact);
        API::get()->log_info("HellraiserAimFix[melee]     -> %s.%s bone=%s impact camLocal=(%.1f %.1f %.1f) impactToWeapon=%.1f%s",
            narrow(info.actor).c_str(), narrow(info.component).c_str(), narrow(info.bone).c_str(), li.x, li.y, li.z,
            length(sub(info.impact, m_burst_weapon)), info.start_penetrating ? " START-PENETRATING" : "");
        ++m_melee_lines;
    }
}

// ------------------------------------------------------------------------------------------------
// Shot context (game thread, inside the trace thunk of a Blueprint node)

bool HellraiserAimFixPlugin::capture_context(void* stack, ShotContext& ctx) {
    if (stack == nullptr) return false;
    const auto s = (const uint8_t*)stack;
    ctx.caller = *(API::UObject* const*)(s + FFRAME_OBJECT);
    if (ctx.caller == nullptr) return false;

    if (m_fire_ability_class == nullptr) m_fire_ability_class = API::get()->find_uobject<API::UClass>(m_cfg.fire_ability_class);
    if (m_fire_ability_class == nullptr || !ctx.caller->is_a(m_fire_ability_class)) return false;
    ctx.from_fire_ability = true;

    auto pawn = API::get()->get_local_pawn(0);
    auto weapon = get_object_prop(pawn, L"CurrentEquipment");
    if (m_ranged_weapon_class == nullptr) m_ranged_weapon_class = API::get()->find_uobject<API::UClass>(m_cfg.ranged_weapon_class);
    if (weapon == nullptr || (m_ranged_weapon_class != nullptr && !weapon->is_a(m_ranged_weapon_class))) { ++m_no_muzzle; return false; }
    auto mesh = get_object_prop(weapon, L"RootComponent");
    if (mesh == nullptr) { ++m_no_muzzle; return false; }
    ctx.weapon_actor = weapon;

    // muzzle = socket on the weapon's root mesh (the mesh UEVR holds on the right controller)
    struct { Vec3 ret; } loc{}, fwd{}, right{}, up{};
    mesh->call_function(L"K2_GetComponentLocation", &loc);
    if (near_zero(loc.ret)) { ++m_no_muzzle; return false; }
    mesh->call_function(L"GetForwardVector", &fwd);
    mesh->call_function(L"GetRightVector", &right);
    mesh->call_function(L"GetUpVector", &up);
    static API::FName s_socket{m_cfg.muzzle_socket};
    struct { API::FName name; Vec3 ret; } sl{};
    sl.name = s_socket;
    mesh->call_function(L"GetSocketLocation", &sl);
    const Vec3 axes[3]{normalize(fwd.ret), normalize(right.ret), normalize(up.ret)};
    Vec3 dir = axes[m_cfg.axis_index];
    dir = Vec3{dir.x * m_cfg.axis_sign, dir.y * m_cfg.axis_sign, dir.z * m_cfg.axis_sign};
    if (m_cfg.yaw_offset_deg != 0.0) dir = rotate_axis(dir, Vec3{0, 0, 1}, deg2rad(m_cfg.yaw_offset_deg));
    if (m_cfg.pitch_offset_deg != 0.0) {
        const Vec3 r = normalize(cross(Vec3{0, 0, 1}, dir));
        dir = rotate_axis(dir, r, -deg2rad(m_cfg.pitch_offset_deg));
    }
    ctx.barrel = normalize(dir);
    ctx.muzzle = add_scaled(near_zero(sl.ret) ? loc.ret : sl.ret, ctx.barrel, m_cfg.muzzle_forward_offset);

    // camera the game aimed from
    auto pc = API::get()->get_player_controller(0);
    auto cm = get_object_prop(pc, L"PlayerCameraManager");
    if (cm == nullptr) return false;
    struct { Vec3 ret; } cl{};
    struct { Rot3 ret; } cr{};
    cm->call_function(L"GetCameraLocation", &cl);
    cm->call_function(L"GetCameraRotation", &cr);
    ctx.cam_loc = cl.ret;
    ctx.cam_fwd = normalize(rotator_forward(cr.ret));
    ctx.valid = true;
    return true;
}

// Rewrites start/end in place when the trace starts at the camera. Returns true if overridden.
bool HellraiserAimFixPlugin::redirect(const ShotContext& ctx, Vec3* start, Vec3* end, const char* what) {
    if (start == nullptr || end == nullptr) return false;
    ++m_fire_traces;
    const Vec3 s0 = *start, e0 = *end;
    const Vec3 delta = sub(e0, s0);
    const double len = length(delta);
    const Vec3 dir = normalize(delta);
    const double from_cam = ctx.valid ? length(sub(s0, ctx.cam_loc)) : -1.0;

    // Only bullet traces: GA_Fire also runs a camera-origin sphere trace pointing ~135 deg away from the aim
    // (backwards and down, ~54 m; measured 2026-10-07) that is not the shot and must not be rotated.
    const double aim_dot = ctx.valid ? dot(dir, ctx.cam_fwd) : -1.0;
    const bool near_aim = aim_dot >= std::cos(deg2rad(m_cfg.max_angle_from_aim));

    bool overridden = false;
    Vec3 new_dir{};
    if (ctx.valid && len > 1.0 && from_cam <= m_cfg.start_tolerance && near_aim) {
        // keep the game's spread: rotate the shot direction by camera-forward -> barrel
        new_dir = normalize(rotate_from_to(dir, ctx.cam_fwd, ctx.barrel));
        if (m_cfg.mode == 1 && API::VR::is_hmd_active()) {
            *start = ctx.muzzle;
            *end = add_scaled(ctx.muzzle, new_dir, len);
            overridden = true;
            ++m_overrides;
        }
    } else if (ctx.valid && !near_aim) {
        ++m_skipped_angle;
    } else if (ctx.valid) {
        ++m_skipped_far;
    }

    if (m_cfg.debug) {
        API::get()->log_info("HellraiserAimFix[%s]: caller=%s len=%.0f startFromCam=%.1f dir=(%.3f %.3f %.3f) dot(dir,camFwd)=%.4f dot(dir,barrel)=%.3f muzzle=(%.0f %.0f %.0f) %s",
            what, narrow(object_name(ctx.caller)).c_str(), len, from_cam, dir.x, dir.y, dir.z,
            ctx.valid ? dot(dir, ctx.cam_fwd) : 0.0, ctx.valid ? dot(dir, ctx.barrel) : 0.0,
            ctx.muzzle.x, ctx.muzzle.y, ctx.muzzle.z,
            overridden ? "OVERRIDDEN" : (!ctx.valid ? "no muzzle/camera" : (!near_aim ? "kept (not along the aim)" :
                (from_cam > m_cfg.start_tolerance ? "kept (not from camera)" : "kept (mode 0)"))));
    }
    return overridden;
}

// ------------------------------------------------------------------------------------------------
// Hooks

void HellraiserAimFixPlugin::on_exec_line_trace_single(API::UObject* ctx, void* stack, void* result) {
    ShotContext c{};
    g_plugin->capture_context(stack, c);
    const auto previous = t_ctx;
    t_ctx = c;
    m_orig_exec_lts(ctx, stack, result);
    t_ctx = previous;
}

void HellraiserAimFixPlugin::on_exec_sphere_trace_multi(API::UObject* ctx, void* stack, void* result) {
    ShotContext c{};
    g_plugin->capture_context(stack, c);
    const auto previous = t_ctx;
    t_ctx = c;
    m_orig_exec_stm(ctx, stack, result);
    t_ctx = previous;
}

// obj's class chain contains a class named `name` (cached per class)
bool HellraiserAimFixPlugin::class_chain_has(std::unordered_map<void*, bool>& cache, API::UObject* obj, const std::wstring& name) {
    if (obj == nullptr) return false;
    auto cls = obj->get_class();
    if (cls == nullptr) return false;
    std::scoped_lock _{m_class_cache_mutex};
    if (auto it = cache.find(cls); it != cache.end()) return it->second;
    bool match = false;
    for (API::UStruct* s = cls; s != nullptr; s = s->get_super()) {
        if (object_name((API::UObject*)s) == name) { match = true; break; }
    }
    cache.emplace(cls, match);
    return match;
}

bool HellraiserAimFixPlugin::class_chain_has_any(std::unordered_map<void*, bool>& cache, API::UObject* obj, const std::wstring& names) {
    if (obj == nullptr) return false;
    auto cls = obj->get_class();
    if (cls == nullptr) return false;
    std::scoped_lock _{m_class_cache_mutex};
    if (auto it = cache.find(cls); it != cache.end()) return it->second;
    bool match = false;
    for (API::UStruct* s = cls; s != nullptr; s = s->get_super()) {
        if (list_contains(names, object_name((API::UObject*)s))) { match = true; break; }
    }
    cache.emplace(cls, match);
    return match;
}

// The telekinesis puzzle (puzzle cube Blueprint: camera ray x plane; puzzle ability: drop angle) asking the pawn's
// FPCameraActor child-actor component where it is / where it points -> the left controller instead. Discovery log
// 2026-10-08: only K2_GetComponentLocation + GetForwardVector on FPCameraActor are camera queries; everything else
// those Blueprints ask (CubeParent, ProjectionPlaneArrow, Box) is left alone.
bool HellraiserAimFixPlugin::telekinesis_camera_query(API::UObject* ctx, void* stack, Vec3& loc, Rot3& rot, const char* fn) {
    if (stack == nullptr || ctx == nullptr || !m_cfg.telekinesis_left_hand) return false;
    auto caller = *(API::UObject* const*)((const uint8_t*)stack + FFRAME_OBJECT);
    if (!class_chain_has_any(m_tk_caller_cache, caller, m_cfg.telekinesis_camera_callers)) return false;
    static const std::wstring k_child_actor_component{L"ChildActorComponent"};
    if (!class_chain_has(m_cac_class_cache, ctx, k_child_actor_component) || object_name(ctx) != L"FPCameraActor") return false;
    if (!get_left_aim(loc, rot)) return false;
    ++m_tk_camera_queries;
    if (m_cfg.debug) {
        // once per (function, caller class)
        const std::wstring key = std::wstring(fn, fn + std::strlen(fn)) + L"|" + object_name((API::UObject*)caller->get_class());
        bool first = false;
        {
            std::scoped_lock _{m_class_cache_mutex};
            first = m_camera_query_logged.emplace(key, true).second;
        }
        if (first) {
            API::get()->log_info("HellraiserAimFix[tk-camera]: %s from %ls on FPCameraActor -> left hand", fn,
                object_name((API::UObject*)caller->get_class()).c_str());
        }
    }
    return true;
}

void HellraiserAimFixPlugin::on_exec_get_component_location(API::UObject* ctx, void* stack, void* result) {
    m_orig_exec_get_loc(ctx, stack, result);
    Vec3 loc{}; Rot3 rot{};
    if (result != nullptr && g_plugin->telekinesis_camera_query(ctx, stack, loc, rot, "K2_GetComponentLocation")) *(Vec3*)result = loc;
}

void HellraiserAimFixPlugin::on_exec_get_forward_vector(API::UObject* ctx, void* stack, void* result) {
    m_orig_exec_get_fwd(ctx, stack, result);
    Vec3 loc{}; Rot3 rot{};
    if (result != nullptr && g_plugin->telekinesis_camera_query(ctx, stack, loc, rot, "GetForwardVector")) {
        *(Vec3*)result = normalize(rotator_forward(rot));
    }
}

bool HellraiserAimFixPlugin::on_line_trace_single(API::UObject* ctx, Vec3* start, Vec3* end, uint32_t channel,
    bool complex, void* ignore, uint32_t draw_debug, void* out_hit, bool ignore_self,
    void* trace_color, void* trace_hit_color, float draw_time) {
    const auto c = t_ctx;
    ActorArray with_weapon{};
    API::UObject* buffer[64]{};
    if (c.from_fire_ability && g_plugin->redirect(c, start, end, "line")) {
        // the trace now starts at the gun: make sure the gun itself cannot block it
        const auto original = (const ActorArray*)ignore;
        const int32_t n = (original != nullptr && original->data != nullptr) ? original->num : 0;
        if (c.weapon_actor != nullptr && n >= 0 && n < (int32_t)std::size(buffer)) {
            for (int32_t i = 0; i < n; ++i) buffer[i] = original->data[i];
            buffer[n] = c.weapon_actor;
            with_weapon = ActorArray{buffer, n + 1, (int32_t)std::size(buffer)};
            ignore = &with_weapon;
        }
    }
    return m_orig_lts(ctx, start, end, channel, complex, ignore, draw_debug, out_hit, ignore_self,
        trace_color, trace_hit_color, draw_time);
}

bool HellraiserAimFixPlugin::on_sphere_trace_multi(API::UObject* ctx, Vec3* start, Vec3* end, float radius,
    uint32_t channel, bool complex, void* ignore, uint32_t draw_debug, void* out_hits, bool ignore_self,
    void* trace_color, void* trace_hit_color, float draw_time) {
    const auto c = t_ctx;
    ActorArray with_weapon{};
    API::UObject* buffer[64]{};
    if (c.from_fire_ability && g_plugin->redirect(c, start, end, "sphere")) {
        const auto original = (const ActorArray*)ignore;
        const int32_t n = (original != nullptr && original->data != nullptr) ? original->num : 0;
        if (c.weapon_actor != nullptr && n >= 0 && n < (int32_t)std::size(buffer)) {
            for (int32_t i = 0; i < n; ++i) buffer[i] = original->data[i];
            buffer[n] = c.weapon_actor;
            with_weapon = ActorArray{buffer, n + 1, (int32_t)std::size(buffer)};
            ignore = &with_weapon;
        }
    }
    return m_orig_stm(ctx, start, end, radius, channel, complex, ignore, draw_debug, out_hits, ignore_self,
        trace_color, trace_hit_color, draw_time);
}

void HellraiserAimFixPlugin::on_pre_engine_tick(API::UGameEngine*, float) {
    const double t = now_seconds();
    if (m_cfg.discover_melee && t - m_last_caller_log >= 10.0) {
        m_last_caller_log = t;
        for (const auto& [cls, n] : m_sts_callers) {
            API::get()->log_info("HellraiserAimFix[melee-callers]: SphereTraceSingle from %s: %u calls", narrow(cls).c_str(), n);
        }
    }
    if (!m_hooks_ok || !m_cfg.debug) return;
    if (t - m_last_debug_log < 10.0) return;
    m_last_debug_log = t;
    API::get()->log_info("HellraiserAimFix[sum]: fireTraces=%u overrides=%u keptNotAlongAim=%u keptNotFromCamera=%u noMuzzle=%u telekinesisUpdates=%u fromLeftHand=%u aimRaysFromLeftHand=%u puzzleCameraQueriesFromLeftHand=%u interactChecksFromHead=%u",
        m_fire_traces, m_overrides, m_skipped_angle, m_skipped_far, m_no_muzzle, m_tk_updates, m_tk_redirects, m_tk_rays, m_tk_camera_queries,
        m_head_swaps);
}

// ------------------------------------------------------------------------------------------------
// Config: plugins/HellraiserAimFix.txt (optional; defaults above)

void HellraiserAimFixPlugin::load_config(const std::filesystem::path& file) {
    if (!std::filesystem::exists(file)) {
        API::get()->log_info("HellraiserAimFix: no config at %ls, using defaults", file.c_str());
        return;
    }
    std::ifstream in(file);
    std::string line;
    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#' || line[0] == ';') continue;
        if (const auto hash = line.find('#'); hash != std::string::npos) line = trim(line.substr(0, hash));
        const auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        const auto key = trim(line.substr(0, eq));
        const auto val = trim(line.substr(eq + 1));
        auto as_bool = [&]() { return val == "1" || val == "true" || val == "yes" || val == "on"; };
        auto as_num = [&]() { try { return std::stod(val); } catch (...) { return 0.0; } };
        auto as_wide = [&]() { return std::wstring(val.begin(), val.end()); };
        auto as_rva = [&]() { try { return (uintptr_t)std::stoull(val, nullptr, 0); } catch (...) { return (uintptr_t)0; } };

        if (key == "Enabled") m_cfg.enabled = as_bool();
        else if (key == "Mode") m_cfg.mode = (int)as_num();
        else if (key == "Debug") m_cfg.debug = as_bool();
        else if (key == "RedirectSphereTraces") m_cfg.redirect_sphere_traces = as_bool();
        else if (key == "StartTolerance") m_cfg.start_tolerance = as_num();
        else if (key == "MaxAngleFromAim") m_cfg.max_angle_from_aim = as_num();
        else if (key == "FireAbilityClass") m_cfg.fire_ability_class = as_wide();
        else if (key == "RangedWeaponClass") m_cfg.ranged_weapon_class = as_wide();
        else if (key == "MuzzleSocket") m_cfg.muzzle_socket = as_wide();
        else if (key == "BarrelAxis") m_cfg.barrel_axis = as_wide();
        else if (key == "MuzzleForwardOffset") m_cfg.muzzle_forward_offset = as_num();
        else if (key == "PitchOffset") m_cfg.pitch_offset_deg = as_num();
        else if (key == "YawOffset") m_cfg.yaw_offset_deg = as_num();
        else if (key == "RVA_execLineTraceSingle") { if (auto v = as_rva()) m_cfg.rva_exec_line_trace_single = v; }
        else if (key == "RVA_LineTraceSingle") { if (auto v = as_rva()) m_cfg.rva_line_trace_single = v; }
        else if (key == "RVA_execSphereTraceMulti") { if (auto v = as_rva()) m_cfg.rva_exec_sphere_trace_multi = v; }
        else if (key == "RVA_SphereTraceMulti") { if (auto v = as_rva()) m_cfg.rva_sphere_trace_multi = v; }
        else if (key == "DiscoverMelee") m_cfg.discover_melee = as_bool();
        else if (key == "MeleeFollow") m_cfg.melee_follow = as_bool();
        else if (key == "MeleeTargetWindow") m_cfg.melee_target_window = as_num();
        else if (key == "MeleeFollowSpread") m_cfg.melee_follow_spread = as_num();
        else if (key == "MeleeFollowExtraReach") m_cfg.melee_follow_extra_reach = as_num();
        else if (key == "MeleeFromWeapon") m_cfg.melee_from_weapon = as_bool();
        else if (key == "MeleeTargetingClasses") m_cfg.melee_targeting_classes = as_wide();
        else if (key == "DiscoverMeleeMaxLines") m_cfg.discover_melee_max_lines = (int)as_num();
        else if (key == "RVA_execSphereTraceSingle") { if (auto v = as_rva()) m_cfg.rva_exec_sphere_trace_single = v; }
        else if (key == "RVA_SphereTraceSingle") { if (auto v = as_rva()) m_cfg.rva_sphere_trace_single = v; }
        else if (key == "TelekinesisLeftHand") m_cfg.telekinesis_left_hand = as_bool();
        else if (key == "LeftAimMaxAge") m_cfg.left_aim_max_age = as_num();
        else if (key == "TelekinesisTickVtableIndex") m_cfg.telekinesis_tick_vtable_index = (int)as_num();
        else if (key == "RVA_TelekinesisUpdate") { if (auto v = as_rva()) m_cfg.rva_telekinesis_update = v; }
        else if (key == "RVA_TelekinesisAimRay") { if (auto v = as_rva()) m_cfg.rva_telekinesis_aim_ray = v; }
        else if (key == "TelekinesisCameraCallers") m_cfg.telekinesis_camera_callers = as_wide();
        else if (key == "InteractHeadAim") m_cfg.interact_head_aim = as_bool();
        else if (key == "RVA_InteractScan") { if (auto v = as_rva()) m_cfg.rva_interact_scan = v; }
        else if (key == "RVA_InteractCheckCurrent") { if (auto v = as_rva()) m_cfg.rva_interact_check_current = v; }
        else if (key == "RVA_InteractOnScreen") { if (auto v = as_rva()) m_cfg.rva_interact_on_screen = v; }
        else if (key == "InteractHeadConeDeg") m_cfg.interact_head_cone_deg = as_num();
    }
}
