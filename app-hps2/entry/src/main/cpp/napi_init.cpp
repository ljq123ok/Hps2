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

#include "common/CrashHandler.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/MemorySettingsInterface.h"
#include "common/Path.h"

#include "CDVD/CDVD.h"
#include "Config.h"
#include "Host.h"
#include "ImGui/ImGuiManager.h"
#include "Memory.h"
#include "PerformanceMetrics.h"
#include "R5900.h"   // cpuRegs（EE 程序计数器），用于进度监控
#include "VMManager.h"
#include "GS/GS.h"

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

bool InitializeConfig() {
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
	s_settings_interface.SetIntValue("EmuCore/GS", "Renderer",
		static_cast<int>(GSRendererType::Null));
	s_settings_interface.SetBoolValue("EmuCore/GS", "SynchronousMTGS", true);
	s_settings_interface.SetBoolValue("EmuCore/Speedhacks", "vuThread", false);

	VMManager::Internal::LoadStartupSettings();
	return true;
}

void VMThreadMain() {
	if (!VMManager::Internal::CPUThreadInitialize()) {
		SetError("CPUThreadInitialize failed");
		SetStage(BootStage::kFailed);
		return;
	}

	VMManager::ApplySettings();

	VMBootParameters params;
	params.source_type = CDVD_SourceType::NoDisc;

	const VMBootResult res = VMManager::Initialize(params);
	if (res != VMBootResult::StartupSuccess) {
		SetError("VMManager::Initialize failed (result=" + std::to_string(static_cast<int>(res)) + ")");
		VMManager::Internal::CPUThreadShutdown();
		SetStage(BootStage::kFailed);
		return;
	}

	LOGI("VM initialized; resuming execution");
	SetStage(BootStage::kRunning);
	VMManager::SetLimiterMode(LimiterModeType::Unlimited);

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
	size_t argc = 2;
	napi_value argv[2] = {nullptr, nullptr};
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
		SetError("startBios requires (dataRoot, biosDir)");
		SetStage(BootStage::kFailed);
		napi_value r; napi_create_int32(env, 0, &r); return r;
	}

	if (g_vm_running.load()) {
		LOGI("already running");
		napi_value r; napi_create_int32(env, 1, &r); return r;
	}

	LOGI("startBios dataRoot=%{public}s biosDir=%{public}s",
	     s_data_root.c_str(), s_bios_dir.c_str());

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
	json += ",\"error\":\"" + esc(err) + "\"}";

	napi_value r;
	napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &r);
	return r;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
	napi_property_descriptor desc[] = {
		{"startBios", nullptr, NapiStartBios, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"stop",      nullptr, NapiStop,      nullptr, nullptr, nullptr, napi_default, nullptr},
		{"getStatus", nullptr, NapiGetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
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
