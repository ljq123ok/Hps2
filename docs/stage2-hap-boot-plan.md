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
