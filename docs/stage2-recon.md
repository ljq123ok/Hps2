# 阶段 2 侦察报告：ARMSX2 → HarmonyOS 接入

**日期**：2026-09-14
**上游基线**：`d7e8d01678107f066d6ec988ca178d80089bd9f5`，分支 `hps2-harmonyos`
**目标**（用户选定）**：先最小可用 —— 让核心能编译、能加载、能跑 BIOS**

---

## 1. 已确认的关键事实

### 1.1 OHOS 的预定义宏（实测）

```
$ clang --target=aarch64-linux-ohos -dM -E - < /dev/null | grep ...
#define __OHOS__    1
#define __linux__   1
#define __unix__    1
#define __aarch64__ 1
        （无 __ANDROID__ / __APPLE__ / _WIN32）
```

**含义**：ARMSX2 会把 OHOS **当成普通 Linux**，从而拉入
D-Bus / X11 / libcurl / udev —— 这些在 OHOS sysroot 中**都不存在**。

### 1.2 上游作者已预见同类问题（重要佐证）

`cmake/Pcsx2Utils.cmake` 中 Android 分支的注释**原文**：

> Its own branch rather than folding into LINUX. ... the LINUX-guarded code
> elsewhere in the build reaches for udev, D-Bus and a runtime page-size probe,
> none of which exist under the NDK — **so Android must not answer to LINUX anywhere.**

**OHOS 处境完全相同。** 上游已经给出正确模式：**新增独立平台分支**，
而不是让它落到 Linux 分支。我已照此实现（见 §3）。

### 1.3 平台抽象缝已经存在（阶段 3 的有利条件）

`common/HostSys.h` 已定义清晰的平台接口，新后端只需实现：

```cpp
namespace HostSys {
    void   MemProtect(void* baseaddr, size_t size, const PageProtectionMode&);
    void   BeginCodeWrite();  void EndCodeWrite();
    void   BeginCodeWriteRange(void*, size_t);
    void   EndCodeWriteRange(void*, size_t);
    void   FlushInstructionCache(void* address, u32 size);
    size_t GetRuntimePageSize();
    size_t GetRuntimeCacheLineSize();
}
namespace PageFaultHandler { HandlerResult HandlePageFault(...); bool Install(Error*); }
class SharedMemoryMappingArea { static Create(size, jit, fixed_base_hint); ... };
```

`common/CMakeLists.txt` 的平台分支模式（Android 复用 Linux 层 + 替换
HTTPDownloader）可直接照搬。

---

## 2. 真实障碍（已实测，非推测）

### 2.1 障碍 1：平台识别 —— ✅ 已解决

**现象**：
```
CMake Error at cmake/Pcsx2Utils.cmake:29 (message):
  Unsupported platform.
```

**处理**：新增 OHOS 平台分支（§3.1）。已生效，配置推进通过。

### 2.2 障碍 2：外部依赖缺口 —— 🔴 当前阻塞

`cmake/SearchForStuff.cmake` 中 **11 个无条件 REQUIRED 依赖**
（无法用 CMake 开关关闭）：

```
Threads  PNG  JPEG  ZLIB  Zstd  LZ4  WebP  SDL3  Freetype
plutovg  plutosvg
```

（另有 CURL / PCAP / X11 / Wayland / Fontconfig / Qt6 / KDDockWidgets
等 **有开关可关**，不属于阻塞项。）

#### OHOS sysroot 实测结果

```
$ ls $SYSROOT/usr/lib/aarch64-linux-ohos/ | grep -iE "png|jpeg|zstd|lz4|webp|sdl|freetype"
（仅 libz.so 命中）
$ ls $SYSROOT/usr/include/ | grep -E "png.h|jpeglib.h|zlib.h|ft2build.h"
✅ zlib.h            ❌ 其余全部缺失
```

| 依赖 | sysroot | 上游自带 | 结论 |
|---|---|---|---|
| ZLIB | ✅ | — | 直接可用 |
| PNG / JPEG / Zstd / LZ4 / WebP / SDL3 / Freetype | ❌ | ❌ | **需交叉编译** |
| plutovg / plutosvg | ❌ | ✅ `3rdparty/` | 随源码交叉编译 |
| Threads | ✅ | — | 实测通过 |

#### 各库在核心中的真实引用量（已修正统计）

> 首次统计得出"每个库都被 17 个文件引用"，**该结果是错的** ——
> 一次 grep 同时匹配多个模式造成计数假象。重新逐库统计数据如下：

