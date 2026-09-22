# 读档后无法正常游玩 —— 根因分析（第二次诊断，已大幅缩小范围）

**日期**：2026-09-22
**前情**：`docs/savestate-load-issue.md`（现象与直接原因）
**本次进展**：排除了"旧档不兼容"，并定位到**主存未被正确写入**

---

## 1. 已排除：旧档不兼容

用户按建议做了实验：**在当前 build 下重新覆盖存档，再读取**。

结果：**仍然无法正常游玩**。

=> **排除**"存档与 build 不匹配"这一解释。问题在**读取/恢复流程本身**。

## 2. 现象修正：不是死机，是"执行垃圾指令"

对比两次读数（同一会话内的连续采样）：

| 阶段 | 时间窗 | frame 增量 | 折算帧率 |
|---|---|---|---|
| 读档前 | 3 秒 | +180 | **60 fps** ✅ |
| 读档后 | 3 秒 | **+25** | **8.3 fps** ❌ |

PC 在变化（非卡死），`vm_state=2`（Running）——
即模拟器**仍在跑，但严重异常**。

## 3. 决定性证据：EE 在执行未初始化内存

emulog 读档段落（第 480-560 行）完整序列：

```
[34.3621]  ... found 'PCSX2 Internal Structures.dat'
[34.3621]  ... found 'eeMemory.bin'          ← 存档里确实含 EE 主存
[34.3621]  ... found 'iopMemory.bin'
[34.3621]  ... found 'eeHwRegs.bin'
...
[34.3832] iR3000A-ARM64 Recompiler reset.    ← 读档触发重编译器复位
[34.3884] iR5900-ARM64 Recompiler reset.
[34.3903] EE ARM64: Dispatcher generated at 0x111d00000
[34.3949] psxRcntFreeze: ... repairing poisoned state   ← 计时器状态异常
[34.3986] EE ARM64: Entering recompiled code (pc=0x001172F8)
[34.3990] TLB Miss, pc=0x0 addr=0x0 [load]   ← **PC=0x0**，且连续 50 条
   ...（addr 从 0x0 递增到 0xc4，步长 4）
[34.4007] Vif1 running when CHCR == 70000045
[34.4032] Unknown R5900 Standard: 77777777   ← **垃圾指令**
[34.4040] EE: Unrecognized op 77877788
```

### 3.1 `0x77777777` 是未初始化填充，不是随机值

`0x77` 是 PS2 内存的未初始化填充模式。EE 读到整片 `0x77`，
说明**它执行的那段主存里没有代码** —— 而读档后那里本应是游戏数据。

### 3.2 `pc=0x0` 的含义

`TLB Miss, pc=0x0` —— 取指发生在**地址 0**。正常游戏中 PC 不会为 0。
合理的解释：**EE 被恢复到了一个空/错的状态**，随后按 0 地址取指。

## 4. 已定位到的最可疑环节

上游的读档流程（`pcsx2/SaveState.cpp`）：

```cpp
static void PreLoadPrep()
{
    if (THREAD_VU1) vu1Thread.WaitVU();
    MTGS::WaitGS(false);

    std::memcpy(s_tlb_backup, tlb, sizeof(s_tlb_backup));  // 备份 TLB
    mmap_ResetBlockTracking();                              // ← 解除写保护
    VMManager::Internal::ClearCPUExecutionCaches();
}

// 主存写入（SavestateEntry_EmotionMemory -> MemorySavestateEntry）
bool MemorySavestateEntry::FreezeIn(zip_file_t* zf) const
{
    const u32 expectedSize = GetDataSize();
    const s64 bytesRead = zip_fread(zf, GetDataPtr(), expectedSize);  // 直接写 eeMem->Main
    if (bytesRead != (s64)expectedSize)
        Console.WriteLn(Color_Yellow, " '%s' is incomplete ...", GetFilename());
    return true;
}
```

**关键点**：

1. `FreezeIn` **直接往 `eeMem->Main` 写**，没有任何成功/失败返回给流程
   （除了打印一行黄字），**即使写入不完整也返回 true**。
2. 写入的前提是这段主存**没有写保护** —— 由 `mmap_ResetBlockTracking()`
   解开，其范围是 `HostSys::MemProtect(eeMem->Main, Ps2MemSize::ExposedRam, ...)`。
3. `eeMemory.bin` 的大小是 `Ps2MemSize::ExposedRam`。

**因此最可疑的假设**：本项目用 `OVERRIDE_HOST_PAGE_SIZE=0x1000`（4KB 页）
以适配真机 —— 而 `MemProtect`/`mmap_ResetBlockTracking` 的**范围与对齐**
在 4KB 页下是否与 16KB 页假设一致，**需要验证**。
若保护范围没被完整解除，主存写入会**静默失败**（被 SIGSEGV 或写入被忽略），
而流程仍返回 true —— 这与"存档内容正常、但 EE 读到 0x77 填充"吻合。

## 5. 下一步（可执行的检查）

1. **在 4KB 页下验证 `ExposedRam` 的保护范围**
   —— 读档前后打印 `mmap_ResetBlockTracking()` 实际解除的地址与长度。
2. **检查 `zip_fread` 的实际返回值**
   —— 当前只在"不完整"时打黄字，但日志里**没有**该黄字，
   故要么写入成功、要么根本没走到这里。
   需确认 `eeMemory.bin` 的写入是否真的执行了。
3. 考虑在 `FreezeIn` 后**回读校验**（读第一个字节是否为 0x77）
   —— 能直接判定"写入是否生效"。

## 6. 对用户的诚实说明

- **问题已大幅缩小**：不是存档坏、不是 build 不兼容、不是崩溃，
  而是**读档后 EE 主存内容不正确**（读到未初始化填充）。
- **根因尚未最终确认**：最可疑的是 4KB 页下写保护范围的问题，
  但这仍是**假设**，需上面的检查来证实。
- 在修好之前，**即时存档可用于保存、但读取后无法继续游玩** ——
  这是本功能的已知缺陷。
