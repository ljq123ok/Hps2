# ARMSX2 → HarmonyOS 可行性审计（阶段 0）

| 项目 | 值 |
|---|---|
| 审计日期 | 2026-09-14 |
| ARMSX2 提交 | `d7e8d01678107f066d6ec988ca178d80089bd9f5`（2026-09-14，"iOS: fixed/re-implemented Airplay (#591)"） |
| 本机 DevEco Studio | 6.1.1.300（build DS-243.24978.46.36.611300） |
| 本机 HarmonyOS SDK | **6.1.1 / API 24**（`sdk-pkg.json`: `displayName: "HarmonyOS 6.1.1"`） |
| 本机 SDK Native 版本 | 6.1.1.125，LLVM/clang 15.0.4，sysroot `aarch64-linux-ohos` |
| 宿主平台 | macOS 26.6.1（arm64） |
| 目标设备 | 待真机确认（任务书称 Pura X；见 §1.4） |
| 连接状态 | `hdc list targets` → 空。**审计期间无设备连接** |

> **关于「HarmonyOS 7」**：任务书称目标为 HarmonyOS 7。本机安装的 SDK 是
> **6.1.1 / API 24**，`sdk-pkg.json` 中不存在 "7" 的任何版本标识；DevEco 的
> 可安装列表也以 6.1.1 为最高级别。因此下文所有「目标 SDK」结论均基于
> 本机实际可用的 API 24 SDK，**不假设 HarmonyOS 7 独有的新接口存在**。
> 这一点已用工具输出核实，不是推断。

---

## 1. 结论摘要

### 1.1 阶段 0 关口判定

> **关口条件**：如果找不到三方 HAP 可使用的 JIT 调用路径，先提交完整证据和最小复现，**再停止大规模 ARMSX2 移植**。

**判定：关口条件【已触发】。**

公开 SDK 中**不存在任何三方 HAP 可调用的 JIT 内存接口**。具体证据见 §2。
因此本阶段的正确动作是：

1. 提交完整证据（本文档）；
2. 交付最小复现工程（`stage1-jitprobe/`），把「权限缺失」从文档结论变成真机可复现的运行期事实；
3. **暂停**大规模 ARMSX2 移植，直到 §2.6 列出的官方渠道事项有明确答复。

这不是"放弃"，而是任务书明确要求的关口行为：证据先行，不赌未经证实的接口。

### 1.2 三条候选权限路径的现状

HarmonyOS 把「代码内存安全」拆成三组 `system_basic` 权限，全部需要 ACL 且由 AGC 签发：

| 权限 | 语义 | 关键限制 | 对本项目的可用性 |
|---|---|---|---|
| `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY` | 允许**系统 JS 引擎**申请带 `MAP_FORT` 的匿名可执行内存 | 面向 JS 引擎，非任意原生代码 | 官方 JIT 入口，但语义不覆盖自研 JIT |
| `ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE` | 允许应用调用 **JITFort 接口**更新 `MAP_FORT` 内存内容 | 公开 SDK 中**找不到该接口** | 权限存在但无 API 可调 |
| `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` | 允许申请**可写可执行**（W+X）匿名内存 | **仅平板、2in1 设备**可申请 | Pura X 为手机形态，预计不可用 |

三者**均为 `system_basic` + `system_grant`**，且文档明确指出：
对于 `system_basic` 等级权限，**若 ACL 使能为 false，则 normal 等级应用无法申请**。

### 1.3 对图形栈的结论（阶段 4 的前置事实）

图形侧**不存在**同等级别的阻塞：

- NDK 提供 `libvulkan.so`，头文件为 **Vulkan 1.4**（`VK_HEADER_VERSION 309`）。
- 提供 **OHOS 专有平台扩展** `vulkan_ohos.h`：`VK_OHOS_surface`、`vkCreateSurfaceOHOS`、
  `VkSurfaceCreateInfoOHOS`（接收 `OHNativeWindow*`），以及 `VK_OHOS_native_buffer`、
  `VK_OHOS_external_memory`。
- 另有 EGL/GLES3 与 `native_window/external_window.h`。

即：**Vulkan 走的是公开 NDK 接口**，可与 `OHNativeWindow` 直接对接。
这意味着若 JIT 关口最终无法通过，Vulkan 侧的移植工作本身不因此作废。

### 1.4 尚未确认为事实的事项（禁止当作已知）

