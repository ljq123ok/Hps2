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
 *  5. 不降级：本模块只做判定与报告，调用方在不可用时阻止启动。
 */

#include "hps2_jitcheck.h"

#include <cerrno>
#include <cstring>

#include <sys/mman.h>
#include <unistd.h>

namespace Hps2JitCheck
{
	namespace
	{
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

		inline size_t PageSize()
		{
			const long ps = sysconf(_SC_PAGESIZE);
			return (ps > 0) ? static_cast<size_t>(ps) : 4096u;
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
		}
		return "unknown";
	}

	Result RunStartupCheck()
	{
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
		return r;
	}

	Result RevalidateAlive()
	{
		if (g_scratch == nullptr)
		{
			// 没有暂存页 => 启动自检从未成功。视为不可用，不静默放过。
			Result r;
			r.stage = Stage::kRevalidate;
			r.stage_name = StageName(r.stage);
			r.message = "无法复检：启动自检未成功建立代码页";
			r.action = "请先执行启动自检；若仍失败，请反馈此结果。";
			return r;
		}

		return ProbeScratch(/*is_revalidate=*/true);
	}

	std::string ToJson(const Result& r)
	{
		auto esc = [](const std::string& s) {
			std::string o;
			o.reserve(s.size());
			for (char c : s)
			{
				if (c == '"' || c == '\\') { o += '\\'; o += c; continue; }
				if (c == '\n' || c == '\r') { o += ' '; continue; }
				o += c;
			}
			return o;
		};

		std::string j = "{";
		j += "\"available\":" + std::string(r.available ? "true" : "false");
		j += ",\"stage\":" + std::to_string(static_cast<int>(r.stage));
		j += ",\"stageName\":\"" + esc(r.stage_name) + "\"";
		j += ",\"errno\":" + std::to_string(r.errno_value);
		j += ",\"message\":\"" + esc(r.message) + "\"";
		j += ",\"action\":\"" + esc(r.action) + "\"}";
		return j;
	}
} // namespace Hps2JitCheck
