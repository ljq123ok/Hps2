/*
 * HPS2 — HarmonyOS JIT 能力探针
 *
 * 目的：在真机上、用「可被三方 HAP 使用」的方式，验证动态生成 AArch64 机器码
 *       的完整生命周期是否可行：
 *         申请 → 写入 → 提交执行 → 重复执行 → 重建 → 跨线程 → 释放后再建
 *
 * 设计原则（对应任务书阶段 0/1 的要求）：
 *  1. 不预设任何未经验证的内核接口。阶段 0 未在公开 NDK 中找到 JITFort 的
 *     可调用接口（无头文件、无导出符号），故此处**不写** MAP_FORT 调用代码，
 *     而是按优先级依次尝试多种「候选路径」，把每条路径的真实结果记录下来。
 *  2. 每条候选路径都独立上报 errno / 系统调用返回值，便于定位阻塞点。
 *  3. 无论成功与否都产出结构化报告，失败也是一种必须留存的结论。
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <sys/mman.h>
#include <unistd.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3201
#define LOG_TAG "HPS2_JIT"

#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

// ===========================================================================
// 平台能力探测：OHOS 是否提供 JITFort 相关的公开接口
// ===========================================================================
// 阶段 0 已确认公开 NDK 中不存在这些符号；此处仍做运行期检查，
// 目的是把「头文件层面缺失」升级为「运行期可验证的事实」。
#ifdef __OHOS__
#define HPS2_TARGET_OHOS 1
#else
#define HPS2_TARGET_OHOS 0
#endif

namespace {

// ---------------------------------------------------------------------------
// AArch64 代码生成
// ---------------------------------------------------------------------------
// 生成一个极简函数： int f(void) { return imm; }
//   movz w0, #imm      ; 将 16 位立即数装入 w0（返回值寄存器）
//   ret                ; 返回
// 编码（AArch64 固定 32 位指令）：
//   MOVZ Wd, #imm16  ->  0x52800000 | (imm16 << 5) | Rd
//   RET              ->  0xD65F03C0
uint32_t EncodeMovzW0(uint16_t imm16) {
    return 0x52800000u | (static_cast<uint32_t>(imm16) << 5) | 0u /* Rd = w0 */;
}
constexpr uint32_t kRet = 0xD65F03C0u;

// 可选：把两个数相加，用于验证「多次重建 + 不同函数体」都正确
//   add w0, w0, #imm12  ->  0x11000000 | (imm12 << 10) | (Rn << 5) | Rd
uint32_t EncodeAddW0Imm12(uint16_t imm12) {
    return 0x11000000u | (static_cast<uint32_t>(imm12 & 0xFFF) << 10) | (0u << 5) | 0u;
}

using JitFnInt = int (*)();

// ---------------------------------------------------------------------------
// 代码内存候选路径
// ---------------------------------------------------------------------------
enum class MemStrategy {
    // 路径 A：先 RW 申请，写入后 mprotect 改为 RX（W^X 合规的标准做法）
    //          这是最可能被系统接受的方案，因为它全程不出现 W+X 同时有效。
    kRwThenRx,
    // 路径 B：一次性申请 RWX（可写可执行）匿名内存。
    //          预期在 OHOS 上被拒绝（需 ALLOW_WRITABLE_CODE_MEMORY 权限）。
    kRwx,
    // 路径 C：MAP_JITFORT 风格的标志位（stage0 未确认其存在，故用探测值）。
    //          仅为验证「传入未知标志是否被内核忽略或拒绝」。
    kFortFlagProbe,
};

struct AllocResult {
    void *addr         = nullptr;
    int   errnoVal     = 0;
    int   protUsed     = 0;
    int   mprotectRet  = 0;
    int   mprotectErrno = 0;
    bool  ok           = false;
};

const char *StrategyName(MemStrategy s) {
    switch (s) {
        case MemStrategy::kRwThenRx:      return "A:rw-then-rx(mprotect)";
        case MemStrategy::kRwx:           return "B:rwx-mmap";
        case MemStrategy::kFortFlagProbe: return "C:fort-flag-probe";
    }
    return "?";
}

