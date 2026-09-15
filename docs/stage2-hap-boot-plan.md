# 阶段 2：HAP 加载核心 + BIOS 启动验证 —— 实施方案

**目标**：让 PCSX2 核心在真机 HAP 内加载并完成可观察的 BIOS 启动。

---

## 1. 已确认的启动前提（读 eerunner 源码得出，非推测）

`pcsx2-eerunner/Main.cpp` 的 `main()` 与 `InitializeConfig()` 给出了
**启动核心所需的最小序列**：

```cpp
CrashHandler::Install();
InitializeConsole();

EmuFolders::SetAppRoot();
EmuFolders::SetResourcesDirectory();   // 必须成功
EmuFolders::SetDataDirectory(nullptr); // 必须成功

VMManager::PerformEarlyHardwareChecks(&error);

// 字体是**强制**前提：加载失败直接 return false
FileSystem::MapBinaryFileForRead("fonts/Roboto-Regular.ttf");

Host::Internal::SetBaseSettingsLayer(&si);
VMManager::SetDefaultSettings(...);
VMManager::Internal::LoadStartupSettings();

SysMemory::ReserveMemory();            // 保留 PS2 内存映射

std::thread cputhread(CPUThreadMain, &params, &thread_ret);
cputhread.join();
```

**关键发现**：`--renderer` 默认为 **`GSRendererType::Null`** ——
eerunner 是无头运行、不初始化图形后端的。这正是阶段 2 需要的形态：
**BIOS 启动验证不需要图形栈**，与阶段 4 解耦。

---

## 2. 资源依赖

| 资源 | 体积 | 必需性 |
|---|---|---|
| `resources/fonts/Roboto-Regular.ttf` | — | **强制**（失败即中止）|
| `resources/` 整体 | 9.8 MB | 打入 HAP |
| `GameIndex.yaml` / `RedumpDatabase.yaml` | 4.4 MB | 游戏库识别用，启动 BIOS 可省 |
| `resources/shaders/` | — | 仅图形后端需要（我们用 Null）|

---

## 3. 实施方案

### 3.1 HAP 结构

```
app-hps2/
├── entry/src/main/
│   ├── ets/                    ArkTS：UI + 生命周期
│   │   ├── entryability/       UIAbility
│   │   └── pages/Index.ets     BIOS 选择 / 启动状态显示
│   ├── cpp/                    N-API 桥接层
│   │   ├── napi_init.cpp       导出 startWithBios() 等
│   │   ├── hps2_host.cpp       复用 eerunner 的 Host 实现
│   │   └── CMakeLists.txt      链接 libPCSX2core.a
│   └── resources/rawfile/      打入 resources/（字体等）
```

### 3.2 核心库形态

当前 `PCSX2` 是 **OBJECT library**，无 `.a` 产物。
需要额外产出一个静态库供 HAP 链接：

- 可选方案 A：把 OBJECT 库改成 STATIC（改动上游 CMake）
- 可选方案 B：新建一个 `hps2_core` STATIC 目标，聚合 OBJECT 库的
  `$<TARGET_OBJECTS:PCSX2>`（**非侵入，倾向此方案**）

### 3.3 Host 接口复用

`pcsx2-eerunner/Main.cpp:216-525` 的 Host 实现区块（310 行）经核实
**零 Linux 专属依赖**，直接提取复用，只需：
- 去掉命令行解析相关部分
- 把 `ReportInfoAsync` / `ReportErrorAsync` 改为输出到 hilog
- 保留 `RunOnCPUThread` 等线程模型

### 3.4 文件访问

- **BIOS**：由用户在 App 内选择，或放在应用沙箱目录
- **resources**：打入 HAP 的 rawfile，首次启动解压到应用数据目录
  （`EmuFolders::SetResourcesDirectory` 需要一个真实文件系统路径）
- 不内置、不分发 BIOS；游戏 ISO 同样由用户提供

---

## 4. 验收标准（阶段 2 关口）

