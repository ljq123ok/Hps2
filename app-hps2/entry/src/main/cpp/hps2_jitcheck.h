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
 * 产品决策（用户明确要求）：**不做降级**。
 *   上游 VMManager::UpdateCPUImplementations 在 HasCodeMemory() 为假时会
 *   **静默**把 Cpu 切成 intCpu 解释器。PS2 模拟器离开 JIT 就没有意义，
 *   与其让用户跑幻灯片，不如明确报告不可用 + 给出可操作的处理建议。
 *   本模块的职责边界：
 *     - 启动前：判定 JIT 是否可用，不可用则**阻止启动**；
 *     - 运行期：周期性复检，发现能力消失时由调用方**停机并报告**。
 *
 * 关键设计：**使用本模块自有的独立暂存页，绝不动核心的 JIT 代码内存。**
 *   核心的代码内存（EE/IOP/VU 重编译器 arena）正在被活跃使用，
 *   向其中写入探针指令会**破坏已编译的代码**。而"能否 mprotect 加执行位"
 *   是进程级策略问题，用一块独立页判定同样有效且完全安全。
 *
 * 依赖边界：本头文件不引入 PCSX2 头，纯 libc 接口，便于宿主侧单元测试。
 */
#pragma once

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
	};

	// 一次自检的完整结果。字段设计目标：UI 可直接展示，日志可直接检索。
	struct Result
	{
		bool available = false;   // JIT 当前是否可用
		Stage stage = Stage::kOk; // 失败阶段（kOk 表示通过）
		int errno_value = 0;      // 失败时的 errno（成功为 0）
		std::string stage_name;   // 阶段名（稳定标识，便于日志过滤）
		std::string message;      // 面向用户的一句话说明
		std::string action;       // 面向用户的可操作建议（不降级，只给行动）
	};

	// 阶段名（稳定字符串，用于日志与 UI 展示）
	const char* StageName(Stage s);

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

	// 把结果序列化为 JSON，供 N-API 直接返回给 ArkTS。
	// 字段：available / stage / stageName / errno / message / action
	std::string ToJson(const Result& r);
} // namespace Hps2JitCheck
