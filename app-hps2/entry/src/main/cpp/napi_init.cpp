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
 *   → FrameAdvance 循环
 *
 * 为什么照搬移动端而不是 Qt：移动端（Android/iOS）与 HAP 同为沙箱环境，
 * 路径模型一致；Qt 桌面版的目录推导在沙箱下不成立。
 *
 * 图形后端：eerunner 默认 GSRendererType::Null，即不初始化图形栈。
 * 阶段 2 只验证 BIOS 启动，与图形解耦，故沿用 Null 渲染器，
 * 无需 OHNativeWindow / Vulkan。
 *
 * 线程模型：VM 运行在独立线程（与上游一致），N-API 只负责启停与状态查询。
 *
 * 范围限制：本阶段只启动 BIOS（CDVD_SourceType::NoDisc），不挂载游戏盘。
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#include <atomic>
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
#include "VMManager.h"

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

	LOGI("BIOS boot succeeded; entering frame loop");
	SetStage(BootStage::kRunning);
	VMManager::SetLimiterMode(LimiterModeType::Unlimited);

	int frames = 0;
	while (g_vm_running.load()) {
		VMManager::FrameAdvance(1);
		if ((++frames % 600) == 0)
			LOGI("VM alive: %{public}d frames advanced", frames);
	}

	VMManager::Internal::CPUThreadShutdown();
	LOGI("VM thread exited after %{public}d frames", frames);
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
