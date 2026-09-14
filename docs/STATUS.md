# HPS2 项目状态

**最后更新**：2026-09-14
**当前阶段**：阶段 0 已完成；阶段 1 **模拟器验证通过（PASS=8 / FAIL=1，生成代码返回 123）**；**真机验证未完成（阻塞）**

---

## 1. 记录基线（可复现）

| 项目 | 值 | 证据来源 |
|---|---|---|
| ARMSX2 提交 | `d7e8d01678107f066d6ec988ca178d80089bd9f5` | `git log -1` |
| ARMSX2 提交时间 | 2026-09-14 00:44:37 +0200 | 同上 |
| ARMSX2 提交标题 | `iOS: fixed/re-implemented Airplay (#591)` | 同上 |
| DevEco Studio | 6.1.1.300（DS-243.24978.46.36.611300） | `product-info.json` |
| HarmonyOS SDK | **6.1.1 / API 24** | `sdk/default/sdk-pkg.json` |
| SDK Native 版本 | 6.1.1.125 | `native/oh-uni-package.json` |
| NDK clang | 15.0.4 | `build/cmake/ohos.toolchain.cmake` |
| 宿主 | macOS 26.6.1，arm64 | `sw_vers` / `uname -m` |
| 真机 | **未连接，型号/系统/架构均未确认** | `hdc list targets` |

> ⚠️ **关于「HarmonyOS 7」**：本机 SDK 为 6.1.1 / API 24，`sdk-pkg.json` 中
> 不存在任何 "7" 版本标识，DevEco 可安装列表亦以 6.1.1 为最高级别。
> 因此所有结论基于**实际可用的 API 24 SDK**，不假设 HarmonyOS 7 独有接口存在。

---

## 2. 已完成能力

### 阶段 0：源码、SDK 与权限可行性审计 —— ✅ 完成

交付物：`docs/feasibility.md`

已完成：

1. **ARMSX2 源码结构审计**：确认仓库布局、平台前端（`platforms/` 下仅
   `android` 与 `ios`，**无 harmonyos**），锁定提交号。JIT/图形/音频子系统
   逐文件审计见 `docs/source-audit.md`。
2. **JIT 内存申请接口核实**（公开 NDK 全集）：
   - `grep -ril "jitfort"` / `grep -rl "MAP_FORT"` → **无结果**
   - 全部 NDK `.so` 的 `nm -D` 导出符号搜 `fort` → **无结果**
   - 结论：无头文件、无导出符号，**三方 HAP 无 JIT 接口可调**。
3. **`MAP_FORT` 性质确认**：源码中为 ArkTS 引擎私有常量
   `JitFort::MAP_JITFORT = 0x1000`，非内核公开 `mmap` 标志；
   且 `0x1000` 已被 `MAP_EXECUTABLE` 占用（语义不同）。
   → 因此本仓库**未写入任何 `MAP_FORT` 实现代码**。
4. **受限权限核实**：三项 JIT 相关权限均为 `system_basic` + `system_grant`；
   `ALLOW_WRITABLE_CODE_MEMORY` 文档限定「仅平板、2in1 设备」；
   官方 JIT 授权路径为 **JSVM + AGC ACL 审批**。
5. **坚盾守护模式**：确认其**全局禁用 JIT，含已获 ACL 的应用**。
6. **图形接口核实**：`libvulkan.so` + Vulkan 1.4 头文件 +
   `vulkan_ohos.h`（`vkCreateSurfaceOHOS` + `OHNativeWindow*`）**均为公开 NDK**。
7. **签名材料盘点**：本机有 `normal` 级调试证书/Profile，**不含 JIT ACL**。

### 阶段 1：真机 JIT 最小验证工程 —— ⚠️ 工程完成，运行未验证

交付物：`stage1-jitprobe/`

| 状态 | 项目 |
|---|---|
| ✅ | ArkTS + N-API + C++ 三层工程结构完整 |
| ✅ | `assembleHap` **构建成功**（BUILD SUCCESSFUL in 32s） |
| ✅ | 产物含 `libs/arm64-v8a/libjitprobe.so` |
| ✅ | 宿主侧（arm64 macOS）**同代码同流程执行返回 123 — PASS** |
| ✅ | 模拟器**安装成功**（允许未签名 HAP） |
| ✅ | **模拟器运行探针通过：PASS=8 / FAIL=1，生成代码返回 123**，3 次运行结果一致 |
| ❌ | **真机运行未完成**（USB 设备处于 Offline，见 §3） |

