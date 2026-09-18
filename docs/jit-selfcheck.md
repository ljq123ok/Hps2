# JIT 能力自检（应用内实现）—— 不降级

**实现时间**：2026-09-17
**范围**：`app-hps2`（正式应用），非 `stage1-jitprobe` 探针
**状态**：✅ 已实现并通过编译验证；⏳ 待真机运行验证

---

## 1. 为什么需要它

`docs/jit-regression.md` 记录了一个**未结案**的现象：

> 同一个 HAP 文件，17:16 跑出 `PASS=8`，19:14 变成 `PASS=1 FAIL=7`，
> 所有带 `PROT_EXEC` 的请求返回 `EINVAL`。

该文档 §5 明确要求两件事，此前均**未落地**：

1. 必须在模拟器核心启动时做 **JIT 能力自检**，而非假定可用；
2. 需要设计 JIT 不可用时的路径。

上游 iOS 端有**同构**问题（iOS 会在运行期吊销 `CS_DEBUGGED` 授权），
其对策是 `DarwinMisc::ValidateJITAlive()`（`common/Darwin/DarwinMisc.cpp:768`）
的运行期复检 —— 本实现按同一思路，但适配 HarmonyOS。

### 1.1 产品决策：**不做降级**（用户明确要求）

上游 `VMManager::UpdateCPUImplementations()`（`VMManager.cpp:2946-2958`）
在 `HasCodeMemory()` 为假时会**静默**把 CPU 指向解释器：

```cpp
if (!SysMemory::HasCodeMemory())
{
    Cpu = &intCpu;      // ← 不报错、不提示，直接退回解释器
    ...
}
```

后果：VM "成功启动"却以解释器运行，用户看到的是"能跑但极慢"。
任务书原始约束是 **"JIT 必须是性能路径，解释器不能是回退方案"**。

因此本实现把该静默路径**升级为显式失败**。

---

## 2. 实现结构

### 2.1 新增模块（与核心解耦，可独立测试）

| 文件 | 职责 |
|---|---|
| `app-hps2/entry/src/main/cpp/hps2_jitcheck.h` | 接口声明 |
| `app-hps2/entry/src/main/cpp/hps2_jitcheck.cpp` | 实现（纯 libc，无 PCSX2 依赖） |

设计要点：

- **只用已经真机验证过的路径**：`mmap(RW)` → 写入 → `mprotect(RX)` → 执行 → 校验。
  不使用 `MAP_JIT`/`MAP_FORT`（真机实测返回 `EINVAL`，明确被拒）。
- **验证到"真正执行并校验返回值"为止**。只做 `mmap`/`mprotect` 不足以证明可用 ——
  回归现象的教训正是"`mmap` 成功而 `mprotect(RX)` 失败"，必须执行一次。
- 指令缓存同步用 `__builtin___clear_cache` + `dsb ish; isb`（真机实测有效）。
- 期望返回值用 `123`，与阶段 1 探针**保持一致**，便于与已有真机证据交叉核对。

### 2.2 关键安全设计：不触碰核心的 JIT 代码内存

运行期复检**必须使用自检模块自有的暂存页**，绝不能复用核心的 arena：

> 核心的代码内存（EE/IOP/VU 重编译器 arena）正在被活跃使用，
> 向其中写入探针指令会**破坏已编译的代码**。

而"能否 `mprotect` 加执行位"是**进程级策略问题**，
用一块独立页判定同样有效且完全安全。

启动自检成功后会**保留**该暂存页（保持 RX），供运行期复检复用；
`RunStartupCheck()` 因此是幂等的（重复调用先释放上一页）。

### 2.3 三处接入点（`napi_init.cpp`）

| # | 位置 | 作用 | 失败时行为 |
|---|---|---|---|
| 1 | `NapiStartBios()` 入口 | **启动前硬门禁**（权威判据） | 拒绝启动，给出可操作建议 |
| 2 | `VMThreadMain()` VM 初始化后 | **重编译器断言** | 停机并报告（拦截静默降级） |
| 3 | 监控线程 | **运行期看门狗**（约 30 秒/次） | 主动停机，**不回退解释器** |

**接入点 2 的判据**用**符号身份比较**而非配置项：

```cpp
if (!SysMemory::HasCodeMemory() || Cpu == &intCpu) { /* 拒绝 */ }
```

理由：配置项只反映"用户想要什么"，符号身份才反映"**实际选了谁**"。

**接入点 3 的周期**取 30 秒，避免高频 `mprotect` 影响模拟性能。

### 2.4 N-API 接口

