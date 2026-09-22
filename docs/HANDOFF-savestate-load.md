# 交接：即时存档「读档后卡死」问题

**交接日期**：2026-09-22
**交接人**：dsh
**状态**：🔴 **未修复**。已排除多个因素，问题范围大幅缩小，但根因未确认。

---

## 1. 一句话描述

**读档本身成功（`ok=1`），但恢复运行后 EE 取指得到垃圾指令，游戏卡死。**

---

## 2. 核心矛盾（最关键的一条，请优先关注）

同一时刻的两个事实互相矛盾：

```
事实 A：我直接读 eeMem->Main[0x00116F4C] = 0x8E22004C
        → 反汇编是 opcode 0x23 = LW，**合法 MIPS 指令**
        （另取样 0x0/0x800000/0x1000000 处也都是合法指令）

事实 B：JIT 从同一地址 0x00116F4C 取指得到 0x73414842
        → emulog: "Unknown R5900 MMI: 73414842"
        → "EE: Unrecognized op 36165c"
```

**=> `eeMem->Main` 的内容是对的，但 JIT 看到的内存不是这一份。**

这说明问题很可能在 **JIT 的地址翻译 / fastmem 映射**，
而不是"数据没恢复"。

---

## 3. 已排除的因素（均有实测证据）

| # | 假设 | 结论 | 证据 |
|---|---|---|---|
| 1 | 存档文件损坏 | ❌ 排除 | 存档含全部组件（`eeMemory.bin`、`vu1Memory.bin`、`GS.bin`…），写入链路正常（`.p2s` + `.backup` 都在） |
| 2 | 存档与 build 不兼容 | ❌ 排除 | 用户在当前 build 下重新存档再读，现象相同 |
| 3 | 主存未被写入 | ❌ **排除** | memcheck 实测四处样本全是合法 MIPS 指令 |
| 4 | PC 未正确恢复 | ❌ 排除 | `cpuRegs.pc=0x00116F4C`，合法且 4 字节对齐 |
| 5 | VM 未真正暂停 | ❌ 排除 | `still_in_execute=0`（用握手指标验证，非 `GetState()`） |
| 6 | 读档不在 VM 线程执行 | ❌ 排除 | 已补任务队列，日志确认 `VM thread: running queued task`（线程 id 53650 ≠ UI 线程 50197） |

---

## 4. 本项目已做的三处修复（供参考，也供 Codex 判断是否有错）

### 4.1 读档/存档改为在 VM 线程执行（`22cf3b6`）

上游用 `Host::RunOnCPUThread()` 把读档投递到 CPU 线程；我们的 Host
是未实现的桩（`hps2_host.cpp:305` `pxFailRel`），且 VM 跑在独立线程。

**补的实现**（`napi_init.cpp`）：
- VM 主循环在 **Paused 分支**取出并执行任务
- `Hps2VmSync::RunOnVmThread(fn, timeout)` 供外部投递并等待

### 4.2 修正"形同虚设"的等待（`168e01c`）

原等待条件 `while (GetState() == Running)` 无效 ——
`SetPaused(true)` 会立刻把状态改成 Paused（自己设的），首次检查即通过
（实测 `waited 0ms`）。
改为等待 `g_vm_in_execute`（VM 线程围绕 `Execute()` 置位/清除）。

### 4.3 Paused 时不再调用 Execute（`168e01c`）

原主循环只跳过 `Stopping`/`Shutdown`，**Paused 时仍调 `VMManager::Execute()`**
→ 暂停名不副实。
（此缺陷的症状是日志里那句：
`WARN: Execute returned N times (频繁返回通常意味着 VM 处于 Paused)`）

---

## 5. 完整复现步骤

```
1. 启动 Hps2，选 BIOS + 游戏，启动游戏
2. 玩到能正常出画面（确认 60fps）
3. 点悬浮球 → 存档 → 存到槽 2
4. 继续玩几秒
5. 点「读」读取槽 2
6. 现象：不闪退，但画面卡死（frame 仍在涨、PC 不变）
```

**设备**：HUAWEI Pura X View（`VOL-AL00`），OpenHarmony-7.0.0.105，
API 26，arm64-v8a，4KB 页。

---

## 6. 关键日志（最近一次完整运行）

### 6.1 读档五步全过

```
LOAD step1: pausing VM (was_running=1)
LOAD step2: waited 0ms for Execute() to return; still_in_execute=0 state=3
LOAD step3: about to call LoadStateFromSlot(2) on VM thread
VM thread: running queued task                 <- VM 线程 id 53650
VM thread: queued task finished
LOAD step4: LoadStateFromSlot returned ok=1
LOAD check: after load, cpuRegs.pc=0x00116F4C
LOAD memcheck: at_pc=0x8E22004C | samples 0x0=0x3C1A8001 0x100000=0x00000000
               0x800000=0x8033331E 0x1000000=0x8F939706
LOAD step5: VM resumed
```

### 6.2 恢复运行后立即出错

```
(VMManager) Resuming...
EE ARM64: Entering recompiled code (pc=0x00116F4C)   <- PC 正确
Unknown R5900 MMI: 73414842                          <- 取指是垃圾
EE: Unrecognized op 36165c
Trap exception at 0x002e43a0
Gif Unit - GS packet size exceeded VU memory size!
```

### 6.3 另一次运行中还出现过复位向量

```
EE ARM64: Entering recompiled code (pc=0xBFC00000)   <- EE 复位向量（BIOS 入口）
```