| 项目 | 标准 |
|---|---|
| 核心加载 | `.so` 在 HAP 内成功 dlopen 并初始化 |
| 资源定位 | `SetResourcesDirectory` / `SetDataDirectory` 返回成功 |
| 硬件检查 | `PerformEarlyHardwareChecks` 通过 |
| **BIOS 启动** | **用用户提供的合法 BIOS，产出可观察的启动流程** |
| 诊断可见 | 启动各阶段状态输出到 hilog 与 UI，失败时能定位到具体阶段 |

**"可观察"的定义**：核心完成 BIOS 加载并进入 EE 执行循环，
在日志中可见 BIOS 初始化输出（而非仅"没有崩溃"）。

---

## 5. 当前进度与下一步

- ✅ 核心编译通过（318/318 aarch64）
- ✅ 完整可执行文件链接成功（17MB，OHOS 库依赖）
- 🔄 HAP 骨架已建立，脚手架从阶段 1 复用（构建/签名/安装链路已验证）
- ⬜ 核心静态库目标
- ⬜ N-API 桥接 + Host 实现
- ⬜ 资源打包与路径适配
- ⬜ 真机 BIOS 启动验证

---

## 6. ✅ HAP 构建成功（2026-09-15）

```
BUILD SUCCESSFUL in 24s 591ms
```

| 项目 | 结果 |
|---|---|
| HAP 体积 | 17.4 MB |
| 内含 native 库 | `libs/arm64-v8a/libhps2core.so`，15.9 MB |
| 架构 | `ELF 64-bit LSB shared object, ARM aarch64` |
| 签名 | ✅ 用 `com.hps2.jitprobe` 的 debug 材料签名成功 |

### 6.1 BIOS 加载方案（按用户要求）

**BIOS 不内置、不打包、不分发** —— 用户自行准备，App 通过系统文件管理器加载。

实现路径（API 已核实）：

```
@ohos.file.picker 的 DocumentViewPicker.select()
  → 返回 URI 数组
fs.copyFileSync(uri, sandboxPath)
  → 复制进应用沙箱（核心需要 POSIX 路径，且外部 URI 授权是临时的）
```

UI 中显著位置标明"本应用不内置、不分发 BIOS"。

**未申请任何受限权限** —— 走系统文件选择器不需要读取整个文件系统的权限。

### 6.2 核心库形态

`PCSX2` 在 `DISABLE_ADVANCE_SIMD` 下是 **OBJECT 库**（无 `.a`），
外部工程无法链接。已在 fork 中新增 `PCSX2_CORE_STATIC` 聚合目标：

```cmake
if(OHOS)
    add_library(PCSX2_CORE_STATIC STATIC $<TARGET_OBJECTS:PCSX2>)
    ...
endif()
```

**不修改 PCSX2 本身**，只打包它已产出的对象；且仅 OHOS 下创建。
产物：`lib/libPCSX2core.a`，19.6 MB，319 个成员全部 aarch64。

### 6.3 链接期依次补齐的依赖

按报错顺序逐个补齐（非一次性猜测）：

| 缺失 | 处理 |
|---|---|
| `common::*` 符号 | 加入 `libcommon.a` |
| `Discord_*` / `cubeb_*` | 加入 `libdiscord-rpc.a` / `libcubeb.a` |
| `SDL_*` | 加入 `libSDL3.a`（实际交叉编译版，非 stub）|
| `pthread_setcanceltype` | 加入 SDL3 子代理留下的 `libohos_musl_compat.a` |

### 6.4 构建期踩到的坑

| 问题 | 根因 | 修正 |
|---|---|---|
| `thirdparty-ohos` 路径解析错 | `HPS2_REPO` 上溯 6 级，实际需 5 级 | 改为 5 级 |
| `Host` 未声明 | 提取 Host 实现时只取了函数体，漏掉 include 区块 | 补 include |
| `SimpleIni.h` 等找不到 | 3rdparty 的 include 路径未全加 | 补 12 个路径 |
| `LocaleCircleConfirm` 未声明 | 该声明在 ImGui UI 头文件中 | 补 ImGui 头 |