```typescript
// 完整自检（含申请页并执行代码），供 UI 在启动前调用
export const checkJit: () => string;   // 返回 JitCheckResult 的 JSON

// getStatus() 的 JSON 中新增 JIT 字段：
//   jitAvailable / jitStage / jitErrno / jitMessage / jitAction
```

`getStatus()` 一并上报 JIT 状态，使 UI 能显示**运行期看门狗**发现的问题
（否则用户只看到"未运行"，不知道原因）。

### 2.5 UI（`Index.ets`）

- 新增 **JIT 状态面板**，位于启动按钮之前 —— 用户先看到"能不能跑"再决定启动；
- 不可用时显示：**原因 + 可操作建议 + 诊断信息（阶段/errno）**；
- 不可用时**禁用启动按钮**（不提供"用解释器凑合跑"的入口）；
- `aboutToAppear()` 主动查一次，使用户不必先点启动才发现不可用。

---

## 3. 失败诊断语义

`stage` 字段用于精确定位阻塞点（稳定标识，便于日志检索与用户反馈）：

| stage | 含义 | 实测依据 |
|---|---|---|
| `ok` | 全部通过 | — |
| `mmap-rw` | 申请可写内存失败 | 未观测到 |
| `mprotect-rx` | **关键**：提交为可执行被拒 | **回归现象实测模式，errno=22 (EINVAL)** |
| `execute` | 生成的代码执行结果不正确 | 未观测到 |
| `revalidate` | 运行期复检失败（能力在运行中消失） | 对应回归现象的假设 |

面向用户的建议文案区分 `EINVAL` 与其他 errno ——
因为 `EINVAL` 是本项目**实测过的真实故障模式**，其处置方式是"重启设备后重试"。

---

## 4. 验证情况

### 4.1 已完成的验证

| 验证项 | 方法 | 结果 |
|---|---|---|
| 逻辑正确性（正例） | 宿主 macOS/arm64 跑同一份实现 | ✅ `available=1` |
| 失败路径识别（反例） | 传入非法地址 | ✅ `available=0`、`errno=22`、给出说明与建议 |
| 幂等性 | 连续两次启动自检 | ✅ 均成功 |
| 复检稳定性 | 连续 5 次 `RevalidateAlive()` | ✅ 全部通过 |
| HAP 编译 | hvigor `assembleHap` | ✅ `BUILD SUCCESSFUL` |
| 符号入包 | `llvm-nm` / `strings` 查 `libhps2core.so` | ✅ 见下表 |

符号入包核对（`app-hps2/entry/build/.../libhps2core.so`）：

```
T Hps2JitCheck::RunStartupCheck()
T Hps2JitCheck::RevalidateAlive()
JIT_SELFCHECK=available / unavailable ...
JIT_ASSERT=failed has_code_memory=... cpu_is_interp=...
JIT_WATCHDOG=alive / revoked
checkJit
（中文建议文案、stage 名均已入包）
```

### 4.2 尚未验证（需真机）

⚠️ **宿主验证不能替代真机验证** —— 宿主是标准 macOS/arm64，
没有 HarmonyOS 的 SELinux/XPM 策略层。以下必须在真机确认：

| 待验证项 | 预期 |
|---|---|
| 真机启动自检输出 `JIT_SELFCHECK=available` | debug 签名下应通过（与阶段 1 一致） |
| 真机 `JIT_ASSERT=passed cpu_is_recompiler=1` | 确认未退回解释器 |
| 运行期看门狗在正常游戏中持续 `alive` | 不应误报 |
| **复现回归现象时看门狗能捕获** | 若能复现 `EINVAL`，应停机并显示原因，**而非静默降级** |

真机运行方式（需设备连接）：

```bash
cd app-hps2
hdc install -r entry/build/default/outputs/default/entry-default-<signed>.hap
hdc shell aa start -b com.hps2.jitprobe -a EntryAbility
hdc shell hilog | grep -E "JIT_SELFCHECK|JIT_ASSERT|JIT_WATCHDOG|JIT_REVALIDATE"
```

---

## 5. 与未结案回归的关系

**本实现不解决回归的根因，但改变了它的后果**：

| | 实现前 | 实现后 |
|---|---|---|
| JIT 启动时不可用 | 静默退回解释器，界面显示"运行中" | **拒绝启动**，显示原因与建议 |
| JIT 运行中失效 | 崩溃或产出错误结果（原因不明） | **看门狗停机**并报告，日志留痕 |
| 用户能否知道当前状态 | 不能 | 界面显著展示 + `checkJit()` 可查 |

`docs/jit-regression.md` §4 的重启对照实验**仍然待做** ——
那是回答"JIT 能否稳定"的唯一真实途径，本实现只是保证在拿到答案之前
不会出现"以为能跑其实在跑解释器"的误导。
