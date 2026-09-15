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
