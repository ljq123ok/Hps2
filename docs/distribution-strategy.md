# Hps2 分发策略：双渠道包设计

**决策变更**（用户 2026-09-18 明确要求）：

> 需要设计成 github 发布的 hap 包客户自己签名可以使用 jit 就跑 jit，
> 上架商店的包，无法使用 jit 就自己降级

**这是对早前"不做降级"策略的正式修订。** 早前决策记录在
`docs/jit-verdict.md` 与 `hps2_jitcheck.h` 的注释里，现按新要求调整。

---

## 1. 为什么必须分两个包

**根因：SELinux 域由签名类型决定。** 这是真机实测的对照证据（非推测）：

| 应用 | 签名来源 | 真机 SELinux 域 | JIT 可用 |
|---|---|---|---|
| 我们的探针 | debug 签名 | `o:r:debug_hap:s0` | ✅ |
| 支付宝（AppGallery 发布） | release 签名 | `o:r:normal_hap:s0` | ❌ |

策略层面的依据：

```
domain.te:355  neverallow { domain developer_only(`-debug_hap_attr -input_debug_hap')
                 debug_only(`-su') -isolated_render } self:xpm { exec_anon_mem };
                 ← normal_hap 不在豁免名单中
```

也就是说：**同一个 HAP 文件，用什么证书签名，直接决定了 JIT 能不能用。**

因此"能跑 JIT 的包"与"能上架的包"在技术上**无法合并**。

## 2. 两个包的定义

### 2.1 GitHub 分发包（`hps2-github`）

| 项 | 值 |
|---|---|
| 签名 | **用户自行签名**（debug 或自签 release 的 debug 型 Provision）|
| JIT | **可用则跑 JIT**；不可用则明确报告并引导 |
| 上架 | ❌ 不上架 |
| 定位 | 面向愿意自行签名的用户，追求完整性能 |

**"用户自己签名"的实际含义**：HAP 必须由用户用**自己**的证书签名后安装。
HarmonyOS 的 debug 型签名（`PROVISION_TYPE_DEBUG`）会得到 `debug_hap` 域，
从而获得 `xpm:exec_anon_mem` 豁免。

> 用户自签流程需要在 README 中写清楚，并说明：
> 自签需要用户自己的 AGC 调试证书/Profile（或 DevEco AutoSign）。

### 2.2 商店包（`hps2-store`）

| 项 | 值 |
|---|---|
| 签名 | 我们的 release 证书（AppGallery 上架）|
| JIT | 预期**不可用**（`normal_hap` 域）|
| 行为 | **自动降级到解释器**，并如实告知用户当前性能受限 |
| 定位 | 能装能玩，但不承诺性能 |

**降级的技术路径**：上游 `VMManager::UpdateCPUImplementations` 已经有现成逻辑 ——
当 `SysMemory::HasCodeMemory()` 为假时，会把
`EnableEE / EnableIOP / EnableVU0 / EnableVU1 / EnableFastmem / vuThread` 全部置 false，
即切到解释器。上游会打印一行 Warning（`VMManager.cpp:3007`）。

**关键：** 上游是"静默降级 + 一行日志"。商店包需要把这个状态
**显式告知用户**（不能让人以为只是"模拟器很慢"）。

## 3. 实现方式：编译期开关，单一代码库

不做两个代码库 —— 用**编译期宏**区分行为：

```cmake
# 默认：GitHub 包（不降级，如实报告）
if (HPS2_STORE_BUILD)
    add_compile_definitions(HPS2_STORE_BUILD=1)
endif()
```

行为差异（运行期判定到不可用之后）：

| | GitHub 包 | 商店包 |
|---|---|---|
| JIT 不可用时 | **拒绝启动** + 引导用户（现有行为）| **自动降级**到解释器 + 明确告知 |
| 日志 | 报错并说明原因 | 记录降级原因与当前后端 |
| UI | 显示"JIT 不可用"+ 处理建议 | 显示"已降级到解释器"+ 性能预期 |

**两者共用**：
- 同一个 JIT 自检（`hps2_jitcheck`）
- 同一套降级代码路径（上游已有）
- 同一个 UI，只是文案与按钮行为不同

## 4. 商店包需要新增的工作

1. **降级开关**：`HPS2_STORE_BUILD` 宏，在 JIT 不可用时不阻止启动，
   而是让上游的降级路径生效（需确保 `SysMemory::Allocate` 失败不会
   导致 `CPUThreadInitialize` 直接 return false）

   ⚠️ **这是本方案最大的技术风险点**：当前
   `VMManager::Internal::CPUThreadInitialize()` 在
   `SysMemory::Allocate()` 失败时**直接返回 false**（`VMManager.cpp:469-473`），
   VM 根本起不来。而上游的降级逻辑在 `UpdateCPUImplementations()`，
   它在 `Initialize()` 的更后面。**需要确认降级路径能否真正走通**，
   不能想当然。

2. **UI 告知**：降级后在界面上显示当前后端与性能预期（不能静默）

3. **README**：说明两个包的差异、自签流程、以及"商店版性能受限"的原因

4. **构建脚本**：产出两个 HAP（宏切换），或至少能一键切换

## 5. 待验证事项（不猜测）

- [ ] **`SysMemory::Allocate()` 失败时，降级路径是否真的能启动 VM？**
      需要读 `Initialize()` 的完整流程确认 —— 这是方案可行性的前提。
- [ ] release 签名下 JIT 是否**确实**不可用（早前因用户批准推迟了
      release 签名验证，见 `docs/release-jit-verification.md`）。
      若 release 下 JIT 其实可用，则商店包无需降级，方案要改。
- [ ] 解释器模式的实际性能（PS2 全解释器可能远低于可玩阈值，
      需实测后才能如实告知用户"能玩到什么程度"）
- [ ] AppGallery 是否允许"性能受限但仍上架"的模拟器类应用

## 6. 建议的推进顺序

1. **先验证第 5 节第 1、2 条**（技术前提）—— 在读通代码前不动实现
2. 再实现编译期开关与 UI 告知
3. 最后写 README 与构建脚本

**不先写代码的原因**：如果 release 签名下 JIT 其实可用，
或者降级路径根本走不通，那实现方向就要变。先把前提搞清楚。

---

## 7. 验证结果（进行中）：降级路径的关键障碍已定位

### 7.1 🔴 确认：非 Apple 平台**没有**解释器逃生门

读 `pcsx2/Memory.cpp` 的代码分支结构，这是决定性发现：

| 平台分支 | 代码内存分配失败时的行为 |
|---|---|
| **Apple/iOS** | `DarwinMisc::iPSX2_FORCE_EE_INTERP=1` 时 `s_code_memory = nullptr` **并继续**——有逃生门 |
| **非 Apple（含 OHOS）** | `return false` —— **直接失败，无逃生门** |

具体位置（`Memory.cpp` 非 Apple 的 `#else` 分支）：

```cpp
if (!(s_code_mapping_area = SharedMemoryMappingArea::Create(...)))
{
    Host::ReportErrorAsync("Error", "Failed to map code memory.");
    ReleaseMemoryMap();
    return false;                    // ← 失败即中止
}
if ((s_code_memory = s_code_mapping_area->Map(...)) == nullptr)
{
    Host::ReportErrorAsync("Error", "Failed to allocate code memory.");
    ReleaseMemoryMap();
    return false;                    // ← 我们上次实测遇到的正是这里
}
```

### 7.2 🔴 由此确定：上游的"降级"逻辑**根本走不到**

上游确实有切解释器的代码，但它位于**更靠后的位置**：

```
VMManager::Initialize()
  └─ VMManager::Internal::CPUThreadInitialize()      (VMManager.cpp:438)
       ├─ SysMemory::Allocate()                      (:469)
       │    └─ AllocateMemoryMap()                   (Memory.cpp:100)
       │         └─ code memory 分配 → 失败 → return false   ★ 在这里就断了
       │    ⇒ CPUThreadInitialize 返回 false，VM 起不来
       └─ …（走不到）
  └─ UpdateCPUImplementations()                      (:3002 附近，把 EnableEE 等置 false)
       ↑ 这段"切解释器"的代码永远执行不到
```

**结论：所谓"上游会自动降级"是一个不成立的假设。**
非 Apple 平台上，代码内存失败 = 启动失败，与 JIT 是否可用无关。

这解释了本次实测现象：`ReportErrorAsync: Error: Failed to allocate code memory.`
→ `Failed to allocate VM memory.` → `CPUThreadInitialize failed`。

### 7.3 ✅ 有利的一面：上游的**下游**代码已为解释器做好准备

`vtlb_Core_Alloc()`（`vtlb.cpp:1387`）已有分支：

```cpp
if (!SysMemory::HasCodeMemory())
{
    // Interpreter execution never emits fastmem accesses. Avoid reserving a
    // 4 GB virtual address range that cannot improve the no-JIT backend.
    vtlbdata.fastmem_base = 0;
    EmuConfig.Cpu.Recompiler.EnableFastmem = false;
    Console.WriteLn("Fastmem disabled: executable code memory is unavailable");
}
```

**即：一旦能跨过 code memory 那一关，后面的解释器路径是通的**
（上游已按无代码内存的情况处理了 fastmem 与 vtlb）。

### 7.4 验证方法（已实现，待设备验证）

在 `Memory.cpp` 非 Apple 分支加入与 iOS 同构的逃生门：

```cpp
const bool skip_code_memory = (std::getenv("HPS2_FORCE_INTERP") != nullptr);
if (skip_code_memory) { s_code_memory = nullptr; }   // 解释器模式
else if (!(s_code_mapping_area = ...)) { return false; }
else if ((s_code_memory = ...->Map(...)) == nullptr) { return false; }
```

同时让 JIT 门禁在验证模式下**不阻止启动**（`RunJitStartupCheck`），
否则降级路径同样到不了。

**触发方式用文件标记**（应用域无法通过 hdc 接收环境变量）：
```
hdc shell "touch /data/storage/el2/base/haps/entry/files/FORCE_INTERP"
```

### 7.5 待验证的两个问题

1. **跨过 code memory 后，VM 能否真正启动？**
   —— 代码层面有依据（§7.3），但**必须实测**。
2. **解释器模式的实际性能是多少？**
   —— PS2 全解释器（EE/IOP/VU0/VU1 全禁用重编译器）通常只有个位数帧率。
   实测后才能如实告知用户"商店版能玩到什么程度"。

> ⚠️ **本节的实现是"验证用开关注入"，不是最终设计。**
> 正式商店包会改为编译期宏 `HPS2_STORE_BUILD`，
> 并且**必须把降级状态明确告知用户** —— 上游只打一行 Warning 静默切换，
> 对用户而言会误以为"模拟器很慢"而不是"JIT 不可用导致降级"。