#### 模拟器实测结果（OpenHarmony-6.1.1.125 / API 24 / arm64-v8a）

设备事实上报：`arch=arm64;pagesize=4096;ohos=1;ptrbits=64`

| # | 测试 | 结果 | 实测数据 |
|---|---|---|---|
| 1.1 | `mmap(RW)` | ✅ | addr=547624173568 |
| 1.2 | `mprotect(RW→RX)` + icache flush | ✅ | 提交成功 |
| 1.3 | **执行生成代码并校验返回值** | ✅ | **返回 123，期望 123** |
| 2.1 | 重复执行 10000 次 | ✅ | sum=770000，期望 770000 |
| 3.1 | 代码重建（RW→RX 往返 3 次） | ✅ | 11,222,3333，期望一致 |
| 4.1 | 跨线程执行 | ✅ | 4 线程 × 5000 次，失败 0 次 |
| 5.1 | 释放后重建 | ✅ | 3 轮全部成功（r0=100 r1=101 r2=102） |
| 6.1 | `mmap(RWX)` 直接申请 | ✅ | 内核**允许** W+X 匿名内存 |
| 6.2 | `MAP_JIT/FORT` 标志探测 | ❌（**预期**） | 标志被内核**忽略**（映射成功但未生效） |

**关键结论（仅限模拟器）**：

1. **RW→RX 分步映射路径成立** —— 这是**唯一不依赖 AGC 审批**的候选路径，
   在模拟器上完整走通，含代码重建（对应 JIT 代码修补）。
2. **`MAP_FORT` 不生效** —— 印证阶段 0 的源码结论：它不是公开内核标志，
   传入会被**静默忽略**而非报错。这解释了为何不能靠猜标志位实现 JITFort。
3. **W+X 在模拟器上被允许** —— 但模拟器为 OpenHarmony 镜像且应用运行在
   `o:r:debug_hap:s0` 域（调试上下文），**不代表真机发布签名下的策略**。

> ⚠️ **模拟器成功不计作真机成功**（任务书明确要求）。且模拟器是
> OpenHarmony 6.1.1 镜像，其 SELinux/JIT 策略与华为 HarmonyOS 商业版
> 真机**很可能不同**，尤其 6.2 与 6.1 两项最可能因策略收紧而变化。
> **阶段 1 关口仍未通过。**

工程覆盖了任务书要求的全部测试面：

| 测试 | 内容 |
|---|---|
| 1 | 首次执行，校验返回值 == 123 |
| 2 | 重复执行 10000 次 |
| 3 | 代码重建（RW→RX 往返 3 次，对应 JIT 代码修补） |
| 4 | 跨线程执行（4 线程 × 5000 次） |
| 5 | 释放后重建（3 轮 mmap→执行→munmap） |
| 6 | 候选路径对照：RWX 直接申请 / FORT 标志探测（**预期失败，失败即证据**） |

设计要点：探针**不预设**任何未经证实的内核接口，改为对每条候选路径
独立上报 `errno`，使阻塞点可精确定位。

### 阶段 1 附带成果：ARMSX2 的 JIT 平台抽象缝已存在

阶段 3 要求"抽出跨平台 `JitCodeCache/JitMemory` 边界"。审计发现
**ARMSX2 已经具备这个边界**，无需从零设计：

- `common/HostSys.h` 定义 `HostSys::BeginCodeWrite()` / `EndCodeWrite()` /
  `BeginCodeWriteRange(addr,size)` / `EndCodeWriteRange(addr,size)` /
  `FlushInstructionCache(addr,size)` / `MemProtect(...)`；
- 平台实现：`common/Linux/LnxHostSys.cpp`、`common/Windows/WinHostSys.cpp`、
  `common/Darwin/DarwinMisc.cpp`；
- `pcsx2/Memory.cpp` 通过 `SharedMemoryMappingArea::Create(CodeSize, /*jit=*/true, ...)`
  分配代码内存；
- iOS 端已有 `DarwinMisc::MmapCodeDualMap()`（双映射：RW 别名写入 / RX 执行），
  并为 4 种 JIT 模式建模（`JitMode::{Simulator, LuckTXM, LuckNoTXM, Legacy}`）；
