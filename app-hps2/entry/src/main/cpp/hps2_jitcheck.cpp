/*
 * Hps2 — JIT 能力自检实现
 *
 * 实现要点（每条都对应一处已实测的事实，不引入未经验证的假设）：
 *  1. 只用「路径 C：RW→RX 分步映射」。真机实测该路径可用且零 AVC；
 *     MAP_JIT/MAP_FORT 在真机返回 EINVAL（明确拒绝），故**不使用**。
 *  2. 验证到「执行并校验返回值」为止。只做 mmap/mprotect 不足以证明可用 ——
 *     阶段 1 的教训是 mmap 可以成功而 mprotect(RX) 失败，必须真正执行一次。
 *  3. 指令缓存同步用 __builtin___clear_cache + dsb ish/isb（真机实测有效）。
 *  4. 只用本模块自有的暂存页，**绝不触碰核心的 JIT 代码内存**（见头文件说明）。
 *  5. 本模块只做开发构建的判定与报告；商店构建不运行探针。
 */

#include "hps2_jitcheck.h"

#include <cerrno>
#include <cstring>
#include <functional>
#include <mutex>
#include <thread>
#include <atomic>

#include <fcntl.h>     // open
#include <sys/mman.h>
#include <sys/stat.h>
#if defined(__OHOS__)
#include <sys/prctl.h>
#endif
#include <unistd.h>    // write/close/unlink

namespace Hps2JitCheck
{
	namespace
	{
		// StartupCheck 会释放并替换 scratch，RevalidateAlive 会改写同一块页。
		// 显式诊断按钮、启动检查和后台看门狗必须串行使用探针页。
		std::recursive_mutex g_probe_mutex;
		bool g_jit_init_done = false;
		bool g_prctl_attempted = false;
		bool g_prctl_accepted = false;
		int g_prctl_ret = -1;
		int g_prctl_errno = 0;
		bool g_prctl_recovery_done = false;
		bool g_prctl_recovery_accepted = false;
		int g_prctl_recovery_ret = -1;
		int g_prctl_recovery_errno = 0;
		bool g_memfd_probe_done = false;
		MemfdProbeResult g_memfd_probe;

		// AArch64 极简代码生成：int f(void) { return imm; }
		//   movz w0, #imm16   -> 0x52800000 | (imm16 << 5) | Rd(=0)
		//   ret               -> 0xD65F03C0
		constexpr uint32_t kRet = 0xD65F03C0u;

		inline uint32_t EncodeMovzW0(uint16_t imm16)
		{
			return 0x52800000u | (static_cast<uint32_t>(imm16) << 5);
		}

		using JitFnInt = int (*)();

		// 期望返回值。用 123 与阶段 1 探针保持一致 —— 便于与已有真机证据交叉核对。
		constexpr int kExpected = 123;

		inline void WriteProbeCode(void* p, int value = kExpected)
		{
			auto* code = static_cast<uint32_t*>(p);
			code[0] = EncodeMovzW0(static_cast<uint16_t>(value));
			code[1] = kRet;
		}

		inline size_t PageSize()
		{
			const long ps = sysconf(_SC_PAGESIZE);
			return (ps > 0) ? static_cast<size_t>(ps) : 4096u;
		}

		void AttachRuntimeDiagnostics(Result& r)
		{
			r.prctl_attempted = g_prctl_attempted;
			r.prctl_accepted = g_prctl_accepted;
			r.prctl_ret = g_prctl_ret;
			r.prctl_errno = g_prctl_errno;
			r.recovery_attempted = g_prctl_recovery_done;
			r.recovery_accepted = g_prctl_recovery_accepted;
			r.recovery_ret = g_prctl_recovery_ret;
			r.recovery_errno = g_prctl_recovery_errno;
			r.page_size = PageSize();
			const MemfdProbeResult memfd = ProbeMemfdDualMapping();
			r.memfd_attempted = memfd.attempted;
			r.memfd_supported = memfd.supported;
			r.memfd_initial_exec = memfd.initial_exec;
			r.memfd_alias_update = memfd.alias_update;
			r.memfd_loop = memfd.loop;
			r.memfd_concurrent = memfd.concurrent;
			r.memfd_errno = memfd.error;
			r.memfd_loop_iterations = memfd.loop_iterations;
			r.memfd_detail = memfd.detail;
			// Capability reporting must never switch the core backend implicitly.
			// Memfd remains an experiment even when its scratch probe succeeds.
			r.preferred_strategy = JitStrategy::AnonRwMprotect;
			const int fd = ::open("/proc/self/attr/current", O_RDONLY | O_CLOEXEC);
			if (fd >= 0)
			{
				char context[256] = {};
				const ssize_t n = ::read(fd, context, sizeof(context) - 1);
				::close(fd);
				if (n > 0)
				{
					r.selinux_context.assign(context, static_cast<size_t>(n));
					while (!r.selinux_context.empty() &&
						(r.selinux_context.back() == '\n' || r.selinux_context.back() == '\r'))
						r.selinux_context.pop_back();
				}
			}
		}

