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
#define LOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

#include "common/CrashHandler.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/MemorySettingsInterface.h"
#include "common/Path.h"

#include <native_window/external_window.h>

#include "hps2_surface.h"

#include "CDVD/CDVD.h"
#include "Config.h"
#include "Host.h"
#include "ImGui/ImGuiManager.h"
#include "Memory.h"
#include "PerformanceMetrics.h"
#include "cpuinfo.h"      // 芯片拓扑探测
#include "R5900.h"   // cpuRegs（EE 程序计数器），用于进度监控
#include "VMManager.h"
#include "GS/GS.h"

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
		// 芯片拓扑上报：这是判断"该用几个核、怎么并行"的事实依据，
		// 而不是从网页规格表推测。数据来自已链接的 cpuinfo 库，
		// 其 ARM 后端在阶段 2 已为本平台修复（平台白名单问题）。
		if (cpuinfo_initialize()) {
			const uint32_t clusters = cpuinfo_get_clusters_count();
			const uint32_t procs = cpuinfo_get_processors_count();
			const uint32_t cores = cpuinfo_get_cores_count();

			// processor / core 计数对比是判断 SMT（超线程）的权威方法：
			//   processors = 逻辑处理器（SMT 线程）
			//   cores      = 物理核
			// 二者相等 => 无 SMT。
			// ARM 架构上公版核与 HiSilicon 自研核均不实现 SMT，
			// 这里用实测数据确认，而非依赖该论断。
			LOGI("CHIP: clusters=%{public}u logical_processors=%{public}u physical_cores=%{public}u smt=%{public}s",
				clusters, procs, cores, (procs > cores) ? "YES" : "NO");

			// 每个逻辑处理器的簇归属：用于确认 12 个"核"是 12 个独立物理核
			// 还是 6 核 x 2 线程。若每个 processor 都对应不同 core，则无 SMT。
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

				const bool smt = (siblings > 0 && cores > 0 && siblings > cores);
				LOGI("SMT: processors=%{public}d cpu_cores=%{public}d siblings=%{public}d => smt=%{public}s",
					nproc, cores, siblings, smt ? "YES" : "NO");
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
	json += ",\"error\":\"" + esc(err) + "\"}";

	napi_value r;
	napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &r);
	return r;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
	napi_property_descriptor desc[] = {
		{"startBios", nullptr, NapiStartBios, nullptr, nullptr, nullptr, napi_default, nullptr},
		{"setSurface", nullptr, NapiSetSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
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