`0xBFC00000` 是 PS2 EE 的复位向量 —— 出现它说明 EE 被重置过，
可能意味着执行流程走了异常/复位路径。

### 6.4 PC 停滞的表现

```
MONITOR: ee_pc=0x8000fe74 frame=487    <- KSEG0 低地址 = EE 异常向量
MONITOR: ee_pc=0x8000fe74 frame=667    <- 同一地址
MONITOR: ee_pc=0x8000fe74 frame=846    <- 同一地址
MONITOR: ee_pc=0x8000fe74 frame=1026   <- frame 在涨、PC 不动
```
（`0x8000FE74 & 0x1FFFFFFF = 0x0000FE74`，约 64KB 处，EE 异常处理区）

---

## 7. 建议 Codex 排查的方向

按我的判断，优先级从高到低：

### 7.1 【最高】JIT 的地址翻译/fastmem 映射与 eeMem->Main 不一致

这是 §2 的核心矛盾。建议查：
- 读档后 `vtlbdata.fastmem_base` 与 `s_fastmem_area` 的状态
- `PostLoadPrep()` 的 `MapTLB`/`UnmapTLB` 是否真的重建了映射
- **本项目特有变量**：`OVERRIDE_HOST_PAGE_SIZE=0x1000`（4KB 页）
  与 `OVERRIDE_HOST_CACHE_LINE_SIZE=64`
  → 建议检查 `vtlb.cpp` 里 `mmap_ResetBlockTracking()` /
  `vtlb_UpdateFastmemProtection()` 在 4KB 页下的行为

### 7.2 检查 `recResetEE` / `eeRecNeedsReset` 的时序

读档会调 `ClearCPUExecutionCaches()` → `Cpu->Reset()` → `recResetEE()`。
`recResetEE()` 在 `eeCpuExecuting==true` 时只置 `eeRecNeedsReset=true`
并 `recSafeExitExecution()`，否则直接 `recResetRaw()`。
**需确认读档时 `eeCpuExecuting` 的值是否符合预期**，以及
`eeRecNeedsReset` 是否在正确的时机被消费（`recEventTest` 里）。

### 7.3 `eeRecExitRequested` 的可能残留

`recSafeExitExecution()` 只置 `eeRecExitRequested=true`，
由 `recEventTest()` 消费。
**若读档前该标志已置位未被消费，读档后可能立即触发一次非预期的 exit。**
建议读档前后打印该标志。

### 7.4 对比上游：在标准 CPU 线程模型下读档是否正常

若能在上游的标准形态（Qt 前端 / 或让 `Host::RunOnCPUThread` 真正实现
为"投递到 VM 线程"而非我们用任务队列模拟）下复现，可判断
**是移植引入的差异，还是上游本身在此配置下也有问题**。

---

## 8. 相关文件与提交

### 关键代码
```
app-hps2/entry/src/main/cpp/hps2_savestate.cpp   读档/存档封装 + 全部诊断日志
app-hps2/entry/src/main/cpp/hps2_savestate.h
app-hps2/entry/src/main/cpp/napi_init.cpp        VM 线程主循环、任务队列、握手标志
app-hps2/entry/src/main/cpp/hps2_host.cpp        Host 实现（RunOnCPUThread 是桩）
```

### 相关提交（按时间）
```
2610408  实现即时存档（复用上游存档槽机制）
4511135  加 LOAD step1/2/3 步进诊断
b760b91  线程修复：暂停-等待-恢复
ff38037  加 cpuRegs.pc 诊断
168e01c  修正等待条件 + Paused 不再 Execute
3756eff  加 eeMem->Main 内容检验
22cf3b6  读档改为在 VM 线程执行（任务队列）
```

### 上游参考
```
upstream/ARMSX2/pcsx2/VMManager.cpp:1842      VMManager::Shutdown（正确停止流程）
upstream/ARMSX2/pcsx2/VMManager.cpp:2091      DoLoadState 全文
upstream/ARMSX2/pcsx2/VMManager.cpp:2964      ClearCPUExecutionCaches
upstream/ARMSX2/pcsx2/SaveState.cpp:52         PreLoadPrep
upstream/ARMSX2/pcsx2/SaveState.cpp:68         PostLoadPrep（MapTLB）
upstream/ARMSX2/pcsx2/SaveState.cpp:519        MemorySavestateEntry::FreezeIn
upstream/ARMSX2/pcsx2/Hotkeys.cpp:96          上游如何投递读档到 CPU 线程
upstream/ARMSX2/pcsx2/arm64/iR5900-arm64.cpp:3442  recExecute（块起始）
upstream/ARMSX2/pcsx2/arm64/iR5900-arm64.cpp:3433  recExecute（函数体，含 pc 打印）
upstream/ARMSX2/pcsx2/arm64/iR5900-arm64.cpp:3400  recSafeExitExecution
upstream/ARMSX2/pcsx2/arm64/iR5900-arm64.cpp:201   recEventTest（含 exitRequested 消费）
upstream/ARMSX2/pcsx2/arm64/iR5900-arm64.cpp:3216  recResetRaw
upstream/ARMSX2/pcsx2/vtlb.cpp:1652            mmap_ResetBlockTracking
```

---

## 9. 对用户的说明（当前状态）

- **即时存档可以「存」，但「读」之后游戏会卡死** —— 这是已知缺陷。
- 存档文件本身是完整、可用格式（`.p2s` + `.backup` 齐全），
  数据没丢。问题在读取后的状态重建。
- 已排除 6 个可能因素（见 §3），问题集中在 **JIT 映射与主存的一致性**。