// 申请一页代码内存。返回结构体而非裸指针，以便把失败细节一并上报。
AllocResult AllocateCodePage(MemStrategy strategy, size_t size) {
    AllocResult r;
    errno = 0;

    if (strategy == MemStrategy::kRwThenRx) {
        // 先 RW 分配，避免出现 W|X 同时置位的映射
        void *p = mmap(nullptr, size, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) {
            r.errnoVal = errno;
            r.addr = nullptr;
            return r;
        }
        r.addr = p;
        r.protUsed = PROT_READ | PROT_WRITE;
        r.ok = true;  // 写入阶段成功；执行前还需 mprotect
        return r;
    }

    if (strategy == MemStrategy::kRwx) {
        void *p = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) {
            r.errnoVal = errno;
            return r;
        }
        r.addr = p;
        r.protUsed = PROT_READ | PROT_WRITE | PROT_EXEC;
        r.ok = true;
        return r;
    }

    // 路径 C：探测 MAP_FORT。
    // AOSP 的 MAP_JIT 是 0x800；OHOS 阶段 0 未确认具体值，
    // 这里刻意用两个候选值分别尝试，观察内核是忽略还是返回 EINVAL。
    // 注意：这是「探测」，不是「实现」——若返回 EINVAL 即证明该标志不被接受。
    {
        constexpr int kProbeFlags[] = {0x800 /*AOSP MAP_JIT*/, 0x1000000 /*高位试探*/};
        for (int flag : kProbeFlags) {
            errno = 0;
            void *p = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                           MAP_PRIVATE | MAP_ANONYMOUS | flag, -1, 0);
            if (p != MAP_FAILED) {
                // 内核忽略了未知标志位，映射本身成功
                munmap(p, size);
                r.ok = false;
                r.errnoVal = 0;
                r.protUsed = PROT_READ | PROT_WRITE | PROT_EXEC;
                // 记下「被忽略」这一事实
                r.mprotectRet = -1;
                continue;
            }
            r.errnoVal = errno;
        }
        return r;
    }
}

// 提交：把 RW 区域变为 RX，并同步指令缓存
int CommitCode(MemStrategy strategy, void *addr, size_t size) {
    int ret = 0;
    if (strategy == MemStrategy::kRwThenRx) {
        errno = 0;
        ret = mprotect(addr, size, PROT_READ | PROT_EXEC);
        if (ret != 0) {
            return errno;
        }
    }
    // 指令缓存同步：ARM64 上通过 set___clear_cache（clang 内建）完成，
    // 它展开为 dc cvau / ic ivau / dsb / isb 序列。
    // 对同一核心自修改代码，实际依赖 ISB；跨核心需要内核协助。
    __builtin___clear_cache(static_cast<char *>(addr),
                            static_cast<char *>(addr) + size);
    __asm__ __volatile__("dsb ish\n\tisb" ::: "memory");
    return 0;
}

// ---------------------------------------------------------------------------
// 报告结构
// ---------------------------------------------------------------------------
struct StepResult {
    std::string name;
    bool ok = false;
    std::string detail;
};

std::vector<StepResult> g_steps;
std::atomic<int> g_seq{0};

void AddStep(const std::string &name, bool ok, const std::string &detail) {
    StepResult s;
    s.name = name;
    s.ok = ok;
    s.detail = detail;
    g_steps.push_back(s);
    if (ok) {
        LOGI("[OK]   %{public}s | %{public}s", name.c_str(), detail.c_str());
    } else {
        LOGE("[FAIL] %{public}s | %{public}s", name.c_str(), detail.c_str());
    }
}

std::string ErrnoStr(int e) {
    return std::string(strerror(e)) + " (errno=" + std::to_string(e) + ")";
}