		// 指令缓存同步：ARM64 上必须显式同步，否则可能执行到旧指令。
		inline void FlushICache(void* addr, size_t size)
		{
			__builtin___clear_cache(static_cast<char*>(addr),
				static_cast<char*>(addr) + size);
			__asm__ __volatile__("dsb ish\n\tisb" ::: "memory");
		}

		inline std::string ErrnoStr(int e)
		{
			return std::string(strerror(e)) + " (errno=" + std::to_string(e) + ")";
		}

		// 面向用户的建议。这里刻意只给"能做什么"，不给"降级跑什么"——
		// 与产品决策一致（不做降级）。
		// errno=EINVAL 是实测过的真实故障模式：mprotect 加执行位被策略层判为无效。
		std::string ActionForProtExecDenied(int e)
		{
			if (e == EINVAL)
			{
				return "系统当前拒绝把内存标记为可执行。请重启手机后重试；"
					"若重启后仍失败，请反馈此错误码（EINVAL）。";
			}
			return "系统当前拒绝把内存标记为可执行（" + ErrnoStr(e) +
				"）。请重启手机后重试；若仍失败，请反馈此错误码。";
		}

		// -------------------------------------------------------------------
		// 自检专用暂存页
		//
		// 为什么保留而不是每次重新 mmap：
		//   运行期复检要判断的是"原本可用的映射是否仍然可用"，
		//   复用同一页才能真实反映该问题的状态；且复检频率可以很高（低开销）。
		//
		// 为什么不用核心的代码内存：
		//   核心 arena 正在被活跃使用，写入探针指令会破坏已编译代码。
		// -------------------------------------------------------------------
		void* g_scratch = nullptr;
		size_t g_scratch_size = 0;

		void ReleaseScratch()
		{
			if (g_scratch != nullptr)
			{
				munmap(g_scratch, g_scratch_size);
				g_scratch = nullptr;
				g_scratch_size = 0;
			}
		}

		// 写入探针指令 → 提交 RX → 执行 → 校验。scratch 必须已存在。
		// 这是"该页现在是否真的可执行"的完整判定。
		Result ProbeScratch(bool is_revalidate)
		{
			Result r;
			void* p = g_scratch;
			const size_t page = g_scratch_size;

			// ---- 取回可写权限 ----
			errno = 0;
			if (mprotect(p, page, PROT_READ | PROT_WRITE) != 0)
			{
				const int e = errno;
				r.stage = is_revalidate ? Stage::kRevalidate : Stage::kMprotectRx;
				r.stage_name = StageName(r.stage);
				r.errno_value = e;
				r.message = is_revalidate
					? "JIT 能力已失效（无法将代码页切回可写）"
					: "系统拒绝将内存标记为可写（JIT 被拦截）";
				r.action = ActionForProtExecDenied(e);
				return r;
			}

			// ---- 写入探针指令 ----
			auto* code = static_cast<uint32_t*>(p);
			code[0] = EncodeMovzW0(static_cast<uint16_t>(kExpected));
			code[1] = kRet;

			// ---- 提交为可执行（关键步骤）----
			errno = 0;
			if (mprotect(p, page, PROT_READ | PROT_EXEC) != 0)
			{
				const int e = errno;
				r.stage = is_revalidate ? Stage::kRevalidate : Stage::kMprotectRx;
				r.stage_name = StageName(r.stage);
				r.errno_value = e;
				r.message = is_revalidate
					? "JIT 能力已失效（无法将代码页重新提交为可执行）"
					: "系统拒绝将内存标记为可执行（JIT 被拦截）";
				r.action = ActionForProtExecDenied(e);
				return r;
			}

			// ---- 同步指令缓存并真正执行 ----
			// 只验证到 mprotect 是不够的：必须执行一次并校验返回值，
			// 才能排除"映射成功但代码不可执行"的情况。
			FlushICache(p, page);
			const JitFnInt fn = reinterpret_cast<JitFnInt>(p);
			const int got = fn();

			if (got != kExpected)
			{
				r.stage = Stage::kExecute;
				r.stage_name = StageName(r.stage);
				r.message = std::string(is_revalidate ? "JIT 复检" : "生成的代码") +
					"执行结果不正确（返回 " + std::to_string(got) +
					"，期望 " + std::to_string(kExpected) + "）";
				r.action = "这是严重错误，请反馈此结果。";
				return r;
			}

			r.available = true;
			r.stage = Stage::kOk;
			r.stage_name = StageName(r.stage);
			r.message = is_revalidate ? "JIT 仍可用" : "JIT 可用";
			return r;
		}
	} // namespace