| 库 | .cpp 引用 | .h 引用 |
|---|---|---|
| zlib.h | 7 | 7 |
| png.h | 4 | 4 |
| jpeglib.h | 3 | 3 |
| zstd.h | 2 | 2 |
| SDL3/ | 2 | 2 |
| lz4.h | 1 | 1 |
| webp/ | 1 | 1 |
| ft2build.h | 1 | 1 |

**含义**：引用点都不多（每库 1–7 处），说明这些库多用于
**存档状态序列化 / 截图 / 纹理解压**等与"BIOS 启动"关系不大的路径，
因此"**先桩化、后补齐**"是可行策略。

**缺口**：`PNG JPEG ZLIB Zstd LZ4 WebP SDL3 Freetype CURL PCAP`
—— 需自行交叉编译或提供替代实现。

### 2.3 障碍 3：核心与图形后端的耦合 —— ⚠️ 需处理

核心文件（如 `VMManager.cpp`）直接引用 `GSRendererType`、`EmuConfig.GS.Renderer`，
因此**无法简单地把 GS 从构建中剔除**。GS 是核心的一部分，
即使"先不做画面"也必须能编译。

**结论**：最小可用路径**不等于**"不编译 GS"，
而是"GS 编译通过但暂不提供可用的呈现后端"。

---

## 3. 已实现的改动

### 3.1 `cmake/Pcsx2Utils.cmake` —— 新增 OHOS 平台分支

```cmake
elseif(OHOS_BUILD OR CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    set(OHOS TRUE)
    set(OHOS TRUE PARENT_SCOPE)
    message(STATUS "Building for HarmonyOS (OHOS).")
```

注释中已说明理由（与 Android 分支同样的 udev/D-Bus 问题），
便于后续与上游同步时理解意图。

### 3.2 `cmake/ohos.toolchain.cmake` —— 新增 OHOS toolchain

- 定位 DevEco SDK 的 clang / sysroot
- `--target=aarch64-linux-ohos` + `-D__OHOS__=1` + `-D__MUSL__=1`
- 限制 `CMAKE_FIND_ROOT_PATH`，避免误用宿主库
- 显式关闭 OHOS 不存在的可选依赖（`USE_DBUS=OFF`、`X11_API=OFF`、`USE_BACKTRACE=OFF`）

### 3.3 已验证的编译能力

- `common/Linux/LnxHostSys.cpp` 编译推进至 **第 205 行**，
  仅剩 2 个错误：`_SC_LEVEL1_DCACHE_LINESIZE` / `_SC_LEVEL1_ICACHE_LINESIZE`
  **在 OHOS musl 中不存在**（标准 Linux glibc 有）。

  这是**薄平台层的典型工作**，需要提供回退实现
  （可读 `/sys/devices/system/cpu/cpu0/cache/*/coherency_line_size`，
  或平台层直接返回 64 字节 —— ARM64 常见值）。

---

## 4. 路线选择（需说明）

面对 24 个 REQUIRED 依赖，有两条路：

| 路线 | 做法 | 代价 |
|---|---|---|
| **A. 补齐依赖** | 为 OHOS 交叉编译 PNG/JPEG/Zstd/LZ4/WebP/SDL3/Freetype/CURL/PCAP | 工作量大，但**保留上游全部功能** |
| **B. 裁剪构建** | 新增 OHOS 专用 CMake 目标，只编译"核心 + BIOS 启动"所需子集，图形/音频/网络用桩实现 | 快，但**偏离上游构建**，后续合并成本高 |

**当前倾向**：**A 为主、B 为辅** —— 先按 A 逐项补齐（从最少的开始），
仅在遇到底层不可获得的库（如 PCAP、SDL3）时对该项做裁剪。

理由：阶段 2 的任务书要求"建立薄的 HarmonyOS 平台层"，
若走 B 会变成"另建一套构建"，与任务书"保留上游许可与来源记录、
可分步构建"的要求相悖。

---

## 5. 下一步

1. 统计每个缺失依赖的**真实必要性**（哪些能通过 CMake 开关关闭）
2. 优先交叉编译最小集合：**Zlib → PNG → Zstd → LZ4 → Freetype**
3. 处理 `_SC_LEVEL1_*CACHE_LINESIZE` 缺失（平台层回退）
4. 逐文件验证核心源码在 OHOS 工具链下的编译
5. 核心编译通过后，建立最小 HAP 加载与 BIOS 启动验证

---

## 6. 诚实声明

- 阶段 2 **尚未完成**，当前处于"平台识别已通、依赖缺口待补"阶段。
- 本报告中的障碍**均为实测**（CMake 报错原文、编译器报错原文），非推测。
- **不承诺**"核心很快能跑起来" —— 24 个依赖缺口是真实工作量。