// ---------------------------------------------------------------------------
// 测试 1：单页 RW→RX，执行一次，期望返回 123
// ---------------------------------------------------------------------------
bool TestBasicExecute(int *outValue, std::string *detail) {
    constexpr size_t kPage = 4096;
    constexpr int kExpected = 123;

    AllocResult a = AllocateCodePage(MemStrategy::kRwThenRx, kPage);
    if (!a.ok || a.addr == nullptr) {
        *detail = "mmap(RW) 失败: " + ErrnoStr(a.errnoVal);
        return false;
    }
    AddStep("1.1 mmap(RW)", true,
            "addr=" + std::to_string(reinterpret_cast<uintptr_t>(a.addr)));

    // 写入两条指令
    auto *code = static_cast<uint32_t *>(a.addr);
    code[0] = EncodeMovzW0(static_cast<uint16_t>(kExpected));
    code[1] = kRet;

    int mret = CommitCode(MemStrategy::kRwThenRx, a.addr, kPage);
    if (mret != 0) {
        *detail = "mprotect(RX) 失败: " + ErrnoStr(mret);
        munmap(a.addr, kPage);
        return false;
    }
    AddStep("1.2 mprotect(RW->RX) + icache flush", true, "提交成功");

    // 执行
    JitFnInt fn = reinterpret_cast<JitFnInt>(a.addr);
    volatile int value = fn();  // volatile 防止被优化掉
    *outValue = value;

    bool ok = (value == kExpected);
    *detail = "返回 " + std::to_string(value) + "，期望 " + std::to_string(kExpected);
    munmap(a.addr, kPage);
    return ok;
}

// ---------------------------------------------------------------------------
// 测试 2：重复执行同一块代码（验证代码页稳定、无一次性副作用）
// ---------------------------------------------------------------------------
bool TestRepeatedExecute(std::string *detail) {
    constexpr size_t kPage = 4096;
    AllocResult a = AllocateCodePage(MemStrategy::kRwThenRx, kPage);
    if (!a.ok || a.addr == nullptr) {
        *detail = "mmap 失败: " + ErrnoStr(a.errnoVal);
        return false;
    }
    auto *code = static_cast<uint32_t *>(a.addr);
    code[0] = EncodeMovzW0(77);
    code[1] = kRet;
    int mret = CommitCode(MemStrategy::kRwThenRx, a.addr, kPage);
    if (mret != 0) {
        *detail = "mprotect 失败: " + ErrnoStr(mret);
        munmap(a.addr, kPage);
        return false;
    }

    JitFnInt fn = reinterpret_cast<JitFnInt>(a.addr);
    constexpr int kIters = 10000;
    long long sum = 0;
    for (int i = 0; i < kIters; ++i) {
        sum += fn();
    }
    munmap(a.addr, kPage);

    bool ok = (sum == static_cast<long long>(77) * kIters);
    *detail = std::to_string(kIters) + " 次调用，sum=" + std::to_string(sum) +
              "，期望 " + std::to_string(77LL * kIters);
    return ok;
}

// ---------------------------------------------------------------------------
// 测试 3：代码重建（同一页内改指令 → 需要重新 RW→改→RX→flush）
//        这直接对应 JIT 的「代码修补」场景，是 HarmonyOS 代码签名约束的关键点。
// ---------------------------------------------------------------------------
bool TestRecompile(std::string *detail) {
    constexpr size_t kPage = 4096;
    void *p = mmap(nullptr, kPage, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        *detail = "mmap 失败: " + ErrnoStr(errno);
        return false;
    }

    auto emitAndRun = [&](uint16_t imm, int *out) -> bool {
        // 改回可写
        if (mprotect(p, kPage, PROT_READ | PROT_WRITE) != 0) {
            return false;
        }
        auto *code = static_cast<uint32_t *>(p);
        code[0] = EncodeMovzW0(imm);
        code[1] = kRet;
        if (mprotect(p, kPage, PROT_READ | PROT_EXEC) != 0) {
            return false;
        }
        __builtin___clear_cache(static_cast<char *>(p), static_cast<char *>(p) + kPage);
        __asm__ __volatile__("dsb ish\n\tisb" ::: "memory");
        JitFnInt f = reinterpret_cast<JitFnInt>(p);
        *out = f();
        return true;
    };

    int v1 = 0, v2 = 0, v3 = 0;
    bool ok = emitAndRun(11, &v1) && emitAndRun(222, &v2) && emitAndRun(3333, &v3);
    munmap(p, kPage);

    bool good = ok && v1 == 11 && v2 == 222 && v3 == 3333;
    *detail = "三次重建结果=" + std::to_string(v1) + "," + std::to_string(v2) + "," +
              std::to_string(v3) + "，期望 11,222,3333";
    return good;
}