### 6.5 当前状态

- ✅ HAP 构建 + 签名完成
- ⬜ **真机安装**：USB 已物理断开，需重新连接
- ⬜ 真机 BIOS 启动验证

**下一步（需用户操作）**：
1. 重新连接手机 USB 并授权调试
2. 安装 HAP 后，在应用内点「选择 BIOS 文件」，
   从文件管理器中选中自己合法拥有的 PS2 BIOS
3. 点「启动核心」，观察各阶段状态

---

## 7. 真机启动验证：进展与一个关键硬件约束

### 7.1 BIOS 加载 ✅（fd 复制修复生效）

真机界面确认：`SCPH-70012_BIOS_V12_USA_200.bin (4.0 MB)`

**修复内容**：先前用 `copyFileSync(uri, path)` 直接传 URI，
报 `No such file or directory`。改为 fd 方式：

```
openSync(uri, READ_ONLY) → srcFd
openSync(dest, CREATE|READ_WRITE|TRUNC) → dstFd
copyFileSync(srcFd, dstFd)
```

picker 返回的 URI 需先解析成文件描述符才能读。

### 7.2 资源解压 ✅

HAP 内置 `resources/`（9.8MB，117 个文件），首次启动解压到
`<filesDir>/resources`。实测日志：

```
extracting resources to /data/storage/el2/base/haps/entry/files/resources
manifest entries=117
extracted 117/117 files
```

**实现方式**：构建期生成文件清单（`rawfile_manifest.json`），
运行期按清单逐条解压 —— 而非运行时递归遍历。
原因：`getRawFileList` 是否返回子目录、是否递归在文档中未明确，
依赖它容易出错；清单是确定的。HAP 体积因此从 17.6MB 增至 27.5MB。

**为什么需要解压**：`EmuFolders::SetResourcesDirectory()`
（`pcsx2/Pcsx2Config.cpp:2378`）在非 Apple 平台会去找
`<AppRoot>/resources`，目录不存在直接返回 `false`。HAP 内 rawfile
不是普通文件路径，核心读不到。

### 7.3 🔴 关键约束：编译期页大小与真机不匹配

真机报错：

```
hardware check failed: Page size mismatch.
This build cannot run on your system.
```

**根因**（`common/Pcsx2Defs.h:36-42`）：

```c
#elif defined(ARCH_ARM64)
	// Apple Silicon uses 16KB pages and 128 byte cache lines.
	static constexpr unsigned int __pagesize = 0x4000;   // 16KB
```

上游对 **ARCH_ARM64 硬编码 16KB 页**，注释写的是
"Apple Silicon uses 16KB pages" ——
**这是把 iOS/macOS 的假设套用到了所有 ARM64 平台。**

而真机实测（`/proc/self/smaps`）：

```
KernelPageSize:        4 kB
MMUPageSize:           4 kB
```

**HarmonyOS 真机是 4KB 页。**

`VMManager::PerformEarlyHardwareChecks()`（`VMManager.cpp:277-283`）
会比较编译期 `__pagesize` 与运行时 `HostSys::GetRuntimePageSize()`，
不一致即致命错误 —— 这个检查本身是对的（页大小确实必须匹配），
错的是我们对 OHOS 的编译期假设。

**处理**：上游已提供 `OVERRIDE_HOST_PAGE_SIZE` 机制，
Android/iOS 前端都在使用（见
`platforms/android/.../BuildParameters.cmake:153-174`）。
OHOS toolchain 同样启用：

```cmake
add_compile_definitions(
    OVERRIDE_HOST_PAGE_SIZE=0x1000        # 4KB，与真机一致
    OVERRIDE_HOST_CACHE_LINE_SIZE=64      # ARM64 默认 128 是 Apple 假设
)
```

**注意缓存行**：上游 ARM64 默认 128 字节（同为 Apple 假设），
ARM 通用实现通常是 64 字节，一并覆盖。