| 事项 | 状态 | 需要的证据 |
|---|---|---|
| 真机确切型号（"Pura X"） | **未确认** | `hdc shell param get const.product.model` |
| 真机系统版本 | **未确认**（推测 OS7/API26） | `hdc shell param get const.ohos.apiversion` |
| 真机 CPU 架构 | **未确认**（推测 arm64） | `hdc shell param get const.product.cpu.abilist` |
| 真机是否为 PC/2in1 形态判定 | **未确认** | 决定 `ALLOW_WRITABLE_CODE_MEMORY` 是否可申请 |
| 坚盾守护模式是否开启 | **未确认** | 系统设置 → 隐私和安全 |
| 真机内核对 `MAP_FORT` 的实际处理 | **未验证** | 需真机探针运行结果 |

**不把此前对芯片型号的任何推测作为已确认事实。** 上表五项必须由真机输出填写。

---

## 2. JIT 可行性证据

### 2.1 公开 NDK 中不存在 JITFort 接口

对 `.../sdk/default/openharmony/native/sysroot/usr/include`（**公开 NDK 头文件全集**）搜索：

```bash
grep -ril "jitfort"   <sysroot>/usr/include   # → 无结果
grep -rl  "MAP_FORT"  <sysroot>/usr/include   # → 无结果
```

对 NDK 全部 `.so`（`sysroot/usr/lib/aarch64-linux-ohos/*.so`）检查**导出符号**：

```bash
for f in $SDK/*.so; do nm -D --defined-only "$f" | grep -i "fort"; done   # → 无结果
```

结论：**没有头文件、没有导出符号**。`libc.so` 中亦无 `MAP_FORT` 相关符号。

> 方法论说明：本次审计最初用 `rg` 得到"无结果"，随后发现**本机并未安装
> `rg`**，那些结果全部是 `command not found` 造成的假阴性（stderr 被抑制）。
> 上文的结论全部以真实 `grep` / `nm` 重新执行过，属于**修正后的**结果。
> 记录此事是因为它直接关系到本项目结论的可信度。

### 2.2 `MAP_FORT` 是运行时私有常量，不是内核公开 flag

在 OpenHarmony 源码 `arkcompiler_ets_runtime/ecmascript/mem/jit_fort.h` 中：

```cpp
static constexpr int MAP_JITFORT = 0x1000;
```

它作为参数传给引擎**自身的** `PageMap(...)` 辅助函数
（`jit_fort.cpp` 中 `PageMap(..., MAP_JITFORT, true)`），**不是** `mmap(2)` 的
公开标志位。`<sys/mman.h>` 中**没有** `MAP_FORT`：

```
MAP_SHARED MAP_PRIVATE MAP_FIXED MAP_ANON MAP_ANONYMOUS MAP_NORESERVE
MAP_GROWSDOWN MAP_DENYWRITE MAP_EXECUTABLE MAP_LOCKED MAP_POPULATE ...
```

且 `MAP_EXECUTABLE` 已被 `<asm-generic/mman.h>` 占用为 `0x1000` ——
与 `MAP_JITFORT` 数值相同但语义无关。**在自研代码里直接传 `0x1000`
不会得到 JITFort 语义**，只会撞上 `MAP_EXECUTABLE`。

**这直接印证任务书的要求：不得预填未经证实的 `MAP_FORT` 调用代码。**
本仓库因此**没有**写入任何 `MAP_FORT` 实现代码；阶段 1 探针只做
「传入该标志观察内核是忽略还是拒绝」的对照实验（路径 C）。

### 2.3 JITFort 是 JS 引擎的内部机制，不是三方 API

`jit_fort.h` 的类注释说明 `JitFort` 是 **ArkTS 运行时的 JIT 代码内存管理器**，
采用双层区域架构：

- Tier 1 **Small Fort**：16 个 256KB 区域（共 4MB）
- Tier 2 **Huge Fort**：1 个 4MB 连续区域

其公开方法（`InitJitFort()`、`Allocate()`、`Sweep()`、
`MarkJitFortMemInstalled()` 等）均属于 **ArkTS 运行时内部实现**，
不出现在 NDK 头文件中。`IsResourceAvailable()` 标了 `PUBLIC_API`，
但那是**引擎内部**的 `PUBLIC_API` 宏，不是给 HAP 用的导出符号。

这正是任务书要求区分的"公开 SDK 接口 vs OpenHarmony 源码内部接口"：
**`JitFort` 属于后者，禁止当作三方应用可调用 API。**

### 2.4 官方指定的 JIT 路径是 JSVM，且必须 AGC 审批