// ---------------------------------------------------------------------------
// 测试 4：跨线程执行（JIT 代码在多线程下是否可用）
// ---------------------------------------------------------------------------
bool TestCrossThread(std::string *detail) {
    constexpr size_t kPage = 4096;
    void *p = mmap(nullptr, kPage, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        *detail = "mmap 失败: " + ErrnoStr(errno);
        return false;
    }
    auto *code = static_cast<uint32_t *>(p);
    code[0] = EncodeMovzW0(456);
    code[1] = kRet;
    if (mprotect(p, kPage, PROT_READ | PROT_EXEC) != 0) {
        *detail = "mprotect 失败: " + ErrnoStr(errno);
        munmap(p, kPage);
        return false;
    }
    __builtin___clear_cache(static_cast<char *>(p), static_cast<char *>(p) + kPage);
    __asm__ __volatile__("dsb ish\n\tisb" ::: "memory");

    constexpr int kThreads = 4;
    constexpr int kPerThread = 5000;
    std::atomic<int> failures{0};
    std::vector<std::thread> threads;

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&]() {
            JitFnInt fn = reinterpret_cast<JitFnInt>(p);
            for (int i = 0; i < kPerThread; ++i) {
                if (fn() != 456) {
                    failures.fetch_add(1);
                }
            }
        });
    }
    for (auto &th : threads) {
        th.join();
    }
    munmap(p, kPage);

    bool ok = (failures.load() == 0);
    *detail = std::to_string(kThreads) + " 线程 × " + std::to_string(kPerThread) +
              " 次，失败 " + std::to_string(failures.load()) + " 次";
    return ok;
}

// ---------------------------------------------------------------------------
// 测试 5：释放后重建（验证 munmap 后地址可被重新申请并再次执行）
// ---------------------------------------------------------------------------
bool TestFreeAndRealloc(std::string *detail) {
    constexpr size_t kPage = 4096;
    std::string log;

    for (int round = 0; round < 3; ++round) {
        void *p = mmap(nullptr, kPage, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) {
            *detail = "第 " + std::to_string(round) + " 轮 mmap 失败: " + ErrnoStr(errno);
            return false;
        }
        auto *code = static_cast<uint32_t *>(p);
        code[0] = EncodeMovzW0(static_cast<uint16_t>(100 + round));
        code[1] = kRet;
        if (mprotect(p, kPage, PROT_READ | PROT_EXEC) != 0) {
            *detail = "第 " + std::to_string(round) + " 轮 mprotect 失败: " + ErrnoStr(errno);
            munmap(p, kPage);
            return false;
        }
        __builtin___clear_cache(static_cast<char *>(p), static_cast<char *>(p) + kPage);
        __asm__ __volatile__("dsb ish\n\tisb" ::: "memory");

        JitFnInt fn = reinterpret_cast<JitFnInt>(p);
        int got = fn();
        log += "r" + std::to_string(round) + "=" + std::to_string(got) + " ";

        if (got != 100 + round) {
            *detail = "第 " + std::to_string(round) + " 轮结果错误: " + log;
            munmap(p, kPage);
            return false;
        }
        if (munmap(p, kPage) != 0) {
            *detail = "第 " + std::to_string(round) + " 轮 munmap 失败: " + ErrnoStr(errno);
            return false;
        }
    }
    *detail = "3 轮申请/执行/释放全部成功: " + log;
    return true;
}

// ---------------------------------------------------------------------------
// 测试 6：候选路径对照（RWX 与 FORT 标志探测）
//        这两项**预期失败**，失败结果本身就是阶段 0 结论的运行期证据。
// ---------------------------------------------------------------------------
void TestAlternativePaths(std::string *report) {
    constexpr size_t kPage = 4096;

    {
        AllocResult a = AllocateCodePage(MemStrategy::kRwx, kPage);
        if (a.ok) {
            AddStep("6.1 mmap(RWX) 直接申请", true,
                    "内核允许 W+X 匿名内存（addr=" +
                        std::to_string(reinterpret_cast<uintptr_t>(a.addr)) + "）");
            munmap(a.addr, kPage);
        } else {
            AddStep("6.1 mmap(RWX) 直接申请", false,
                    "被拒绝: " + ErrnoStr(a.errnoVal));
        }
        *report += std::string("RWX=") + (a.ok ? "allowed" : "denied") + "; ";
    }

    {
        AllocResult a = AllocateCodePage(MemStrategy::kFortFlagProbe, kPage);
        AddStep("6.2 MAP_JIT/FORT 标志探测", false,
                a.errnoVal != 0 ? ("标志被拒绝: " + ErrnoStr(a.errnoVal))
                                : "标志被内核忽略（映射成功但未生效）");
        *report += "FORT_PROBE=" + std::string(a.errnoVal != 0 ? "rejected" : "ignored");
    }
}