- **其中 `JitMode::Legacy` 用的正是 `mprotect` RW↔RX 切换**，
  与本次模拟器实测通过的路径**同构**。

**意义**：HarmonyOS 后端很可能可以照着 iOS 的 `Legacy` 模式实现，
而不是发明新机制。这是阶段 3 的有利条件，但仍**必须真机实测确认**。

---

## 3. 阻塞原因

### 阻塞 1：无真机连接 🔴 —— **当前唯一阻塞项**

```
$ hdc list targets -v
127.0.0.1:5555          TCP     Connected   localhost   ← 模拟器（已跑通）
<DEVICE_ID>        USB     Offline     localhost   ← 疑似目标真机
```

存在一个 USB 设备 `<DEVICE_ID>`，但状态为 **Offline**：

```
$ hdc -t <DEVICE_ID> shell param get const.product.model
[Fail][E001005] Device not found or connected
```

**推测**（非确认事实）：该设备是需要在手机上确认"允许 USB 调试"的
目标真机。**其型号、系统版本、CPU 架构一律未经确认。**

### 已解决：模拟器曾无法驻留 🟢

首次尝试时模拟器进程退出，`hdc` 转 `Offline`。原因是启动方式问题：
macOS 上不存在 `setsid`，非交互式 shell 中 detach 失败。
改用**受管后台任务**方式启动后，模拟器稳定驻留并完成全部验证。

**当前模拟器状态**：运行中，`127.0.0.1:5555` Connected。

> **重要**：模拟器结果**不计作真机成功**（任务书明确要求）。
> 且模拟器为 OpenHarmony 6.1.1 镜像，其 JIT/权限策略与
> 华为 HarmonyOS 商业版真机**可能不同**，即使跑通也**不能替代真机结论**。
> 这一点在本次实测中已有具体佐证：模拟器运行在 `o:r:debug_hap:s0`
> 调试域，且允许 W+X —— 这两项在真机发布签名下都可能不同。

---

## 4. 构建与运行命令

### 构建

```bash
cd stage1-jitprobe
bash scripts/build.sh
# 产物：entry/build/default/outputs/default/entry-default-unsigned.hap
```

### 签名（真机必需）

```bash
# 使用本机调试材料（normal 级，不含 JIT ACL）
HPS2_KEY_PWD='<口令>' bash scripts/sign.sh

# 使用含 JIT ACL 的 AGC 签发材料
HPS2_SIGN_DIR=/path/to/materials HPS2_KEY_ALIAS=app HPS2_KEY_PWD='<口令>' bash scripts/sign.sh
```

### 安装运行

```bash
bash scripts/install-run.sh                 # 自动选择设备
bash scripts/install-run.sh 127.0.0.1:5555  # 指定模拟器
```

### 宿主侧编码校验（独立验证）

```bash
cd stage1-jitprobe/host-test
cc -O0 -o encode_check encode_check.c && ./encode_check
```

实测输出：

```
movz w0,#123 => 0x52800F60 (期望 0x52800F60)   PASS
ret          => 0xD65F03C0 (期望 0xD65F03C0)   PASS
执行生成代码返回: 123 (期望 123) -> PASS
  重建 r0 => 100  PASS
  重建 r1 => 101  PASS
  重建 r2 => 102  PASS
```

**这项校验的价值**：宿主为 arm64，与目标同架构，且使用**与 HAP 内完全
相同的编码函数与 RW→RX→icache 流程**。它证明了**指令编码与流程逻辑正确**。
因此若真机上失败，即可**排除"代码写错"**，把问题收敛到
HarmonyOS 的内存/权限策略上。这是阶段 1 失败诊断的关键前提。

---

## 5. 性能数据

**无**。阶段 5 才采集性能数据；当前尚未进入该阶段，且缺少可运行基线。

---

## 6. 下一阶段任务

### 6.1 需要你操作的**最短清单**

按重要性排序，只需做 1 件事即可解除主要阻塞：

**① 接入真机（解除阻塞 1）** — 必须
```
1. 用 USB 线连接 Pura X 到本机
2. 手机上：设置 → 系统和更新 → 开发者选项 → 打开「USB 调试」
3. 手机弹出「允许 USB 调试吗？」→ 勾选「始终允许」→ 确定
4. 告诉我，我会先跑设备事实采集（型号/系统/架构），再装探针
```
> 我不会把"Pura X"当作已确认事实——接入后第一件事就是用
> `hdc shell param get` 把型号、`const.ohos.apiversion`、
> CPU 架构全部读出来记录。