OpenHarmony 官方文档 `zh-cn/application-dev/napi/jsvm-apply-jit-profile.md`
（《JSVM-API 申请JIT权限指导》）是唯一权威的 JIT 授权说明，原文要点：

1. JIT 默认**被禁用**；如需使用，必须通过 ACL 申请
   `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY`，
   并**向 AGC 说明在 JSVM 上使用 JIT 的理由**；
2. **AGC 批准后**更新 profile、重新打包发布；
3. **"如果未申请权限证书但在配置文件中声明了该权限，应用安装将失败。"**
4. 权限证书未申请时声明权限 → 编译期报错要求 SDK 升级到 5.0.2.125+；
5. **坚盾守护模式下，操作系统全局禁用 JIT 功能，对所有应用生效，
   包括已获得 ACL 权限的特权应用。**

NDK 侧对应的可观测信号是 `JSVM_Status::JSVM_JIT_MODE_EXPECTED`
（`jsvm_types.h`，`@since 18`），`OH_JSVM_CompileWasmModule` 等接口在
jitless 模式下返回它（`jsvm.h:3255/3281/3319`）。

**关键含义**：官方把 JIT 能力**绑定在 JSVM 之上**。申请到的权限语义是
"允许**系统 JS 引擎**申请 FORT 内存"，而**不是**"允许我的原生代码自行
`mmap` 可执行内存"。PS2 模拟器的 EE/IOP/VU 重编译器和 ARMSX2 的
JIT 代码缓存是纯原生 C++，**不经过 JSVM**。现有公开材料**没有任何**
把该权限扩展到任意原生 JIT 的路径。

### 2.5 坚盾守护模式：系统级全局开关

`jsvm-secure-shield-mode.md` 明确：坚盾守护模式下
**"全面禁用即时编译(JIT)功能，包括已获取 ACL 权限的应用程序"**，
并**暂停 WebAssembly 支持**。这是**用户可随时开启的系统设置**，
意味着即使拿到 ACL，模拟器仍可能在用户开启该模式后完全失去 JIT。

对 PS2 模拟器这是**产品级风险**，不是边缘情况：需在设计中准备
"JIT 不可用"的降级路径（虽然任务书明确不以解释器作为最终性能兜底，
但作为可用性兜底仍需存在）。

### 2.6 真机内核实证：JITFort 机制真实存在并处于启用状态

**这是真机接入后获得的最重要的一条运行期证据**（模拟器上完全没有）。

在真机（HUAWEI Pura X View，HongMeng Kernel 1.13.0）上：

```bash
$ hdc -t <device> shell ls /proc/sys/kernel/
... jitfort ...          ← 存在 jitfort 节点

$ hdc -t <device> shell ls -la /proc/sys/kernel/jitfort/
dr-xr-xr-x 2 root root 0 2026-09-13 20:46 .
dr-xr-xr-x 11 root root 0 2026-09-13 20:46 ..
-?????????  ? ?    ?    ?         ? jitfort_mode

$ hdc -t <device> shell cat /proc/sys/kernel/jitfort/jitfort_mode
/bin/sh: cat: /proc/sys/kernel/jitfort/jitfort_mode: Permission denied
```

**结论**：

1. `jitfort` **不是纯用户态概念** —— 它由**内核直接暴露一个 sysctl 目录**
   （`/proc/sys/kernel/jitfort/jitfort_mode`）。HongMeng 内核**原生实现了**
   JITFort 语义，这与普通 Linux 内核有本质区别。
2. 该节点为 **root-only**（普通 shell 读为 `Permission denied`），
   即其开关由系统/root 控制，**三方应用无法自行开启**。
3. 这解释了 `ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE`
   （"允许应用调用 JITFort 接口更新 MAP_FORT 内存的内容"）的**存在意义**：
   内核提供机制，应用需显式获权才能调用。
4. **同时也解释了为何公开 NDK 没有该接口**：它是**高度受限的内核能力**，
   连头文件都不对普通 NDK 暴露，只对系统 JS 引擎（ArkTS）开放。

**对项目的影响**：这**加强了** R1/R3 风险判断 —— JITFort 是**为系统
JS 引擎定制的内核能力**，把 PS2 模拟器的自研 JIT 接入这条路，
需要官方明确开放，不是靠逆向或猜测可达成的。任务书已明确禁止
"绕过代码签名、XPM、提权或内核漏洞"的方案，本审计严格遵守。

### 2.7 需要走官方渠道解决的事项

