/*
 * Hps2 — N-API 桥接层：在 HAP 内启动 PCSX2 核心
 *
 * 启动序列**照搬上游移动端前端**（platforms/android/.../native-lib.cpp 与
 * platforms/ios/.../main.cpp），而非自行设计：
 *
 *   EmuFolders::AppRoot = <数据根>
 *   EmuFolders::DataRoot = <数据根>
 *   EmuFolders::SetResourcesDirectory()
 *   si.SetStringValue("Folders", "Bios", <BIOS 目录>)
 *   → 字体 → settings 层 → LoadStartupSettings
 *   → SysMemory::ReserveMemory()
 *   → [CPU 线程] CPUThreadInitialize → ApplySettings → VMManager::Initialize
 *   → VMManager::Execute() 执行循环
 *
 * 为什么照搬移动端而不是 Qt：移动端（Android/iOS）与 HAP 同为沙箱环境，
 * 路径模型一致；Qt 桌面版的目录推导在沙箱下不成立。
 *
 * 图形后端：显式设为 GSRendererType::Null（见 InitializeConfig 内的注释）。
 * 默认的 Auto 会让 GS 去初始化真实图形后端，而 HAP 无可用窗口时会卡住。
 * 阶段 2 只验证 BIOS 启动，与图形解耦，故用 Null 渲染器，
 * 无需 OHNativeWindow / Vulkan。
 *
 * 线程模型：VM 运行在独立线程（与上游一致），N-API 只负责启停与状态查询。
 *
 * 范围限制：本阶段只启动 BIOS（CDVD_SourceType::NoDisc），不挂载游戏盘。
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#include <atomic>
#include <cmath>
#include <cstdlib>   // getenv/setenv
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3202
#define LOG_TAG "HPS2_CORE"

#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

#include "common/CrashHandler.h"
#include "common/Error.h"
#include "common/Console.h"
#include "common/FileSystem.h"
#include "common/MemorySettingsInterface.h"
#include "common/Path.h"

#include <native_window/external_window.h>

#include "hps2_surface.h"
#include "hps2_vpad.h"
#include "hps2_video.h"

#include "CDVD/CDVD.h"
#include "Config.h"
#include "Host.h"
#include "ImGui/ImGuiManager.h"
#include "Memory.h"
#include "PerformanceMetrics.h"
#include "cpuinfo.h"      // 芯片拓扑探测
#include "R5900.h"   // cpuRegs（EE 程序计数器）+ Cpu/intCpu（判定是否被静默降级）
#include "VMManager.h"
#include "Input/InputManager.h"
#include "GS/GS.h"

#include "hps2_jitcheck.h"   // JIT 能力自检（启动前 + 运行期复检，不降级）

// ---------------------------------------------------------------------------
// 渲染表面共享状态（声明见 hps2_surface.h）
// 必须位于全局作用域：napi_init.cpp 与 hps2_host.cpp 都访问它。
// ---------------------------------------------------------------------------
namespace Hps2Surface {
	std::mutex g_mutex;
	void* g_window = nullptr;   // OHNativeWindow*
	int g_width = 0;
	int g_height = 0;
	bool g_ready = false;
	std::condition_variable g_cv;
}

namespace {

enum class BootStage : int {
	kIdle = 0,
	kSettingFolders,
	kHardwareCheck,
	kLoadingFonts,
	kSettingsLayer,
	kReservingMemory,
	kStartingThread,
	kRunning,
	kFailed,
};

const char* StageName(BootStage s) {
	switch (s) {
		case BootStage::kIdle:            return "idle";
		case BootStage::kSettingFolders:  return "setting-folders";
		case BootStage::kHardwareCheck:   return "hardware-check";
		case BootStage::kLoadingFonts:    return "loading-fonts";
		case BootStage::kSettingsLayer:   return "settings-layer";
		case BootStage::kReservingMemory: return "reserving-memory";
		case BootStage::kStartingThread:  return "starting-thread";
		case BootStage::kRunning:         return "running";
		case BootStage::kFailed:          return "failed";
	}
	return "unknown";
}

std::atomic<int> g_stage{static_cast<int>(BootStage::kIdle)};
std::atomic<bool> g_vm_running{false};
std::mutex g_mutex;
std::string g_last_error;
std::thread g_vm_thread;

MemorySettingsInterface s_settings_interface;
std::string s_data_root;
std::string s_bios_dir;
std::string s_game_path;   // 空 = 只启动 BIOS；非空 = 启动该游戏镜像

// ---------------------------------------------------------------------------
// JIT 能力状态（自检 + 运行期复检）
//
// 产品决策：**不做降级**。JIT 不可用时阻止启动并给出可操作建议，
// 而不是让 VMManager 静默切到解释器跑幻灯片。
// ---------------------------------------------------------------------------
std::atomic<bool> g_jit_available{false};
std::mutex g_jit_mutex;
std::string g_jit_message;   // 面向用户的说明
std::string g_jit_action;    // 面向用户的操作建议
std::string g_jit_stage;     // 失败阶段名
int g_jit_errno = 0;

void SetStage(BootStage s) {
	g_stage.store(static_cast<int>(s));
	LOGI("BOOT_STAGE=%{public}s", StageName(s));
}

void SetError(const std::string& msg) {
	{
		std::lock_guard<std::mutex> lock(g_mutex);
		g_last_error = msg;
	}
	LOGE("BOOT_ERROR=%{public}s", msg.c_str());
}

// ---------------------------------------------------------------------------
// JIT 状态读写
// ---------------------------------------------------------------------------
void SetJitState(const Hps2JitCheck::Result& r) {
	{
		std::lock_guard<std::mutex> lock(g_jit_mutex);
		g_jit_message = r.message;
		g_jit_action = r.action;
		g_jit_stage = r.stage_name;
		g_jit_errno = r.errno_value;
	}
	g_jit_available.store(r.available);
}

// 线程安全地读取面向用户的 JIT 说明（看门狗需要把它写进错误信息）。
std::string GetJitMessage() {
	std::lock_guard<std::mutex> lock(g_jit_mutex);
	return g_jit_message;
}

// 启动前自检。这是唯一的"能不能启动"判据。
// 返回 false 时已把原因写入 JIT 状态与 last_error，UI 可直接展示。
bool RunJitStartupCheck() {
	const Hps2JitCheck::Result r = Hps2JitCheck::RunStartupCheck();
	SetJitState(r);

	if (r.available) {
		LOGI("JIT_SELFCHECK=available");
		return true;
	}

	LOGE("JIT_SELFCHECK=unavailable stage=%{public}s errno=%{public}d msg=%{public}s",
		r.stage_name.c_str(), r.errno_value, r.message.c_str());

	// ---------------------------------------------------------------------
	// 【临时验证分支】降级模式：JIT 不可用时**不阻止启动**，放行到解释器路径。
	//
	// 目的：验证"商店包无法使用 JIT 时自动降级"这条路能否真正跑起来 ——
	// 包括两个此前未验证的环节：
	//   1) 环境变量 HPS2_FORCE_INTERP 能否让 Memory.cpp 跳过 code memory 分配
	//   2) 跳过之后 CPUThreadInitialize 是否还能成功、VM 能否启动
	//
	// 触发条件：FORCE_INTERP 标记文件存在（由 InitializeConfig 设置环境变量）。
	//
	// 注意：这是**验证用**分支。正式的商店包会改为编译期宏
	// （HPS2_STORE_BUILD），且必须把降级状态**明确告知用户**，
	// 而不是像上游那样静默切换（上游只打一行 Warning）。
	// ---------------------------------------------------------------------
	if (std::getenv("HPS2_FORCE_INTERP") != nullptr) {
		LOGW("JIT unavailable, but HPS2_FORCE_INTERP is set -> "
		     "NOT blocking boot; falling through to interpreter path (VERIFICATION MODE)");
		SetJitState(r);
		return true;
	}

	SetError("JIT 不可用（阶段 " + r.stage_name + "，errno=" +
		std::to_string(r.errno_value) + "）：" + r.message + " " + r.action);
	return false;
}

// 运行期复检：JIT 可用性不是静态属性（见 docs/jit-regression.md 的回归现象）。
// 发现能力消失时返回 false —— 调用方应停机并报告，而不是让核心切解释器。
//
// 注意：复检只用 Hps2JitCheck 自有的暂存页，**不触碰核心的 JIT 代码内存**
// （核心 arena 正在被活跃使用，写入探针指令会破坏已编译代码）。
bool RevalidateJitAlive() {
	// 先看核心自己是否还持有代码内存。若代码内存都没了，
	// VMManager 已经处于"静默降级"路径上，无需再做页级复检。
	if (!SysMemory::HasCodeMemory()) {
		Hps2JitCheck::Result r;
		r.available = false;
		r.stage = Hps2JitCheck::Stage::kRevalidate;
		r.stage_name = Hps2JitCheck::StageName(r.stage);
		r.message = "JIT 代码内存已丢失（核心已退回解释器）";
		r.action = "请重启手机后重试。";
		SetJitState(r);
		LOGE("JIT_REVALIDATE=failed reason=no-code-memory");
		return false;
	}

	Hps2JitCheck::Result r = Hps2JitCheck::RevalidateAlive();
	SetJitState(r);

	if (!r.available) {
		LOGE("JIT_REVALIDATE=failed stage=%{public}s errno=%{public}d msg=%{public}s",
			r.stage_name.c_str(), r.errno_value, r.message.c_str());
	}
	return r.available;
}

bool InitializeConfig() {
	// ---------------------------------------------------------------------
	// 【临时验证开关】强制解释器模式
	//
	// 目的：验证"商店包无法使用 JIT 时自动降级"这条路径**能否真正跑起来**。
	//
	// 背景：非 Apple 平台在 code memory 分配失败时直接 return false
	// （Memory.cpp），导致 CPUThreadInitialize 失败、VM 根本起不来 ——
	// 上游那段"切解释器"的降级逻辑（VMManager::UpdateCPUImplementations）
	// 因此永远走不到。所以在改设计前必须先确认降级路径的可达性。
	//
	// 真机无法通过 hdc 给应用域传环境变量，故在此显式设置。
	// 待验证结论确定后，本开关会被正式的编译期宏（HPS2_STORE_BUILD）替代。
	//
	// 注意：这是"验证用"的开关注入，不是最终设计。
	// ---------------------------------------------------------------------
	// 触发方式用**文件标记**而非环境变量：应用域无法通过 hdc 接收环境变量，
	// 而文件可以在设备上随时创建/删除，无需重新构建即可反复切换测试。
	//
	// 用法：
	//   开启  hdc shell "touch /data/storage/el2/base/haps/entry/files/FORCE_INTERP"
	//   关闭  hdc shell "rm /data/storage/el2/base/haps/entry/files/FORCE_INTERP"
	{
		const std::string marker = Path::Combine(s_data_root, "FORCE_INTERP");
		if (FileSystem::FileExists(marker.c_str()))
		{
			setenv("HPS2_FORCE_INTERP", "1", 1);
			LOGI("TEST: FORCE_INTERP marker present -> interpreter-only boot path");
		}
	}

	EmuFolders::AppRoot = s_data_root;
	EmuFolders::DataRoot = s_data_root;

	if (!EmuFolders::SetResourcesDirectory()) {
		SetError("EmuFolders::SetResourcesDirectory failed");
		return false;
	}

	EmuFolders::Bios = s_bios_dir;
	FileSystem::CreateDirectoryPath(EmuFolders::Cache.c_str(), true);
	FileSystem::CreateDirectoryPath(EmuFolders::Bios.c_str(), true);

	CrashHandler::SetWriteDirectory(EmuFolders::DataRoot);

	SetStage(BootStage::kHardwareCheck);
	const char* error = nullptr;
	if (!VMManager::PerformEarlyHardwareChecks(&error)) {
		SetError(std::string("hardware check failed: ") + (error ? error : "unknown"));
		return false;
	}

	SetStage(BootStage::kLoadingFonts);
	{
		const std::string roboto_path =
			EmuFolders::GetOverridableResourcePath("fonts" FS_OSPATH_SEPARATOR_STR "Roboto-Regular.ttf");
		const auto roboto_data = FileSystem::MapBinaryFileForRead(roboto_path.c_str());
		if (roboto_data.empty()) {
			SetError("failed to load font: " + roboto_path);
			return false;
		}

		std::vector<ImGuiManager::FontInfo> fonts;
		ImGuiManager::FontInfo fi{};
		fi.data = roboto_data;
		fi.exclude_ranges = {};
		fi.face_name = nullptr;
		fi.is_emoji_font = false;
		fonts.push_back(fi);
		ImGuiManager::SetFonts(std::move(fonts));
	}

	// ---------------------------------------------------------------------
	// 把核心的 Console 输出写到应用沙箱文件。
	//
	// 为什么必须这么做：核心的 Console 走 stdout，而 HAP 里的 stdout
	// 不进入 hilog —— 之前 GS 初始化失败时我们只看到
	// "VMManager::Initialize failed (result=1)"，完全看不到底层原因。
	// 上游提供了 Log::SetFileOutputLevel()，直接把日志写成文件更可靠。
	// 阶段 4 调试图形栈时这是必需的诊断手段。
	// ---------------------------------------------------------------------
	{
		const std::string log_path = Path::Combine(s_data_root, "emulog.txt");
		if (Log::SetFileOutputLevel(LOGLEVEL_TRACE, log_path))
			LOGI("core log -> %{public}s", log_path.c_str());
		else
			LOGW("failed to open core log at %{public}s", log_path.c_str());
	}

	SetStage(BootStage::kSettingsLayer);
	Host::Internal::SetBaseSettingsLayer(&s_settings_interface);
	VMManager::SetDefaultSettings(s_settings_interface, true, true, true, true, true);

	// 与 Android 一致：BIOS 目录经 settings 传入，而非只设 Folders 变量
	if (!s_bios_dir.empty())
		s_settings_interface.SetStringValue("Folders", "Bios", s_bios_dir.c_str());

	// ---------------------------------------------------------------------
	// 无头启动配置（照搬 pcsx2-eerunner/Main.cpp:1027-1055）
	//
	// 关键：GS 渲染器必须显式设为 Null。
	// 默认的 Auto 会让 GS 去初始化真实的图形后端，而 HAP 此时没有可用窗口，
	// GS 线程会卡在创建 device/context 上 —— 表现为进程存活、CPU 0%、
	// 启动停在 starting-thread。这正是先前卡住的原因。
	//
	// 注意（上游注释原文）：Null 渲染器**并非自足** ——
	//   GS's GetAPIForRenderer() has no Null case, so it falls through to
	//   GetPreferredRenderer() for the HOST device API.
	// 即设备 API 仍会被选择。若后续 GS 阶段仍卡，需在此进一步处理。
	//
	// 同时把 GS 设为同步执行（不建 MTGS 线程）、关闭 MTVU：
	// 这两项都是 eerunner 在确定性/无头模式下的配置，可减少线程依赖。
	// ---------------------------------------------------------------------
	// 有渲染表面 => OpenGL 真正出画面；无表面 => Null（只验证核心逻辑）。
	// 这样同一份代码既能做无头验证，也能真正显示游戏。
	{
		const Hps2Surface::Snapshot surf = Hps2Surface::Get();
		if (surf.ready && surf.window != nullptr)
		{
			s_settings_interface.SetIntValue("EmuCore/GS", "Renderer",
				static_cast<int>(GSRendererType::OGL));
			LOGI("renderer=OpenGL surface=%{public}dx%{public}d", surf.width, surf.height);
		}
		else
		{
			s_settings_interface.SetIntValue("EmuCore/GS", "Renderer",
				static_cast<int>(GSRendererType::Null));
			LOGW("renderer=Null (frontend supplied no surface)");
		}
	}

	// GS 同步在 CPU 线程上执行。异步 MTGS 需要独立的呈现线程，
	// 现阶段保持同步更可控；画面稳定后再评估打开异步的收益。
	s_settings_interface.SetBoolValue("EmuCore/GS", "SynchronousMTGS", true);
	s_settings_interface.SetBoolValue("EmuCore/Speedhacks", "vuThread", false);

	VMManager::Internal::LoadStartupSettings();
	// Keep the selected multiplier in the same settings layer that the later
	// VMManager::ApplySettings() reloads.  The CPU-thread injection below is
	// still needed because this frontend has no persistent PCSX2 ini file.
	s_settings_interface.SetFloatValue("EmuCore/GS", "upscale_multiplier",
		Hps2Video::GetUpscaleMultiplier());
	return true;
}

void VMThreadMain() {
	if (!VMManager::Internal::CPUThreadInitialize()) {
		SetError("CPUThreadInitialize failed");
		SetStage(BootStage::kFailed);
		return;
	}

	VMManager::ApplySettings();
	// Apply the frontend-selected graphics values before VMManager::Initialize()
	// opens GS.  Calling MTGS::ApplySettings() after initialization was both too
	// late to guarantee the initial render-target size and a source of delayed
	// renderer crashes on this device.
	Hps2Video::ApplyPendingConfigBeforeVM();

	VMBootParameters params;
	if (!s_game_path.empty())
	{
		// 与上游 GameList::FillBootParametersForEntry()（GameList.cpp:234-241）
		// 对 PS2 光盘镜像的处理一致：
		//   filename    = 镜像路径
		//   source_type = Iso
		//   elf_override = 空（必须是空，否则会被当成 ELF 覆盖启动）
		params.filename = s_game_path;
		params.source_type = CDVD_SourceType::Iso;
		params.elf_override.clear();
		LOGI("booting game image: %{public}s", s_game_path.c_str());
	}
	else
	{
		params.source_type = CDVD_SourceType::NoDisc;
		LOGI("booting BIOS only (no game image)");
	}

	const VMBootResult res = VMManager::Initialize(params);
	if (res != VMBootResult::StartupSuccess) {
		SetError("VMManager::Initialize failed (result=" + std::to_string(static_cast<int>(res)) + ")");
		VMManager::Internal::CPUThreadShutdown();
		SetStage(BootStage::kFailed);
		return;
	}
	LOGI("GS initialized with upscale emu=%{public}f gs=%{public}f",
		EmuConfig.GS.UpscaleMultiplier, GSConfig.UpscaleMultiplier);

	// ---------------------------------------------------------------------
	// 重编译器断言（拦截上游的"静默降级到解释器"）
	//
	// 上游 VMManager::UpdateCPUImplementations()（VMManager.cpp:2957）在
	// HasCodeMemory() 为假时会**不报错地**把 Cpu 指向 intCpu 解释器：
	//     Cpu = CHECK_EEREC ? &recCpu : &intCpu;
	// 这会让 VM "成功启动"却以解释器运行 —— 用户看到的是能跑但极慢。
	// 产品决策不降级，因此这里把该情况升级为**启动失败**。
	//
	// 判据用符号身份比较（Cpu == &intCpu），而非配置项：
	// 配置项只反映"用户想要什么"，符号身份才反映"实际选了谁"。
	// ---------------------------------------------------------------------
	if (!SysMemory::HasCodeMemory() || Cpu == &intCpu) {
		SetError("JIT 未生效：核心已静默退回解释器（PS2 模拟在解释器下不可用，已拒绝启动）");
		LOGE("JIT_ASSERT=failed has_code_memory=%{public}d cpu_is_interp=%{public}d",
			SysMemory::HasCodeMemory() ? 1 : 0, (Cpu == &intCpu) ? 1 : 0);

		// 记录到 JIT 状态，让 UI 能展示原因
		{
			Hps2JitCheck::Result jr;
			jr.stage = Hps2JitCheck::Stage::kRevalidate;
			jr.stage_name = Hps2JitCheck::StageName(jr.stage);
			jr.message = "核心已退回解释器（JIT 未生效）";
			jr.action = "请重启手机后重试；若仍失败，请反馈此结果。";
			SetJitState(jr);
		}

		g_vm_running.store(false);
		VMManager::Internal::CPUThreadShutdown();
		SetStage(BootStage::kFailed);
		return;
	}

	LOGI("JIT_ASSERT=passed cpu_is_recompiler=%{public}d",
		(Cpu == &recCpu) ? 1 : 0);

	// ---------------------------------------------------------------------
	// 虚拟手柄的自动按键映射 —— 必须在这里做，不能更早。
	//
	// 为什么不能像先前那样在 startBios() 返回后立刻做：
	//   输入源是**懒创建**的，只有 InputManager::ReloadSources() 跑过才填充
	//   s_input_sources[]（InputManager.cpp:1902）。而 ReloadSources()
	//   由 VMManager::LoadSettings()（VMManager.cpp:704）调用，后者在
	//   **CPU 线程**的 CPUThreadInitialize 内部执行。
	//
	//   若在更早的时机调用，InputManager::GetGenericBindingMapping()
	//   会在 s_input_sources[i]->IsInitialized()（InputManager.cpp:1885，
	//   **没有 null 检查**）处解引用空指针 → SIGSEGV → 应用闪退。
	//   这是真机上实测到的崩溃（日志停在 initVirtualPad -> 1）。
	//
	// 到这里时 VMManager::Initialize() 已完成，输入源必然存在。
	// ---------------------------------------------------------------------
	// The virtual joystick-added event is queued by SDL. Drain it through
	// PCSX2's SDL input source before asking for the player-id mapping;
	// otherwise the source exists but still has an empty controller list and
	// MapController() silently has nothing to bind. The UI creates the
	// virtual pad just after startBios(), so retry briefly to cover either
	// ordering without polling the input manager before VM init.
	bool virtual_pad_mapped = false;
	for (int attempt = 0; attempt < 20 && !virtual_pad_mapped; attempt++) {
		if (Hps2VPad::IsReady()) {
			InputManager::PollSources();
			virtual_pad_mapped = Hps2VPad::MapToPadPort(0);
		}
		if (!virtual_pad_mapped)
			std::this_thread::sleep_for(std::chrono::milliseconds(100));
	}
	if (virtual_pad_mapped)
		LOGI("virtual pad mapped to port 0");
	else
		LOGW("virtual pad mapping failed after retry window (see HPS2_VPAD)");

	LOGI("VM initialized; resuming execution");
	SetStage(BootStage::kRunning);
	// Keep the emulated console clock at its nominal NTSC/PAL cadence.
	//
	// This must not be Unlimited: on a 120 Hz phone display, Unlimited lets the
	// EE/GS loop run as fast as the host can execute it.  That also makes SPU2
	// produce audio too quickly, so both gameplay and audio become faster than
	// the PS2's 59.94/50 Hz timing.  VSync controls presentation, but the
	// nominal frame limiter is what keeps the emulated clock correct.
	VMManager::SetLimiterMode(LimiterModeType::Nominal);
	LOGI("emulation limiter set to nominal (PS2 video timing), independent of host display refresh");

	// ---------------------------------------------------------------------
	// 关键：解除暂停
	//
	// VMManager::Initialize() 在 hwReset() 之后会**主动**把状态设为 Paused
	// （VMManager.cpp:1812）。这是设计行为 —— VM 初始化完成但处于
	// "就绪未运行"状态，等前端决定何时开始。
	//
	// 若不解除，VMManager::Execute() 会因为状态是 Paused 而立刻返回，
	// 表现为：阶段显示 running、CPU 有少量占用、但 Execute() 每 1-2ms
	// 就返回一次（实测已调用 2 万多次），**实际没有执行任何 PS2 代码**。
	//
	// Qt 前端在 VM 启动后同样会调 SetPaused(false)（QtHost.cpp:826）。
	// eerunner 则是刻意保持 Paused，因为它的诊断模式需要单步控制 ——
	// 我们的场景不同，要让它真正跑起来。
	// ---------------------------------------------------------------------
	VMManager::SetPaused(false);
	LOGI("resumed; VM state=%{public}d", static_cast<int>(VMManager::GetState()));

	// 独立监控线程：周期采样 EE 的程序计数器与帧号。
	//
	// 为什么需要它：CPU 占用率只能区分"有活动"与"完全阻塞"，
	// **无法区分"空转"与"真正执行 PS2 代码"**（本项目已因此在
	// FrameAdvance 空转和 Paused 未恢复两种情况下误判过两次）。
	// EE 的 PC 变化才是真在执行 PS2 指令的直接证据。
	std::thread monitor([]() {
		// 一次性上报后端状态：这是判断 JIT 是否真正启用的权威依据。
		// 字段含义（对应 VMManager.cpp:483 的 @@CPU_BACKEND@@ 自报）：
		//   code_generation = JIT 代码内存是否分配成功（SysMemory::HasCodeMemory）
		//   ee_rec / iop_rec / vu0_rec / vu1_rec = 各重编译器是否启用
		//   fastmem = 快速内存访问是否启用
		// 芯片拓扑上报：这是判断"该用几个核、怎么并行"的事实依据，
		// 而不是从网页规格表推测。数据来自已链接的 cpuinfo 库，
		// 其 ARM 后端在阶段 2 已为本平台修复（平台白名单问题）。
		if (cpuinfo_initialize()) {
			const uint32_t clusters = cpuinfo_get_clusters_count();
			const uint32_t procs = cpuinfo_get_processors_count();
			const uint32_t cores = cpuinfo_get_cores_count();

			// cpuinfo 能给出处理器/物理核/簇的布局，但本设备内核没有
			// 暴露可用于确认 SMT 的 siblings/cpu cores 拓扑字段；因此
			// 不能用 processors == cores 推导“无 SMT”。
			LOGI("CHIP: clusters=%{public}u logical_processors=%{public}u physical_cores=%{public}u smt=%{public}s",
				clusters, procs, cores, "UNKNOWN");

			// 每个逻辑处理器的簇归属：用于记录异构簇布局；不据此判定 SMT。
			for (uint32_t pi = 0; pi < procs; ++pi) {
				const cpuinfo_processor* pr = cpuinfo_get_processor(pi);
				if (!pr)
					continue;
				LOGI("CHIP: proc[%{public}u] core_id=%{public}u cluster_idx=%{public}u",
					pi, pr->core ? pr->core->core_id : 9999u,
					pr->cluster ? pr->cluster->cluster_id : 9999u);
			}
			for (uint32_t ci = 0; ci < clusters; ++ci) {
				const cpuinfo_cluster* cl = cpuinfo_get_cluster(ci);
				if (!cl)
					continue;
				LOGI("CHIP: cluster[%{public}u] cores=%{public}u freq=%{public}lluMHz "
				     "uarch=%{public}u midr=0x%{public}08x",
					ci, cl->core_count,
					static_cast<unsigned long long>(cl->frequency / 1000000ull),
					static_cast<unsigned>(cl->uarch), cl->midr);
			}
		} else {
			LOGI("CHIP: cpuinfo_initialize() failed");
		}

		// ------------------------------------------------------------------
		// SMT（超线程）判定
		//
		// 判定依据（Linux/OHOS 通用约定）：
		//   /proc/cpuinfo 每个逻辑处理器块含：
		//     "cpu cores" = 同一物理封装内的**物理核数**
		//     "siblings"  = 同一物理封装内的**逻辑处理器数**
		//   若 siblings > cpu cores => 存在 SMT（超线程）
		//   若相等               => 无 SMT
		//
		// 这是内核给出的数字，不依赖 cpuinfo 库的微架构数据库
		// （该库不认识本芯片：uarch=0/freq=0MHz，其 smt 推断不可信）。
		//
		// 同时打印每个处理器的 CPU part / implementer，用于核对
		// 是否为 HiSilicon 自研核（MIDR 的 PartNum）。
		// ------------------------------------------------------------------
		{
			// 注意：不能用 FileSystem::ReadFileToString 读 procfs ——
			// 该函数按 st_size 分配缓冲，而 procfs 的 st_size **恒为 0**，
			// 因此会读到空串（这正是上一次探测 processors=0 的原因，
			// 不是权限问题）。procfs 必须流式读取。
			std::string t;
			if (std::FILE* fp = std::fopen("/proc/cpuinfo", "r")) {
				char buf[4096];
				while (std::fgets(buf, sizeof(buf), fp) != nullptr)
					t += buf;
				std::fclose(fp);
			}

			if (t.empty()) {
				LOGI("SMT: /proc/cpuinfo empty or unreadable");
			} else {
				LOGI("SMT: cpuinfo size=%{public}zu bytes", t.size());
				int nproc = 0, cores = -1, siblings = -1;
				std::string impl, part;

				// 逐行解析
				size_t pos = 0;
				while (pos < t.size()) {
					size_t eol = t.find('\n', pos);
					if (eol == std::string::npos)
						eol = t.size();
					std::string line = t.substr(pos, eol - pos);
					pos = eol + 1;

					auto val = [&](const char* key, std::string& out) {
						const std::string k = std::string(key) + "\t: ";
						const std::string k2 = std::string(key) + ": ";
						size_t p1 = line.find(k);
						if (p1 == 0) { out = line.substr(k.size()); return true; }
						size_t p2 = line.find(k2);
						if (p2 == 0) { out = line.substr(k2.size()); return true; }
						return false;
					};

					std::string v;
					if (val("processor", v)) {
						++nproc;
					} else if (val("cpu cores", v)) {
						if (cores < 0) cores = std::atoi(v.c_str());
					} else if (val("siblings", v)) {
						if (siblings < 0) siblings = std::atoi(v.c_str());
					} else if (val("CPU implementer", v)) {
						if (impl.empty()) impl = v;
					} else if (val("CPU part", v)) {
						if (part.empty()) part = v;
					}
				}

				const char* smt_state = (siblings > 0 && cores > 0) ?
					((siblings > cores) ? "YES" : "NO") : "UNKNOWN";
				LOGI("SMT: processors=%{public}d cpu_cores=%{public}d siblings=%{public}d => smt=%{public}s",
					nproc, cores, siblings, smt_state);
				LOGI("SMT: first CPU implementer=%{public}s part=%{public}s",
					impl.c_str(), part.c_str());

				// 打印 /proc/cpuinfo 的前 2 个处理器块原始内容，
				// 便于人工核对字段名是否如预期（不同内核版本字段可能有差异）
				size_t p = 0; int blocks = 0;
				while (blocks < 2 && p < t.size()) {
					size_t nxt = t.find("\n\n", p);
					std::string blk = (nxt == std::string::npos) ? t.substr(p) : t.substr(p, nxt - p);
					std::string joined;
					for (char ch : blk) joined += (ch == '\n') ? '|' : ch;
					LOGI("SMT: block[%{public}d]=%{public}s", blocks, joined.c_str());
					++blocks;
					if (nxt == std::string::npos) break;
					p = nxt + 2;
				}
			}
		}

		LOGI("BACKEND: code_generation=%{public}d ee_rec=%{public}d iop_rec=%{public}d "
		     "vu0_rec=%{public}d vu1_rec=%{public}d fastmem=%{public}d",
			SysMemory::HasCodeMemory() ? 1 : 0,
			EmuConfig.Cpu.Recompiler.EnableEE ? 1 : 0,
			EmuConfig.Cpu.Recompiler.EnableIOP ? 1 : 0,
			EmuConfig.Cpu.Recompiler.EnableVU0 ? 1 : 0,
			EmuConfig.Cpu.Recompiler.EnableVU1 ? 1 : 0,
			EmuConfig.Cpu.Recompiler.EnableFastmem ? 1 : 0);

		for (int i = 0; i < 6; ++i) {
			std::this_thread::sleep_for(std::chrono::seconds(3));
			LOGI("MONITOR: ee_pc=0x%{public}08x frame=%{public}llu vm_state=%{public}d",
				cpuRegs.pc,
				static_cast<unsigned long long>(PerformanceMetrics::GetFrameNumber()),
				static_cast<int>(VMManager::GetState()));
		}

		// ---------------------------------------------------------------
		// 运行期 JIT 看门狗（产品决策：不降级）
		//
		// 为什么必须有：JIT 可用性**不是设备的静态属性** —— 实测同一个
		// HAP 文件在运行 2 小时后出现所有 PROT_EXEC 请求返回 EINVAL
		// （见 docs/jit-regression.md）。若能力在游戏中途消失，继续跑
		// 只会崩溃或产出错误结果，而不是"变慢"。
		//
		// 处理方式：复检失败 => 主动停机并报告。
		// **不切解释器** —— 那正是本模块要拦截的静默降级。
		// ---------------------------------------------------------------
		int watchdog_tick = 0;
		while (g_vm_running.load()) {
			std::this_thread::sleep_for(std::chrono::seconds(3));
			++watchdog_tick;

			// 每 10 次采样（约 30 秒）复检一次，避免高频 mprotect 影响模拟性能。
			if ((watchdog_tick % 10) != 0)
				continue;

			if (!RevalidateJitAlive()) {
				LOGE("JIT_WATCHDOG=revoked 已停止模拟（不回退解释器）");
				SetError("JIT 能力在运行中失效，已停止模拟：" + GetJitMessage());
				g_vm_running.store(false);
				VMManager::SetPaused(true);
				SetStage(BootStage::kFailed);
				break;
			}
			LOGI("JIT_WATCHDOG=alive tick=%{public}d", watchdog_tick);
		}
	});

	// ---------------------------------------------------------------------
	// 真正的执行循环
	//
	// 注意（这是个易错点，先前的实现就错在这里）：
	//   VMManager::FrameAdvance(n) **不执行任何帧** ——
	//   它只是设置 s_frame_advance_count 并 SetState(Running)，
	//   是给"单步调试"用的计数器（见 VMManager.cpp:2536）。
	//   用它写 while 循环只会空转。
	//
	//   真正的执行入口是 VMManager::Execute() → Cpu->Execute()，
	//   它会**一直执行到被要求停止**（见 Qt 前端 QtHost.cpp:410）。
	//
	// 因此这里的模型是：
	//   反复调用 Execute()，每次它会跑一段并在状态改变时返回；
	//   只要状态仍是 Running 就继续，直到我们要求停止。
	// ---------------------------------------------------------------------
	LOGI("entering Execute loop");

	// 循环模型（与 Qt 前端 QtHost.cpp:404-410 一致）：
	// VMManager::Execute() 是**长跑**——上游注释原文：
	//   "Executes code until a break is signaled. Execution can be paused or
	//    suspended via thread-style signals ... a signal causes the Execute
	//    call to return at the nearest state check"
	// （见 pcsx2/R5900.h:416-421）
	// 因此它只在状态变化（暂停/停止/复位）时返回，不是每帧返回。
	// 外层 while 负责在它返回后重新进入，直到我们要求停止。
	//
	// 为便于外部验证"确实在模拟"，每次 Execute() 返回都记录状态与
	// 返回序号；只要 CPU 有持续占用且不返回，就说明在执行 PS2 代码。
	int execute_calls = 0;
	VMState last_state = VMState::Shutdown;
	while (g_vm_running.load()) {
		const VMState before = VMManager::GetState();
		if (before == VMState::Stopping || before == VMState::Shutdown) {
			LOGI("VM state=%{public}d, leaving Execute loop", static_cast<int>(before));
			break;
		}

		// 只在状态变化时报一次，避免高频刷屏。
		// 正常运行时状态恒为 Running，Execute() 会长时间不返回；
		// 若它频繁返回（且状态是 Paused），说明 VM 未被恢复。
		if (before != last_state) {
			LOGI("state -> %{public}d (Execute call #%{public}d)",
				static_cast<int>(before), execute_calls + 1);
			last_state = before;
		}

		VMManager::Execute();
		execute_calls++;

		// 每 5000 次返回报一次存活，正常应极少触发（Execute 是长跑）。
		if ((execute_calls % 5000) == 0) {
			LOGI("WARN: Execute returned %{public}d times, state=%{public}d "
			     "(频繁返回通常意味着 VM 处于 Paused)",
				execute_calls, static_cast<int>(VMManager::GetState()));
		}
	}
	LOGI("Execute loop ended after %{public}d calls", execute_calls);

	if (monitor.joinable())
		monitor.join();

	VMManager::Internal::CPUThreadShutdown();
	LOGI("VM thread exited");
}

}  // namespace

static napi_value NapiStartBios(napi_env env, napi_callback_info info) {
	size_t argc = 3;
	napi_value argv[3] = {nullptr, nullptr, nullptr};
	napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

	auto getStr = [&](size_t i, std::string& out) -> bool {
		if (i >= argc || argv[i] == nullptr) return false;
		size_t len = 0;
		napi_get_value_string_utf8(env, argv[i], nullptr, 0, &len);
		out.resize(len + 1);
		napi_get_value_string_utf8(env, argv[i], out.data(), len + 1, &len);
		out.resize(len);
		return true;
	};

	if (!getStr(0, s_data_root) || !getStr(1, s_bios_dir)) {
		SetError("startBios requires (dataRoot, biosDir, [gamePath])");
		SetStage(BootStage::kFailed);
		napi_value r; napi_create_int32(env, 0, &r); return r;
	}

	// 第三个参数可选：游戏镜像路径。不传或空字符串 => 只启动 BIOS。
	s_game_path.clear();
	getStr(2, s_game_path);

	if (g_vm_running.load()) {
		LOGI("already running");
		napi_value r; napi_create_int32(env, 1, &r); return r;
	}

	LOGI("startBios dataRoot=%{public}s biosDir=%{public}s",
	     s_data_root.c_str(), s_bios_dir.c_str());

	// ---------------------------------------------------------------------
	// JIT 硬门禁（产品决策：不降级）
	//
	// 必须在做任何重量级初始化**之前**判定：不可用时直接拒绝启动，
	// 并给出可操作建议。理由：
	//   - PS2 模拟器离开 JIT 就是幻灯片，降级没有产品意义；
	//   - 上游在 HasCodeMemory() 为假时会**静默**切到解释器，
	//     那会让用户以为"能跑"却得到不可用的性能 —— 必须显式拦截。
	// ---------------------------------------------------------------------
	if (!RunJitStartupCheck()) {
		SetStage(BootStage::kFailed);
		napi_value r; napi_create_int32(env, 0, &r); return r;
	}

	SetStage(BootStage::kSettingFolders);
	if (!InitializeConfig()) {
		SetStage(BootStage::kFailed);
		napi_value r; napi_create_int32(env, 0, &r); return r;
	}

	SetStage(BootStage::kReservingMemory);
	SysMemory::ReserveMemory();

	SetStage(BootStage::kStartingThread);
	g_vm_running.store(true);
	g_vm_thread = std::thread(VMThreadMain);

	napi_value r; napi_create_int32(env, 1, &r); return r;
}

// ---------------------------------------------------------------------------
// 虚拟手柄 N-API
//
// 供 ArkUI 的虚拟按键调用。把屏幕触控表达为 SDL 虚拟手柄，
// 经 SDLInputSource 进入 PCSX2 的 Pad —— 与真实手柄同一条路径。
// ---------------------------------------------------------------------------

// initVirtualPad() -> 1 成功 / 0 失败
static napi_value NapiInitVirtualPad(napi_env env, napi_callback_info info) {
	const bool ok = Hps2VPad::Initialize();
	if (!ok) {
		SetError("virtual pad initialization failed (见 HPS2_VPAD 日志)");
		napi_value r; napi_create_int32(env, 0, &r); return r;
	}
	napi_value r; napi_create_int32(env, 1, &r); return r;
}

// mapVirtualPad(port) -> 1/0  为手柄端口做自动按键映射
static napi_value NapiMapVirtualPad(napi_env env, napi_callback_info info) {
	size_t argc = 1;
	napi_value argv[1] = {nullptr};
	napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
	int32_t port = 0;
	if (argc >= 1)
		napi_get_value_int32(env, argv[0], &port);
	const bool ok = Hps2VPad::MapToPadPort(port);
	napi_value r; napi_create_int32(env, ok ? 1 : 0, &r); return r;
}

// enumerateControllers() -> JSON array of SDL real controllers
static napi_value NapiEnumerateControllers(napi_env env, napi_callback_info info) {
	const std::string json = Hps2VPad::EnumerateControllersJson();
	napi_value r;
	napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &r);
	return r;
}

// mapController(device, port) -> 1/0
static napi_value NapiMapController(napi_env env, napi_callback_info info) {
	size_t argc = 2;
	napi_value argv[2] = {nullptr, nullptr};
	napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
	if (argc < 2)
	{
		napi_value r;
		napi_create_int32(env, 0, &r);
		return r;
	}

	size_t length = 0;
	if (napi_get_value_string_utf8(env, argv[0], nullptr, 0, &length) != napi_ok || length == 0)
	{
		napi_value r;
		napi_create_int32(env, 0, &r);
		return r;
	}
	std::string device(length + 1, '\0');
	napi_get_value_string_utf8(env, argv[0], device.data(), length + 1, &length);
	device.resize(length);

	int32_t port = 0;
	napi_get_value_int32(env, argv[1], &port);
	const bool ok = Hps2VPad::MapControllerToPadPort(device, port);
	napi_value r;
	napi_create_int32(env, ok ? 1 : 0, &r);
	return r;
}

// setButton(button, pressed) —— button 为 SDL_GAMEPAD_BUTTON_*
static napi_value NapiVpadButton(napi_env env, napi_callback_info info) {
	size_t argc = 2;
	napi_value argv[2] = {nullptr, nullptr};
	napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

	int32_t button = 0;
	bool pressed = false;
	if (argc >= 2) {
		napi_get_value_int32(env, argv[0], &button);
		napi_get_value_bool(env, argv[1], &pressed);
	}
	Hps2VPad::SetButton(button, pressed);
	napi_value r; napi_create_int32(env, 1, &r); return r;
}

// setAxis(axis, value) —— axis 为 SDL_GAMEPAD_AXIS_*，value -32768..32767
static napi_value NapiVpadAxis(napi_env env, napi_callback_info info) {
	size_t argc = 2;
	napi_value argv[2] = {nullptr, nullptr};
	napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

	int32_t axis = 0, value = 0;
	if (argc >= 2) {
		napi_get_value_int32(env, argv[0], &axis);
		napi_get_value_int32(env, argv[1], &value);
	}
	Hps2VPad::SetAxis(axis, value);
	napi_value r; napi_create_int32(env, 1, &r); return r;
}

// ---------------------------------------------------------------------------
// 画面显示 N-API（宽高比 + 旋转适配）
//
// 供 ArkUI 在以下时机调用：
//   - 用户改变「画面比例」设置时 → setAspectMode
//   - 屏幕方向变化 / surface 尺寸变化时 → notifyResize
// ---------------------------------------------------------------------------

// setAspectMode(mode) -> 1/0
//   mode: 0=自动 1=保持4:3 2=铺满 3=宽屏16:9
static napi_value NapiSetAspectMode(napi_env env, napi_callback_info info) {
	size_t argc = 1;
	napi_value argv[1] = {nullptr};
	napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

	int32_t mode = 0;
	if (argc >= 1)
		napi_get_value_int32(env, argv[0], &mode);

	const bool ok = Hps2Video::SetAspectMode(static_cast<Hps2Video::AspectMode>(mode));
	napi_value r; napi_create_int32(env, ok ? 1 : 0, &r); return r;
}

// getAspectMode() -> number
static napi_value NapiGetAspectMode(napi_env env, napi_callback_info info) {
	napi_value r;
	napi_create_int32(env, static_cast<int32_t>(Hps2Video::GetAspectMode()), &r);
	return r;
}

// setUpscaleMultiplier(multiplier) -> 1/0
// 1.0=原生，允许范围 1.0..4.0；具体上限仍由 GS 根据设备纹理能力钳制。
static napi_value NapiSetUpscaleMultiplier(napi_env env, napi_callback_info info) {
	size_t argc = 1;
	napi_value argv[1] = {nullptr};
	napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

	double value = 1.0;
	if (argc >= 1)
		napi_get_value_double(env, argv[0], &value);

	const bool ok = Hps2Video::SetUpscaleMultiplier(static_cast<float>(value));
	napi_value r;
	napi_create_int32(env, ok ? 1 : 0, &r);
	return r;
}

// getUpscaleMultiplier() -> number
static napi_value NapiGetUpscaleMultiplier(napi_env env, napi_callback_info info) {
	napi_value r;
	napi_create_double(env, static_cast<double>(Hps2Video::GetUpscaleMultiplier()), &r);
	return r;
}

// notifyResize(width, height) -> 1/0
// 屏幕方向变化后必须调用 —— 仅改 surface 尺寸不够，
// GS 的正交投影是用 WindowInfo 尺寸算的（见 hps2_video.h 的说明）。
static napi_value NapiNotifyResize(napi_env env, napi_callback_info info) {
	size_t argc = 2;
	napi_value argv[2] = {nullptr, nullptr};
	napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

	int32_t w = 0, h = 0;
	if (argc >= 2) {
		napi_get_value_int32(env, argv[0], &w);
		napi_get_value_int32(env, argv[1], &h);
	}
	const bool ok = Hps2Video::NotifyResize(static_cast<unsigned int>(w), static_cast<unsigned int>(h));
	napi_value r; napi_create_int32(env, ok ? 1 : 0, &r); return r;
}

// setSurface(surfaceId: string, width: number, height: number) -> 1/0
//
// 由 ArkTS 在 XComponent 就绪后调用，把 ArkUI 的 surfaceId 转成
// OHNativeWindow* 交给 GS 作渲染目标。
//
// 为什么尺寸要一起传：我们走 surfaceId 路径，native 侧拿不到
// OH_NativeXComponent 的 component 指针，因而无法调用
// OH_NativeXComponent_GetXComponentSize()，尺寸只能由 ArkTS 侧提供。
static napi_value NapiSetSurface(napi_env env, napi_callback_info info) {
	size_t argc = 3;
	napi_value argv[3] = {nullptr, nullptr, nullptr};
	napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

	if (argc < 3) {
		SetError("setSurface requires (surfaceId, width, height)");
		napi_value r; napi_create_int32(env, 0, &r); return r;
	}

	size_t len = 0;
	napi_get_value_string_utf8(env, argv[0], nullptr, 0, &len);
	std::string sid;
	sid.resize(len + 1);
	napi_get_value_string_utf8(env, argv[0], sid.data(), len + 1, &len);
	sid.resize(len);

	int32_t w = 0, h = 0;
	napi_get_value_int32(env, argv[1], &w);
	napi_get_value_int32(env, argv[2], &h);

	uint64_t surface_id = 0;
	try {
		surface_id = std::stoull(sid);
	} catch (...) {
		SetError("setSurface: surfaceId not numeric: " + sid);
		napi_value r; napi_create_int32(env, 0, &r); return r;
	}

	LOGI("setSurface: id=%{public}llu %{public}dx%{public}d",
		static_cast<unsigned long long>(surface_id), w, h);

	OHNativeWindow* window = nullptr;
	const int32_t err = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surface_id, &window);
	if (err != 0 || window == nullptr) {
		SetError("OH_NativeWindow_CreateNativeWindowFromSurfaceId failed: " + std::to_string(err));
		napi_value r; napi_create_int32(env, 0, &r); return r;
	}

	{
		std::lock_guard<std::mutex> lock(Hps2Surface::g_mutex);
		Hps2Surface::g_window = window;
		Hps2Surface::g_width = w;
		Hps2Surface::g_height = h;
		Hps2Surface::g_ready = true;
	}
	Hps2Surface::g_cv.notify_all();

	LOGI("setSurface: OHNativeWindow OK (%{public}p)", static_cast<void*>(window));
	napi_value r; napi_create_int32(env, 1, &r); return r;
}

static napi_value NapiStop(napi_env env, napi_callback_info info) {
	g_vm_running.store(false);
	if (g_vm_thread.joinable())
		g_vm_thread.join();
	SetStage(BootStage::kIdle);
	napi_value r; napi_create_int32(env, 1, &r); return r;
}

static napi_value NapiGetStatus(napi_env env, napi_callback_info info) {
	const int stage = g_stage.load();
	std::string err;
	{
		std::lock_guard<std::mutex> lock(g_mutex);
		err = g_last_error;
	}

	auto esc = [](const std::string& s) {
		std::string o;
		for (char c : s) {
			if (c == '"' || c == '\\') o += '\\';
			if (c == '\n' || c == '\r') { o += ' '; continue; }
			o += c;
		}
		return o;
	};

	std::string json = "{";
	json += "\"stage\":" + std::to_string(stage);
	json += ",\"stageName\":\"" + std::string(StageName(static_cast<BootStage>(stage))) + "\"";
	json += ",\"running\":" + std::string(g_vm_running.load() ? "true" : "false");
	json += ",\"error\":\"" + esc(err) + "\"";
	const float fps = g_vm_running.load() ? PerformanceMetrics::GetFPS() : 0.0f;
	json += ",\"fps\":" + std::to_string(std::isfinite(fps) && fps > 0.0f ? fps : 0.0f);

	// JIT 状态一并上报：UI 需要在不启动的情况下也能显示"当前是否可用"。
	{
		std::lock_guard<std::mutex> lock(g_jit_mutex);
		json += ",\"jitAvailable\":" + std::string(g_jit_available.load() ? "true" : "false");
		json += ",\"jitStage\":\"" + esc(g_jit_stage) + "\"";
		json += ",\"jitErrno\":" + std::to_string(g_jit_errno);
		json += ",\"jitMessage\":\"" + esc(g_jit_message) + "\"";
		json += ",\"jitAction\":\"" + esc(g_jit_action) + "\"";
	}
	json += "}";

	napi_value r;
	napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &r);
	return r;
}

// checkJit() -> JSON
//
// 独立暴露 JIT 自检，供 UI 在**启动之前**（用户还在选 BIOS 时）就能查询，
// 让用户不必先点启动才发现 JIT 不可用。
//
// 语义：这是一次**完整**的自检（会重新申请页并执行代码），不是缓存查询。
// 返回 { available, stage, stageName, errno, message, action }
static napi_value NapiCheckJit(napi_env env, napi_callback_info info) {
	const Hps2JitCheck::Result r = Hps2JitCheck::RunStartupCheck();
	SetJitState(r);

	LOGI("JIT_CHECK_EXPLICIT available=%{public}d stage=%{public}s errno=%{public}d",
		r.available ? 1 : 0, r.stage_name.c_str(), r.errno_value);

	const std::string json = Hps2JitCheck::ToJson(r);
	napi_value out;
	napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &out);
	return out;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
	napi_property_descriptor desc[] = {
		{"startBios", nullptr, NapiStartBios, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"setSurface", nullptr, NapiSetSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"initVirtualPad", nullptr, NapiInitVirtualPad, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"mapVirtualPad", nullptr, NapiMapVirtualPad, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"enumerateControllers", nullptr, NapiEnumerateControllers, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"mapController", nullptr, NapiMapController, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"vpadButton", nullptr, NapiVpadButton, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"vpadAxis", nullptr, NapiVpadAxis, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"setAspectMode", nullptr, NapiSetAspectMode, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"getAspectMode", nullptr, NapiGetAspectMode, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"setUpscaleMultiplier", nullptr, NapiSetUpscaleMultiplier, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"getUpscaleMultiplier", nullptr, NapiGetUpscaleMultiplier, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"notifyResize", nullptr, NapiNotifyResize, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"stop",      nullptr, NapiStop,      nullptr, nullptr, nullptr, napi_default, nullptr},
		{"getStatus", nullptr, NapiGetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"checkJit",  nullptr, NapiCheckJit,  nullptr, nullptr, nullptr, napi_default, nullptr},
	};
	napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
	return exports;
}
EXTERN_C_END

static napi_module hps2CoreModule = {
	.nm_version = 1,
	.nm_flags = 0,
	.nm_filename = nullptr,
	.nm_register_func = Init,
	.nm_modname = "hps2core",
	.nm_priv = nullptr,
	.reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterHps2CoreModule(void) {
	napi_module_register(&hps2CoreModule);
}