	const char* StageName(Stage s)
	{
		switch (s)
		{
			case Stage::kOk:           return "ok";
			case Stage::kMmapRw:       return "mmap-rw";
			case Stage::kMprotectRx:   return "mprotect-rx";
			case Stage::kExecute:      return "execute";
			case Stage::kRevalidate:   return "revalidate";
			case Stage::kPolicyDisabled: return "policy-disabled";
		}
		return "unknown";
	}

	const char* StrategyName(JitStrategy strategy)
	{
		switch (strategy)
		{
			case JitStrategy::None: return "None";
			case JitStrategy::AnonRwMprotect: return "AnonRwMprotect";
			case JitStrategy::MemfdDualMapping: return "MemfdDualMapping";
		}
		return "None";
	}

	void InitializeHarmonyJit()
	{
		std::lock_guard<std::recursive_mutex> lock(g_probe_mutex);
		if (g_jit_init_done)
			return;
		g_jit_init_done = true;
#if defined(__OHOS__)
		g_prctl_attempted = true;
		errno = 0;
		g_prctl_ret = prctl(0x6a6974, 0UL, 0UL, 0UL, 0UL);
		g_prctl_errno = (g_prctl_ret == -1) ? errno : 0;
		g_prctl_accepted = (g_prctl_ret == 0);
#endif
	}

	bool TryHarmonyJitRecovery()
	{
		std::lock_guard<std::recursive_mutex> lock(g_probe_mutex);
		if (g_prctl_recovery_done)
			return g_prctl_recovery_accepted;
		g_prctl_recovery_done = true;
#if defined(__OHOS__)
		errno = 0;
		g_prctl_recovery_ret = prctl(0x6a6974, 0UL, 0UL, 0UL, 0UL);
		g_prctl_recovery_errno = (g_prctl_recovery_ret == -1) ? errno : 0;
		g_prctl_recovery_accepted = (g_prctl_recovery_ret == 0);
#else
		g_prctl_recovery_errno = ENOTSUP;
#endif
		return g_prctl_recovery_accepted;
	}