以下是**只能由用户/官方渠道推进**、无法靠本机代码绕过的阻塞项：

1. **向 AGC 申请 `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY` 的 ACL**，
   并在申请中明确说明用途是"自研原生 ARM64 JIT 重编译器"，而非 JSVM。
   需确认：该权限能否覆盖非 JSVM 场景。
2. **确认 `ohos.permission.kernel.ALLOW_USE_JITFORT_INTERFACE` 是否存在
   可调用的接口**。若存在，索取头文件与文档；若不存在，请官方确认该权限的用途。
   真机已证实 `/proc/sys/kernel/jitfort/jitfort_mode` 存在（§2.6）。
3. **确认 Pura X（手机形态）能否申请 `ALLOW_WRITABLE_CODE_MEMORY`**。
   文档写"当前仅平板、2in1 设备应用可申请"，需确认真机形态判定规则。
4. **确认 W^X 策略下 RW→RX 分步映射（`mprotect`）是否被允许**。
   这是**唯一可能不依赖上述任何权限**的路径 —— 因为它全程不出现 W+X 同时有效。
   本阶段 1 探针的核心目的就是实测这一点。

> **第 4 项是本项目在"不依赖 AGC 审批"前提下最可能的突破口。**
> 若 `mmap(RW)` → 写入 → `mprotect(RX)` → `__builtin___clear_cache` 全流程
> 在真机上成功，则 JIT 可在**不申请任何受限权限**的情况下工作。
> 这条路径的正确性尚属**未验证假设**，必须由真机探针判定。

---

## 3. 图形栈证据（阶段 4 前置）

| 能力 | 本机 SDK 实际符号/文件 | 状态 |
|---|---|---|
| Vulkan 核心 | `vulkan/vulkan_core.h`，`VK_HEADER_VERSION 309`（Vulkan 1.4） | ✅ 存在 |
| OHOS 平台表面扩展 | `vulkan/vulkan_ohos.h`：`VK_OHOS_surface`、`vkCreateSurfaceOHOS`、`VkSurfaceCreateInfoOHOS{OHNativeWindow*}` | ✅ 存在 |
| OHOS native buffer | `VK_OHOS_native_buffer`、`VkNativeBufferOHOS{OHBufferHandle*}` | ✅ 存在 |
| 外部内存 | `VK_OHOS_external_memory`、`OH_NativeBuffer` | ✅ 存在 |
| 链接库 | `sysroot/usr/lib/aarch64-linux-ohos/libvulkan.so` | ✅ 存在 |
| GLES | `GLES3/gl3.h gl31.h gl32.h`、`libGLESv2.so libGLESv3.so` | ✅ 存在 |
| EGL | `EGL/egl.h eglext.h`、`libEGL.so` | ✅ 存在 |
| 窗口 | `native_window/external_window.h`、`libnative_window.so` | ✅ 存在 |

**结论**：HarmonyOS 原生应用的 Vulkan 图形路径是**公开且完整**的，
通过 `vkCreateSurfaceOHOS` + `OHNativeWindow*` 接入窗口，
**不需要** Android 的 `ANativeWindow` 或 `vkCreateAndroidSurfaceKHR`。

⚠️ 仍待真机验证：目标 GPU 的 Vulkan 驱动版本、可用扩展（尤其
`VK_KHR_swapchain`、`VK_EXT_external_memory_*`）、以及 GS 后端所需的
特性（如 `shaderStorageImageWriteWithoutFormat`、整数纹理等）。
**不预设 Android 的 Vulkan/窗口代码可以原样编译。**

---

## 4. 权限与签名现状

### 4.1 Profile 模板（本机实际文件）

`.../toolchains/lib/UnsgnedReleasedProfileTemplate.json`：

```json
{
  "bundle-info": { "apl": "normal", "app-feature": "hos_normal_app" },
  "acls":        { "allowed-acls": [ "" ] },
  "permissions": { "restricted-permissions": [] }
}
```

`apl` 默认为 `normal`。要跨级别申请 `system_basic` 权限，需修改
Profile 中的 `acls.allowed-acls`（无权限数据者）或
`app-services-capabilities`（携带权限数据者），然后**重新签名**。

> 官方原文同时限定：**ACL 方式跨级别申请权限仅限调试阶段，
> 不可用于发布上架应用市场**；商用版本必须向应用市场申请发布证书与 Profile。

### 4.2 本机签名材料

