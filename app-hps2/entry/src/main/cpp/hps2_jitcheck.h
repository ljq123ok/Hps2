/*
 * Hps2 — JIT 能力自检（启动前 + 运行期复检）
 *
 * 为什么需要这个模块：
 *   阶段 1 探针已在真机证明「mmap(RW) → 写入 → mprotect(RX) → 执行」可用，
 *   但同时也观测到 JIT 可用性**不是设备的静态属性**：同一个 HAP 文件在
 *   2 小时后出现所有 PROT_EXEC 请求返回 EINVAL（见 docs/jit-regression.md）。
 *   上游 iOS 端有同构现象（iOS 会在运行期吊销 CS_DEBUGGED 授权），其对策是
 *   DarwinMisc::ValidateJITAlive() 的运行期复检 —— 本模块按同一思路实现。
 *
 * 产品策略：本模块只服务于 JIT 开发构建。
 *   - 启动前：判定 JIT 是否可用，不可用则阻止开发构建启动；
 *   - 运行期：周期性复检，发现能力消失时由调用方停机并报告。
 *   商店构建不调用此探针，而是在内存策略层固定选择解释器。
 *
 * 关键设计：**使用本模块自有的独立暂存页，绝不动核心的 JIT 代码内存。**
 *   核心的代码内存（EE/IOP/VU 重编译器 arena）正在被活跃使用，
 *   向其中写入探针指令会**破坏已编译的代码**。而"能否 mprotect 加执行位"
 *   是进程级策略问题，用一块独立页判定同样有效且完全安全。
 *
 * 依赖边界：本头文件不引入 PCSX2 头，纯 libc 接口，便于宿主侧单元测试。
 */
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace Hps2JitCheck
{
	// 探测失败所处的阶段。数值用于上报，稳定不变。
	enum class Stage : int
	{
		kOk = 0,            // 全部通过
		kMmapRw = 1,        // 申请可写内存失败
		kMprotectRx = 2,    // 关键：提交为可执行被拒（实测故障模式，errno=EINVAL）
		kExecute = 3,       // 生成的代码执行结果不正确
		kRevalidate = 4,    // 运行期复检失败（能力在运行中消失）
		kPolicyDisabled = 5, // 商店构建按发行策略不使用 JIT
	};

	// Capability backend identifiers. Memfd is reported as a capability only;
	// the core's preferred backend remains the existing anonymous RW→RX path.
	enum class JitStrategy : uint8_t
	{
		None,
		AnonRwMprotect,
		MemfdDualMapping,
	};

	// 一次自检的完整结果。字段设计目标：UI 可直接展示，日志可直接检索。
	struct Result
	{
		bool available = false;   // JIT 当前是否可用
		Stage stage = Stage::kOk; // 失败阶段（kOk 表示通过）
		int errno_value = 0;      // 失败时的 errno（成功为 0）
		bool prctl_attempted = false;
		bool prctl_accepted = false;
		int prctl_ret = -1;
		int prctl_errno = 0;
		bool recovery_attempted = false;
		bool recovery_accepted = false;
		int recovery_ret = -1;
		int recovery_errno = 0;
		size_t page_size = 0;
		bool memfd_attempted = false;
		bool memfd_supported = false;
		bool memfd_initial_exec = false;
		bool memfd_alias_update = false;
		bool memfd_loop = false;
		bool memfd_concurrent = false;
		int memfd_errno = 0;
		int memfd_loop_iterations = 0;
		std::string memfd_detail;
		bool runtime_validation_attempted = false;
		bool runtime_validation_passed = false;
		JitStrategy preferred_strategy = JitStrategy::AnonRwMprotect;
		std::string selinux_context;
		std::string strategy = "AnonRwMprotect";
		std::string stage_name;   // 阶段名（稳定标识，便于日志过滤）
		std::string message;      // 面向用户的一句话说明
		std::string action;       // 面向用户的可操作建议（不降级，只给行动）
	};

	struct MemfdProbeResult
	{
		bool attempted = false;
		bool supported = false;
		bool initial_exec = false;
		bool alias_update = false;
		bool loop = false;
		bool concurrent = false;
		int error = 0;
		int loop_iterations = 0;
		std::string detail;
	};

	// 阶段名（稳定字符串，用于日志与 UI 展示）
	const char* StageName(Stage s);
	const char* StrategyName(JitStrategy strategy);

	// HarmonyOS 兼容增强。只尝试一次，必须在启动 JIT scratch 自检前调用；
	// prctl 失败只记录诊断，不作为启动门禁。非 OHOS 返回 attempted=false。
	void InitializeHarmonyJit();
	// 运行期仅允许一次的恢复尝试；调用方必须在失败的复检线程上调用，
	// 随后立即在同一线程重新 RevalidateAlive()。
	bool TryHarmonyJitRecovery();

	// 启动前自检：完整走一遍 申请 → 写入 → 提交 → 执行 → 校验。
	// 这是"JIT 现在能不能用"的权威判定。
	//
	// 成功后**保留**该暂存页（保持 RX），供 RevalidateAlive() 复用；
	// 因此本函数是幂等的：重复调用会先释放上一次的页再重新判定。
	Result RunStartupCheck();

	// 运行期复检：在启动自检保留的暂存页上做一次轻量往返
	// （切回 RW → 写探针指令 → 切回 RX → 执行 → 校验）。
	//
	// 与启动自检的区别：不新申请内存，只验证既有页的"写入+提交+执行"仍可行；
	// 只触碰本模块自有的页，**不影响核心正在使用的 JIT 代码内存**。
	// 因此可以在运行期周期性调用。
	//
	// 若启动自检从未成功执行过（无暂存页），返回 available=false。
	Result RevalidateAlive();

	// 独立的 memfd RW/RX 双视图能力探针。只映射本函数创建的匿名代码页，
	// 不访问 ARMSX2 CodeCache；结果进程内缓存，后续读取不重复跑 10k 循环。
	MemfdProbeResult ProbeMemfdDualMapping();

	// 显式 A/B 实验：先在当前调用线程做普通 RW→RX 探针，再尝试
	// HarmonyOS 非标准 prctl，最后重新申请 scratch 页并重复探针。
	// 该结果只代表调用线程与探针页，不代表模拟器核心的 JIT arena。
	struct PrctlExperimentResult
	{
		bool attempted = false;
		bool accepted = false;
		bool startup_prctl_already_attempted = false;
		int return_value = -1;
		int errno_value = 0;
		uint64_t call_thread_id = 0;
		Result before;
		Result after;
	};

	PrctlExperimentResult RunPrctlExperiment();
	std::string PrctlExperimentToJson(const PrctlExperimentResult& r);

	// 把结果序列化为 JSON，供 N-API 直接返回给 ArkTS。
	// 字段：available / stage / stageName / errno / message / action
	std::string ToJson(const Result& r);

	// -------------------------------------------------------------------
	// 商店版专用：**文件映射**可执行内存探针
	//
	// 为什么必须单独测这一项（而不是复用上面的匿名映射自检）：
	//   release 签名（normal_hap 域）下，**匿名**可执行内存被拒
	//   （mprotect(RX) 返回 EINVAL，见 docs/release-jit-conclusion.md）。
	//   但审查 SELinux 策略源码发现一处**关键不对称**：
	//
	//     domain.te:354  neverallow {... -normal_hap ...} self:xpm { exec_no_sign };
	//        ← normal_hap **被豁免**：允许执行「未签名」的代码
	//     domain.te:355  neverallow {... }  self:xpm { exec_anon_mem };
	//        ← normal_hap **未被豁免**：不允许「匿名」可执行内存
	//
	//   即被拒的可能是「**匿名**」这个属性，而非「可执行」本身。
	//   文件映射的可执行内存是另一条策略路径，此前**从未实测过**。
	//
	//   这与 iOS 上的做法呼应：ARMSX2 的 DarwinMisc::MmapCodeDualMap()
	//   正是用「同一文件两个映射（RW + RX）」来规避单映射 W^X 限制。
	//
	// 本函数依次探测三种形态，并逐项报告成功/失败与 errno：
	//   B: 文件映射 MAP_SHARED，RW → mprotect(RX) → 执行
	//   C: 双映射（同文件 RW 写 + RX 执行两块映射）→ 执行
	//   D: 文件映射直接以 PROT_READ|PROT_EXEC 打开 → 执行
	//
	// 只要任一形态成功，商店版就有机会恢复真正的 JIT。
	// work_dir 用于存放探针临时文件（应用私有目录）。
	// -------------------------------------------------------------------
	struct FileProbeResult
	{
		bool any_success = false;
		bool b_success = false;   // 单映射 RW → mprotect(RX)
		bool c_success = false;   // 双映射（RW + RX）
		bool d_success = false;   // 直接以 RX 打开文件映射
		int b_errno = 0;
		int c_errno = 0;
		int d_errno = 0;
		std::string detail;       // 逐项的人类可读结论（供日志/UI）
	};

	FileProbeResult RunFileBackedJitProbe(const std::string& work_dir);
} // namespace Hps2JitCheck