	Result RunStartupCheck()
	{
		std::lock_guard<std::recursive_mutex> lock(g_probe_mutex);
		Result r;

		// 幂等：重复调用先释放上一块暂存页。
		ReleaseScratch();

		const size_t page = PageSize();

		// ---- 阶段 1：申请可写内存 ----
		// 先 RW 而非 RWX：全程不出现 W+X 同时有效，这是最可能被系统接受的形态。
		errno = 0;
		void* p = mmap(nullptr, page, PROT_READ | PROT_WRITE,
			MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (p == MAP_FAILED)
		{
			r.stage = Stage::kMmapRw;
			r.stage_name = StageName(r.stage);
			r.errno_value = errno;
			r.message = "无法申请可写内存";
			r.action = "请重启手机后重试；若仍失败，请反馈此错误码。";
			AttachRuntimeDiagnostics(r);
			return r;
		}

		g_scratch = p;
		g_scratch_size = page;

		// ---- 阶段 2~4：写入 → 提交 → 执行 → 校验 ----
		// 成功后保留 scratch（保持 RX），供 RevalidateAlive() 复用。
		r = ProbeScratch(/*is_revalidate=*/false);
		if (!r.available)
		{
			ReleaseScratch();
		}
		AttachRuntimeDiagnostics(r);
		return r;
	}

	Result RevalidateAlive()
	{
		std::lock_guard<std::recursive_mutex> lock(g_probe_mutex);
		if (g_scratch == nullptr)
		{
			// 没有暂存页 => 启动自检从未成功。视为不可用，不静默放过。
			Result r;
			r.stage = Stage::kRevalidate;
			r.stage_name = StageName(r.stage);
			r.message = "无法复检：启动自检未成功建立代码页";
			r.action = "请先执行启动自检；若仍失败，请反馈此结果。";
			AttachRuntimeDiagnostics(r);
			return r;
		}

		Result r = ProbeScratch(/*is_revalidate=*/true);
		r.runtime_validation_attempted = true;
		r.runtime_validation_passed = r.available;
		AttachRuntimeDiagnostics(r);
		return r;
	}

	MemfdProbeResult ProbeMemfdDualMapping()
	{
		std::lock_guard<std::recursive_mutex> lock(g_probe_mutex);
		if (g_memfd_probe_done)
			return g_memfd_probe;
		g_memfd_probe_done = true;
		MemfdProbeResult& res = g_memfd_probe;
		res.attempted = true;

#if !defined(__OHOS__) || !defined(__aarch64__)
		res.error = ENOTSUP;
		res.detail = "memfd dual mapping probe requires HarmonyOS AArch64";
		return res;
#else
		constexpr size_t kSlotOffset = 64;
		constexpr int kLoopCount = 10000;
		const size_t page = PageSize();
		const int fd = memfd_create("hps2-jit-probe", MFD_CLOEXEC);
		if (fd < 0)
		{
			res.error = errno;
			res.detail = "memfd_create failed (errno=" + std::to_string(res.error) + ")";
			return res;
		}

		void* rw = MAP_FAILED;
		void* rx = MAP_FAILED;
		if (ftruncate(fd, static_cast<off_t>(page)) != 0)
		{
			res.error = errno;
			res.detail = "ftruncate failed (errno=" + std::to_string(res.error) + ")";
		}
		else
		{
			rw = mmap(nullptr, page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
			if (rw == MAP_FAILED)
			{
				res.error = errno;
				res.detail = "RW mmap failed (errno=" + std::to_string(res.error) + ")";
			}
			else
			{
				rx = mmap(nullptr, page, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
				if (rx == MAP_FAILED)
				{
					res.error = errno;
					res.detail = "RX mmap failed (errno=" + std::to_string(res.error) + ")";
				}
			}
		}

		if (rw != MAP_FAILED && rx != MAP_FAILED)
		{
			auto* const rw_bytes = static_cast<uint8_t*>(rw);
			auto* const rx_bytes = static_cast<uint8_t*>(rx);
			void* const rw_slot = rw_bytes;
			void* const rx_slot = rx_bytes;
			WriteProbeCode(rw_slot, 111);
			FlushICache(rx_slot, 8);
			res.initial_exec = (reinterpret_cast<JitFnInt>(rx_slot)() == 111);

			// Keep the RX alias mapped and unchanged while the RW alias updates code.
			WriteProbeCode(rw_slot, 222);
			FlushICache(rx_slot, 8);
			res.alias_update = (reinterpret_cast<JitFnInt>(rx_slot)() == 222);

			bool loop_ok = true;
			for (int i = 0; i < kLoopCount; ++i)
			{
				const int expected = 10000 + (i % 50000);
				WriteProbeCode(rw_slot, expected);
				FlushICache(rx_slot, 8);
				if (reinterpret_cast<JitFnInt>(rx_slot)() != expected)
				{
					loop_ok = false;
					res.loop_iterations = i + 1;
					break;
				}
			}
			if (loop_ok)
				res.loop_iterations = kLoopCount;
			res.loop = loop_ok;

			// Thread A repeatedly executes one immutable slot while thread B writes
			// and executes a separate slot; no instruction slot is concurrently mutated.
			constexpr size_t kSecondSlotOffset = kSlotOffset;
			if (page > kSecondSlotOffset + 8)
			{
				void* const rw_slot_a = rw_slot;
				void* const rx_slot_a = rx_slot;
				void* const rw_slot_b = rw_bytes + kSecondSlotOffset;
				void* const rx_slot_b = rx_bytes + kSecondSlotOffset;
				WriteProbeCode(rw_slot_a, 111);
				WriteProbeCode(rw_slot_b, 222);
				FlushICache(rx_slot_a, 8);
				FlushICache(rx_slot_b, 8);

				std::atomic<bool> start{false};
				std::atomic<bool> workers_ok{true};
				std::thread execute_existing([&]() {
					while (!start.load(std::memory_order_acquire)) {}
					for (int i = 0; i < kLoopCount; ++i)
						if (reinterpret_cast<JitFnInt>(rx_slot_a)() != 111)
							workers_ok.store(false, std::memory_order_relaxed);
				});
				std::thread generate_other_slot([&]() {
					while (!start.load(std::memory_order_acquire)) {}
					for (int i = 0; i < kLoopCount; ++i)
					{
						const int expected = 20000 + (i % 40000);
						WriteProbeCode(rw_slot_b, expected);
						FlushICache(rx_slot_b, 8);
						if (reinterpret_cast<JitFnInt>(rx_slot_b)() != expected)
							workers_ok.store(false, std::memory_order_relaxed);
					}
				});
				start.store(true, std::memory_order_release);
				execute_existing.join();
				generate_other_slot.join();
				res.concurrent = workers_ok.load(std::memory_order_relaxed);
			}
			res.supported = res.initial_exec && res.alias_update && res.loop && res.concurrent;
			res.detail = res.supported
				? "SUPPORTED: initial/update/10000-loop/separate-slot concurrency passed"
				: "UNSUPPORTED: one or more executable alias tests failed";
		}

		if (rw != MAP_FAILED)
			munmap(rw, page);
		if (rx != MAP_FAILED)
			munmap(rx, page);
		close(fd);
		return res;
#endif
	}

	PrctlExperimentResult RunPrctlExperiment()
	{
		std::lock_guard<std::recursive_mutex> lock(g_probe_mutex);
		PrctlExperimentResult out;
		out.startup_prctl_already_attempted = g_jit_init_done && g_prctl_attempted;
		out.call_thread_id = static_cast<uint64_t>(
			std::hash<std::thread::id>{}(std::this_thread::get_id()));
		out.before = RunStartupCheck();
#if defined(__OHOS__)
		out.attempted = true;
		errno = 0;
		out.return_value = prctl(0x6a6974, 0UL, 0UL, 0UL, 0UL);
		out.errno_value = (out.return_value == -1) ? errno : 0;
		out.accepted = (out.return_value == 0);
#else
		out.errno_value = ENOTSUP;
#endif
		// RunStartupCheck 会用新 scratch 建立第二次独立结果，避免把第一次
		// 检查遗留的映射状态误当成 prctl 后的结果。
		out.after = RunStartupCheck();
		return out;
	}

	std::string PrctlExperimentToJson(const PrctlExperimentResult& r)
	{
		return std::string("{\"attempted\":") + (r.attempted ? "true" : "false") +
			",\"accepted\":" + (r.accepted ? "true" : "false") +
			",\"startupPrctlAlreadyAttempted\":" +
				(r.startup_prctl_already_attempted ? "true" : "false") +
			",\"prctlRet\":" + std::to_string(r.return_value) +
			",\"prctlErrno\":" + std::to_string(r.errno_value) +
			",\"callThreadId\":" + std::to_string(r.call_thread_id) +
			",\"before\":" + ToJson(r.before) +
			",\"after\":" + ToJson(r.after) +
			",\"scope\":\"calling-thread-scratch-only\"}";
	}

	std::string ToJson(const Result& r)
	{
		auto esc = [](const std::string& s) {
			std::string o;
			o.reserve(s.size());
			constexpr char kHex[] = "0123456789abcdef";
			for (unsigned char c : s)
			{
				if (c == '"' || c == '\\') { o += '\\'; o += c; continue; }
				if (c < 0x20)
				{
					o += "\\u00";
					o += kHex[c >> 4];
					o += kHex[c & 0x0f];
					continue;
				}
				o += c;
			}
			return o;
		};

		std::string j = "{";
		j += "\"available\":" + std::string(r.available ? "true" : "false");
		j += ",\"stage\":" + std::to_string(static_cast<int>(r.stage));
		j += ",\"prctlAttempted\":" + std::string(r.prctl_attempted ? "true" : "false");
		j += ",\"prctlAccepted\":" + std::string(r.prctl_accepted ? "true" : "false");
		j += ",\"prctlRet\":" + std::to_string(r.prctl_ret);
		j += ",\"prctlErrno\":" + std::to_string(r.prctl_errno);
		j += ",\"prctlRecoveryAttempted\":" + std::string(r.recovery_attempted ? "true" : "false");
		j += ",\"prctlRecoveryAccepted\":" + std::string(r.recovery_accepted ? "true" : "false");
		j += ",\"prctlRecoveryRet\":" + std::to_string(r.recovery_ret);
		j += ",\"prctlRecoveryErrno\":" + std::to_string(r.recovery_errno);
		j += ",\"pageSize\":" + std::to_string(r.page_size);
		j += ",\"memfdAttempted\":" + std::string(r.memfd_attempted ? "true" : "false");
		j += ",\"memfdSupported\":" + std::string(r.memfd_supported ? "true" : "false");
		j += ",\"memfdInitialExec\":" + std::string(r.memfd_initial_exec ? "true" : "false");
		j += ",\"memfdAliasUpdate\":" + std::string(r.memfd_alias_update ? "true" : "false");
		j += ",\"memfdLoop\":" + std::string(r.memfd_loop ? "true" : "false");
		j += ",\"memfdConcurrent\":" + std::string(r.memfd_concurrent ? "true" : "false");
		j += ",\"memfdErrno\":" + std::to_string(r.memfd_errno);
		j += ",\"memfdLoopIterations\":" + std::to_string(r.memfd_loop_iterations);
		j += ",\"memfdDetail\":\"" + esc(r.memfd_detail) + "\"";
		j += ",\"runtimeValidationAttempted\":" + std::string(r.runtime_validation_attempted ? "true" : "false");
		j += ",\"runtimeValidationPassed\":" + std::string(r.runtime_validation_passed ? "true" : "false");
		j += ",\"preferredStrategy\":\"" + std::string(StrategyName(r.preferred_strategy)) + "\"";
		j += ",\"strategy\":\"" + esc(r.strategy) + "\"";
		j += ",\"selinuxContext\":\"" + esc(r.selinux_context) + "\"";
		j += ",\"stageName\":\"" + esc(r.stage_name) + "\"";
		j += ",\"errno\":" + std::to_string(r.errno_value);
		j += ",\"message\":\"" + esc(r.message) + "\"";
		j += ",\"action\":\"" + esc(r.action) + "\"}";
		return j;
	}
	// ===================================================================
	// 文件映射可执行内存探针（商店版专用）
	//
	// 设计原则与匿名探针一致：**必须真正执行一次并校验返回值**。
	// 只验证 mmap/mprotect 成功是不够的 —— 阶段 1 的教训就是
	// "映射可以成功而执行被拒"。
	//
	// 背景：release 签名（normal_hap 域）下匿名可执行内存被拒，但审查
	// SELinux 策略发现关键不对称 —— domain.te:354 的 exec_no_sign
	// neverallow **豁免了 normal_hap**，而 domain.te:355 的 exec_anon_mem
	// 没有。即被拒的可能是「匿名」属性而非「可执行」本身。
	// ===================================================================
	namespace
	{
		// 执行并校验。返回 true 表示"该形态确实可执行"。
		inline bool ExecuteAndVerify(void* p, int* out_got)
		{
			FlushICache(p, PageSize());
			const JitFnInt fn = reinterpret_cast<JitFnInt>(p);
			const int got = fn();
			if (out_got != nullptr)
				*out_got = got;
			return got == kExpected;
		}
	} // namespace

	FileProbeResult RunFileBackedJitProbe(const std::string& work_dir)
	{
		std::lock_guard<std::recursive_mutex> lock(g_probe_mutex);
		FileProbeResult res;
		const size_t page = PageSize();
		const std::string path = work_dir + "/.jitprobe.bin";

		// ---- 准备一个装有探针指令的模板文件 ----
		const int fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0700);
		if (fd < 0)
		{
			res.detail = "无法创建探针文件 (errno=" + std::to_string(errno) + ")";
			return res;
		}

		bool wrote_ok = false;
		{
			// 用匿名页先拼好内容，再写入文件
			void* tmp = mmap(nullptr, page, PROT_READ | PROT_WRITE,
				MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			if (tmp != MAP_FAILED)
			{
				WriteProbeCode(tmp);
				const ssize_t n = ::write(fd, tmp, page);
				wrote_ok = (n == static_cast<ssize_t>(page));
				munmap(tmp, page);
			}
		}
		if (!wrote_ok)
		{
			::close(fd);
			res.detail = "写入探针文件失败";
			return res;
		}

		// ===============================================================
		// 形态 B：文件映射 MAP_SHARED，RW → mprotect(RX) → 执行
		//
		// 与匿名路径的唯一区别是「映射来源是文件」。
		// 若此项成功而匿名路径失败，则证明被拒的是「匿名」属性。
		// ===============================================================
		{
			errno = 0;
			void* m = mmap(nullptr, page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
			if (m == MAP_FAILED)
			{
				res.b_errno = errno;
				res.detail += "B:文件映射(RW)失败 errno=" + std::to_string(errno) + "; ";
			}
			else
			{
				errno = 0;
				if (mprotect(m, page, PROT_READ | PROT_EXEC) != 0)
				{
					res.b_errno = errno;
					res.detail += "B:mprotect(RX)被拒 errno=" + std::to_string(errno) + "; ";
				}
				else
				{
					int got = -1;
					if (ExecuteAndVerify(m, &got))
					{
						res.b_success = true;
						res.detail += "B:成功(文件映射+RX可执行); ";
					}
					else
					{
						res.detail += "B:执行返回 " + std::to_string(got) + "(期望 " +
							std::to_string(kExpected) + "); ";
					}
				}
				munmap(m, page);
			}
		}

		// ===============================================================
		// 形态 C：双映射 —— 同一文件映射两块，一块 RW 写、一块 RX 执行
		//
		// 这是 iOS/ARMSX2 的 DarwinMisc::MmapCodeDualMap() 思路：
		// 全程不出现 W+X 同时有效的页，写入通过 RW 别名、
		// 执行通过 RX 别名，靠文件作为共享后端。
		// ===============================================================
		{
			errno = 0;
			void* rw = mmap(nullptr, page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
			void* rx = mmap(nullptr, page, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
			if (rw == MAP_FAILED || rx == MAP_FAILED)
			{
				res.c_errno = errno;
				res.detail += "C:双映射失败 errno=" + std::to_string(errno) + "; ";
				if (rw != MAP_FAILED) munmap(rw, page);
				if (rx != MAP_FAILED) munmap(rx, page);
			}
			else
			{
				// 通过 RW 别名改写指令，再从 RX 别名执行
				WriteProbeCode(rw);
				int got = -1;
				if (ExecuteAndVerify(rx, &got))
				{
					res.c_success = true;
					res.detail += "C:成功(RW/RX 双映射可执行); ";
				}
				else
				{
					res.detail += "C:执行返回 " + std::to_string(got) + "; ";
				}
				munmap(rw, page);
				munmap(rx, page);
			}
		}

		// ===============================================================
		// 形态 D：直接以 PROT_READ|PROT_EXEC 打开文件映射（不可写）
		//
		// 最严格的 W^X 形态：从来没有可写映射，因此不存在
		// "把只读映射提权为可执行"这一步，策略上可能被接受。
		// ===============================================================
		{
			errno = 0;
			void* m = mmap(nullptr, page, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
			if (m == MAP_FAILED)
			{
				res.d_errno = errno;
				res.detail += "D:直接RX映射失败 errno=" + std::to_string(errno) + "; ";
			}
			else
			{
				int got = -1;
				if (ExecuteAndVerify(m, &got))
				{
					res.d_success = true;
					res.detail += "D:成功(直接RX文件映射可执行); ";
				}
				else
				{
					res.detail += "D:执行返回 " + std::to_string(got) + "; ";
				}
				munmap(m, page);
			}
		}

		::close(fd);
		::unlink(path.c_str());

		res.any_success = res.b_success || res.c_success || res.d_success;
		if (res.detail.empty())
			res.detail = "无可用形态";
		return res;
	}
} // namespace Hps2JitCheck