> 这类"把 Apple 假设当 ARM64 通用"的问题在本项目中已出现多次
> （页大小、缓存行、`preserve_all` 调用约定），
> 是移植到非 Apple 的 ARM64 平台时的**系统性风险**。

### 7.4 当前状态

- ✅ BIOS 加载（fd 复制）
- ✅ 资源解压（117/117）
- ✅ 页大小覆盖已加入 toolchain，核心正在重建
- ⬜ 重建后重新验证启动

---

## 8. 真机启动：逐阶段推进记录

### 8.1 当前进度（真机实测日志）

```
BIOS copied, size=4194304              ← BIOS 复制成功（4MB）
BOOT_STAGE=setting-folders             ✅ 过
BOOT_STAGE=hardware-check              ✅ 过（页大小修复生效）
BOOT_STAGE=loading-fonts               ✅ 过
BOOT_STAGE=settings-layer              ✅ 过
BOOT_STAGE=reserving-memory            ✅ 过
BOOT_STAGE=starting-thread             ✅ 过
BOOT_ERROR=CPUThreadInitialize failed  ❌ 卡在内部
```

**页大小修复（§7.3）确认生效** —— `hardware-check` 这次通过了。
BIOS 复制也成功（`size=4194304` 正好 4MB）。

### 8.2 本次阻塞：`CPUThreadInitialize` 失败

`VMManager::Internal::CPUThreadInitialize()`（`VMManager.cpp:438-505`）
只有两处 `return false`：

```cpp
if (!cpuinfo_initialize())
    Console.Error("cpuinfo_initialize() failed.");   // 仅记日志，不 return
...
if (!SysMemory::Allocate())                          // ← 真正的失败点
{
    Host::ReportErrorAsync("Error", "Failed to allocate VM memory.");
    return false;
}
```

`SysMemory::Allocate()`（`Memory.cpp:320`）的首个失败点是：

```cpp
if (!s_data_memory_file_handle && !AllocateMemoryMap())
    return false;
```

而 `AllocateMemoryMap()` 第一件事就是：

```cpp
s_data_memory_file_handle =
    HostSys::CreateSharedMemory(HostSys::GetFileMappingName("pcsx2").c_str(),
                                HostMemoryMap::MainSize);
```

### 8.3 根因：沙箱 HAP 无 `/dev/shm`

`HostSys::CreateSharedMemory()`（`common/Linux/LnxHostSys.cpp:136`）原本：

```cpp
#if defined(__ANDROID__)
    const int fd = memfd_create_wrapper(name, 0);    // Android 走这条
#else
    const int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);   // OHOS 落这里
```

上游注释已说明 Android 为何不用 `shm_open`：

> bionic lacks shm_open until API 30; ... the raw syscall works from API 26

**OHOS 有同类问题但原因不同**：NDK 头文件里 `shm_open()` 是有声明的
（`sys/mman.h:139`），但**沙箱化的 HAP 没有可写的 `/dev/shm`**，
调用会在运行时失败，导致 `AllocateMemoryMap()` 返回 false，
进而 `SysMemory::Allocate()` 失败 → `CPUThreadInitialize` 返回 false。

而这份代码**本来就不需要文件系统的共享内存** —— 看 `shm_open`
分支后面紧跟的 `shm_unlink(name)`：该映射从不在进程间共享。

### 8.4 处理

让 OHOS 复用 Android 的 `memfd_create` 路径（匿名文件映射，无需文件系统路径）：

```cpp
#if defined(__ANDROID__) || defined(__OHOS__)
    const int fd = memfd_create_wrapper(name, 0);
```

同时把 `memfd_create_wrapper`（`syscall(__NR_memfd_create, ...)`）
的启用条件一并扩展。

> 注：`HostSys::GetRuntimePageSize()` 走的是 `sysconf(_SC_PAGESIZE)`，
> 与页大小修复无关，此处不受影响。

---

## 9. 真机 BIOS 启动：达成与验证