| 材料 | 路径 | 说明 |
|---|---|---|
| 调试证书 | `~/.ohos/config/default_arktunnel_*.cer` | 已有 |
| 调试 Profile | `~/.ohos/config/default_arktunnel_*.p7b` | 已有 |
| 私钥 | `~/.ohos/config/default_arktunnel_*.p12` | 已有 |
| 签名工具 | `.../toolchains/lib/hap-sign-tool.jar` | 官方工具，可用 |

hvigor 的 `SignHap` 需要 DevEco 加密后的口令串（AES-128-GCM，
密钥材料在 `~/.ohos/config/material`），无法离线生成，
因此本仓库改用 `hap-sign-tool` 直接签名（见 `stage1-jitprobe/scripts/sign.sh`）。

⚠️ **现有材料是 `normal` 级调试 Profile，不含任何 JIT 相关 ACL。**
要用受限权限签名，必须由 AGC 签发**新的**、内含对应 ACL 的 Profile。

---

## 5. 风险排序

| # | 风险 | 影响 | 概率 | 当前证据 | 处置 |
|---|---|---|---|---|---|
| **R1** | **无三方原生 JIT 路径** | 致命：核心目标失效 | **高** | §2.1–2.4 | 待真机探针；走官方渠道 |
| **R2** | RW→RX 分步映射也被拒绝 | 致命 | 中 | 未验证 | **阶段 1 探针首要目标** |
| **R3** | JIT 权限仅限 JSVM，不覆盖原生 | 致命 | 中高 | §2.4 | 需官方澄清 |
| **R4** | 坚盾守护模式全局禁用 JIT | 产品级可用性 | 确定（用户可开） | §2.5 | 设计降级路径 + 用户提示 |
| **R5** | W+X 权限仅限平板/2in1 | 高 | 高（Pura X 是手机） | §1.2 表格 | 不作为主路径 |
| **R6** | 真机 GPU Vulkan 特性不足 | 中：GS 后端降级 | 中 | 未验证 | 阶段 4 实测 |
| **R7** | 本机 SDK(API24) 低于真机(API26) | 中：无法编译真机独有 API | 中 | §1 表 | 升级 SDK 或避免新 API |
| **R8** | 无设备连接，全部真机结论缺失 | 高：无法验证 | 确定 | `hdc list targets` 为空 | 需用户接入设备 |
| **R9** | ARMSX2 JIT 依赖原位代码修补 | 中：与代码签名冲突 | 中 | 待源码审计 | 见 §6 |

---

## 6. ARMSX2 源码审计（阶段 0 第 1 项）

> 本节由独立子代理以"只读、可验证"方式审计
> `d7e8d01678107f066d6ec988ca178d80089bd9f5` 的实际源码得出，
> 不以 README 的自我描述为据。审计结论见 `docs/source-audit.md`。

仓库结构（已验证）：

```
ARMSX2/
├── pcsx2/          核心模拟器（EE/IOP/VU/GS/音频/输入）
├── pcsx2-qt/       Qt 桌面前端
├── pcsx2-sdl/      SDL 前端
├── pcsx2-libretro/ libretro 前端
├── pcsx2-eerunner/ 诊断用 EE 单测运行器
├── pcsx2-vurunner/ 诊断用 VU 单测运行器
├── pcsx2-gsrunner/ 诊断用 GS 单测运行器
├── platforms/      仅 android 与 ios 两个平台前端
└── 3rdparty/       大量 vendored 依赖
```

关键事实（README 声明，**待源码核实**）：
EE/IOP/VU 的 ARM64 重编译器已实现，vtlb fastmem 已实现。
**README 明确说明其 JIT 翻译工作大量借助 LLM 完成** ——
这加强了对"必须逐单元跑正确性测试"的要求，不能因为"能启动"就认为 JIT 正确。

⚠️ **`platforms/` 下只有 android 与 ios，没有 harmonyos** ——
HarmonyOS 平台层需要从零建立。

---

## 7. 阶段 1 交付说明

见 `stage1-jitprobe/` 与 `docs/STATUS.md`。

阶段 1 探针的设计原则：
- **不写**任何未经证实的 `MAP_FORT` 实现代码（遵守任务书与 §2.2 结论）；
- 以**候选路径对照实验**的方式，把每种可能的内存申请方式都实测一遍，
  失败也记录 `errno`，使"阻塞点"可精确定位；
- 覆盖任务书要求的全部测试面：首次执行、重复执行、代码重建、
  跨线程、释放后重建、失败时的错误报告。

**真机结果才是关口。** 模拟器与宿主侧验证不计作真机成功。