**② 真机签名（可能必需）** — 视①的结果而定

真机通常拒绝未签名 HAP（`no signature file`）。两条路：
- **快速路**：DevEco Studio → `File > Project Structure > Signing Configs`
  → 勾选 `Automatically generate signature`（需登录华为开发者账号）
- **可控路**：把 AGC 签发的 `.p12` / `.cer` / `.p7b` 放到一个目录，
  告诉我路径，我用 `scripts/sign.sh` 签名

**③ 向 AGC 申请 JIT ACL（长期，可并行）** — 建议尽早启动

申请 `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY`，
并在申请理由中明确说明用途是**自研原生 ARM64 JIT 重编译器（PS2 模拟器）**，
而非 JSVM。**关键问题**：该权限能否覆盖非 JSVM 的原生 JIT 场景。

理由：这是官方唯一指明的 JIT 授权通道，且审批需要时间。
即使①的探针跑通（RW→RX 路径可行），也建议并行推进，以备系统策略收紧。

### 6.2 我这边不依赖以上材料可继续做的事

1. 完成 ARMSX2 源码审计的整理（`docs/source-audit.md`）
2. 把探针扩展为「权限/接口矩阵报告」：对每个候选接口逐一给出
   存在性、可调用性、失败原因
3. 准备阶段 2 的平台层骨架（构建系统、文件访问、线程、计时），
   这部分不依赖 JIT 权限
4. 静态验证 ARMSX2 的 GS/Vulkan 后端与 `vulkan_ohos.h` 的兼容性差距

**但按任务书要求，在真机 JIT 验证通过之前，不展开整套模拟器移植。**

---

## 7. 阶段关口判定

| 关口 | 条件 | 判定 |
|---|---|---|
| 阶段 0 → 1 | 找到三方 HAP 可用的 JIT 调用路径，否则提交证据后停止大规模移植 | **关口条件已触发**：公开 SDK 无 JITFort 接口。已提交完整证据（`docs/feasibility.md`）。**暂停**大规模移植，按任务书要求执行。 |
| 阶段 1 → 2 | **只有真机上受支持的 JIT 路径成功执行生成代码，才进入阶段 2** | **未通过** —— 模拟器已通过（返回 123），但**模拟器成功不计作真机成功**。停留在阶段 1。 |

**当前不进入阶段 2。** 在真机探针给出明确结果前，
不展开 EE/IOP/VU 的移植工作。

**为什么必须等真机**：模拟器是 OpenHarmony 6.1.1 镜像，本次实测中
已观察到两个"可能不代表真机"的信号 —— 应用运行在 `debug_hap` 调试域、
且 W+X 内存被允许。华为商业版 HarmonyOS 对代码内存的策略明显更严
（这正是 `system_basic` 系列权限存在的原因）。**在真机上重复同一探针
之前，任何"JIT 可用"的结论都不成立。**

---

## 8. 未解决问题

| # | 问题 | 状态 |
|---|---|---|
| Q1 | **真机 RW→RX 分步映射是否被允许？**（唯一不依赖 AGC 审批的突破口；模拟器已验证可行） | **待真机确认** |
| Q2 | 真机型号 / 系统版本 / CPU 架构 | 未确认（设备 Offline） |
| Q3 | 真机是否被判定为"手机形态"（影响 W+X 权限可申请性） | 未确认 |
| Q4 | 真机是否开启坚盾守护模式 | 未确认 |
| Q5 | `ALLOW_EXECUTABLE_FORT_MEMORY` 能否覆盖非 JSVM 原生 JIT | 需官方澄清 |
| Q6 | `ALLOW_USE_JITFORT_INTERFACE` 对应的可调用接口是否存在 | 无公开接口 |
| Q7 | 真机 GPU Vulkan 驱动版本与可用扩展 | 未验证 |
| Q8 | ARMSX2 原位代码修补与代码签名约束是否冲突 | **部分明确**：ARMSX2 已有 `HostSys::BeginCodeWrite/EndCodeWriteRange` 抽象，iOS 的 `Legacy` 模式用 mprotect 往返切换；真机需实测其性能代价 |