### 9.1 启动阶段全部通过（真机日志）

```
BIOS copied, size=4194304        ✅ fd 复制成功（4MB）
BOOT_STAGE=setting-folders       ✅
BOOT_STAGE=hardware-check        ✅ 页大小修复生效
BOOT_STAGE=loading-fonts         ✅
BOOT_STAGE=settings-layer        ✅
BOOT_STAGE=reserving-memory      ✅
BOOT_STAGE=starting-thread       ✅
VM initialized; entering execution loop
entering Execute loop            ✅ 进入执行循环
```

### 9.2 本轮修复的两个问题

#### A. GS 渲染器未显式设置（我的 bug）

**现象**：阶段停在 `starting-thread`，进程存活、无崩溃、**CPU 0.00%**。

**诊断依据**：线程表已有 `CPU Thread` / `GS` / `MTVU`，
说明 `CPUThreadInitialize` 已成功；但 CPU 完全为 0 = **阻塞等待**，
指向 GS 初始化。

**根因**：我在代码注释里写了"沿用 Null 渲染器"，
但**实际没有设置它**。默认 `Auto` 会让 GS 去初始化真实图形后端，
而 HAP 此时没有可用窗口 → GS 线程卡在创建 device/context。

**处理**（照搬 eerunner 的无头配置）：

```cpp
Renderer = GSRendererType::Null          // 显式设置
SynchronousMTGS = true                   // GS 同步执行，不建 MTGS 线程
vuThread = false                         // 关闭 MTVU
```

> ⚠️ 上游注释提醒：**Null 渲染器并非自足** ——
> `GetAPIForRenderer()` 没有 Null 分支，会落到 `GetPreferredRenderer()`
> 去选宿主设备 API。若后续 GS 阶段仍卡，需进一步处理。

#### B. `FrameAdvance` 不执行帧（我的理解错误）

**我曾据截图报告"阶段 running = 成功"，但核对代码后发现那是假阳性。**

```cpp
void VMManager::FrameAdvance(u32 num_frames)
{
	s_frame_advance_count = num_frames;   // 只是设计数器
	SetState(VMState::Running);           // 只是改状态
}
```

`FrameAdvance()` **不执行任何帧**，是给单步调试用的计数器。
我写的 `while { FrameAdvance(1); }` 是纯空转 ——
所以"9 亿帧"会全部在同一毫秒内打出来（日志时间戳完全相同）。

**真正的执行入口**是 `VMManager::Execute()` → `Cpu->Execute()`
（Qt 前端 `QtHost.cpp:410` 即如此调用）。已修正：

```cpp
while (g_vm_running) { VMManager::Execute(); }
```

**`Execute()` 的语义**（`pcsx2/R5900.h:416-421` 上游原文）：

> Executes code until a break is signaled. Execution can be paused or
> suspended via thread-style signals ... a signal causes the Execute
> call to return at the nearest state check.

即**长跑**，只在状态变化时返回，不是每帧返回。

### 9.3 验证方法（区分"真在跑"与"空转/卡死"）

这是本项目一条重要的方法论：**界面文字或日志存在都不是成功证据**。

| 指标 | 假阳性（空转） | 真在跑 |
|---|---|---|
| **CPU 占用** | **0.00%** | **8.88% 持续**（用户态 9.91%）|
| 线程表 | CPU Thread 存在但 0% | CPU Thread / GS / MTVU 且活跃 |
| 日志时间戳 | 全部同一毫秒 | 分散 |

**CPU 占用是最硬的判据**：线程存在但 CPU 0% = 阻塞；
CPU 持续占用 = 真的在执行代码。

### 9.4 当前状态

- ✅ 阶段 2 核心接入完成：核心在真机上加载、初始化并进入执行循环
- ✅ 图形后端为 Null（阶段 2 与图形解耦）
- ⬜ **待确认**：EE 执行进度探针（本次构建已加，用于确认帧在推进）
- ⬜ 游戏镜像加载（阶段 3/4）