// ---------------------------------------------------------------------------
// 主测试入口
// ---------------------------------------------------------------------------
std::string RunAllTests() {
    g_steps.clear();
    std::string summary;

    LOGI("========== HPS2 JIT 探针开始 ==========");
    LOGI("TARGET_OHOS=%{public}d", HPS2_TARGET_OHOS);

    int basicValue = -1;
    std::string d;

    // 测试 1
    bool t1 = TestBasicExecute(&basicValue, &d);
    AddStep("1.3 执行生成代码并校验返回值", t1, d);

    // 测试 2
    bool t2 = TestRepeatedExecute(&d);
    AddStep("2.1 重复执行 10000 次", t2, d);

    // 测试 3
    bool t3 = TestRecompile(&d);
    AddStep("3.1 代码重建（RW→RX 往返 3 次）", t3, d);

    // 测试 4
    bool t4 = TestCrossThread(&d);
    AddStep("4.1 跨线程执行", t4, d);

    // 测试 5
    bool t5 = TestFreeAndRealloc(&d);
    AddStep("5.1 释放后重建", t5, d);

    // 测试 6
    std::string altReport;
    TestAlternativePaths(&altReport);

    // 汇总
    int pass = 0, fail = 0;
    for (const auto &s : g_steps) {
        if (s.ok) ++pass; else ++fail;
    }

    summary = "PASS=" + std::to_string(pass) + " FAIL=" + std::to_string(fail) +
              " | basicReturn=" + std::to_string(basicValue) + " | " + altReport;

    LOGI("========== HPS2 JIT 探针结束: %{public}s ==========", summary.c_str());
    return summary;
}

// 把步骤列表序列化成 JSON，供 ArkTS 侧展示
std::string StepsToJson() {
    std::string json = "[";
    for (size_t i = 0; i < g_steps.size(); ++i) {
        if (i) json += ",";
        json += "{\"name\":\"";
        // 极简转义：正文中不含引号与反斜杠
        json += g_steps[i].name;
        json += "\",\"ok\":";
        json += (g_steps[i].ok ? "true" : "false");
        json += ",\"detail\":\"";
        std::string det = g_steps[i].detail;
        std::string esc;
        for (char c : det) {
            if (c == '"' || c == '\\') { esc += '\\'; }
            if (c == '\n') { esc += ' '; continue; }
            esc += c;
        }
        json += esc;
        json += "\"}";
    }
    json += "]";
    return json;
}

}  // namespace

// ===========================================================================
// N-API 导出
// ===========================================================================
static napi_value NapiRunAll(napi_env env, napi_callback_info info) {
    std::string summary = RunAllTests();
    napi_value result;
    napi_create_string_utf8(env, summary.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

static napi_value NapiGetSteps(napi_env env, napi_callback_info info) {
    std::string json = StepsToJson();
    napi_value result;
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

// 单独暴露「平台事实」查询，便于在界面顶部显示环境
static napi_value NapiPlatformInfo(napi_env env, napi_callback_info cbInfo) {
    (void)cbInfo;
    std::string text;
    text += "arch=";
#if defined(__aarch64__)
    text += "arm64";
#elif defined(__arm__)
    text += "arm32";
#elif defined(__x86_64__)
    text += "x86_64";
#else
    text += "unknown";
#endif
    text += ";pagesize=" + std::to_string(sysconf(_SC_PAGESIZE));
    text += ";ohos=" + std::to_string(HPS2_TARGET_OHOS);
    text += ";ptrbits=" + std::to_string(sizeof(void *) * 8);
    napi_value result;
    napi_create_string_utf8(env, text.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"runAll",      nullptr, NapiRunAll,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSteps",    nullptr, NapiGetSteps,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"platformInfo", nullptr, NapiPlatformInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module jitProbeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "jitprobe",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterJitProbeModule(void) {
    napi_module_register(&jitProbeModule);
}
