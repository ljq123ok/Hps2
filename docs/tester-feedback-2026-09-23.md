# 外部测试反馈分析（2026-09-23）

**测试者设备**：HarmonyOS 7.0.0.107 测试设备（标识已脱敏）
**我们的测试机**：HarmonyOS 7.0.0.105 折叠屏测试设备（标识已脱敏）
**游戏**：《最终幻想12 国际黄道版》

> 不同机型 + 不同系统版本 ⇒ 反馈的问题可能具有普遍性，非本机特有。

---

## 反馈的三条问题

1. 关闭游戏后再开**会闪退**
2. **Xbox 系列手柄无法识别**
3. **音乐不正常**

---

## 问题 1：关闭游戏后再开闪退

### 1.1 已定位的可疑代码（静态分析，未经真机复现）

**可疑点 A：`std::thread` 重新赋值可能触发 `std::terminate`**

```cpp
// napi_init.cpp:963
g_vm_thread = std::thread(VMThreadMain);   // 直接赋值
```

`std::thread` 的赋值运算符要求右侧线程可 joinable、左侧**不可 joinable**。
若 `g_vm_thread` 此时仍处于 joinable（上次停止未彻底 join），
赋值会调用 `std::terminate()` ⇒ **立即闪退**，且不产生常规崩溃日志。

**我们目前只有 `NapiStop` 一条路径会 join。**
若存在其它路径（启动失败、异常退出）使线程未被 join，
再次启动就会踩到这个终止条件。

**可疑点 B：前端的 stop/start 竞态**

```typescript
// Index.ets exitGame()
this.beginLoading('正在停止模拟器…');
setTimeout(() => { this.stopBoot(); ... }, 50);   // ← 延迟 50ms
```

延迟是为了让"正在停止"提示先绘制出来。
但在这 50ms 窗口内，界面已回到首页、**"启动游戏"按钮可点**：

```
用户快速点击"启动" → startBios() → 此时 VM 仍在运行
  → native 的 NapiStartBios 检查 g_vm_running 为真 → 直接返回 1
随后 50ms 到期 → stopBoot() 执行 → **刚启动的 VM 被停掉**
  → 界面已切到游玩页但 VM 已停 ⇒ 黑屏 / 后续操作异常
```

**可疑点 C：停止后未重置的静态状态**

以下状态在 `NapiStop` 中**均未重置**：

```
g_jit_available      g_vm_in_execute     g_last_error
g_vm_task_pending    g_vm_task_running
```

其中 `g_vm_task_pending` / `g_vm_task_running` 与读档任务队列有关 ——
若停止时恰有任务排队/执行中，残留的 pending 标记会让**下一次启动**的
`RunOnVmThread` 误判"已有任务忙"，或让 CVM 线程执行到已失效的闭包。

### 1.2 需要做的验证

- [ ] 真机复现：启动游戏 → 返回 → 立即再启动，抓 `cppcrash`
- [ ] 检查 `g_vm_thread` 是否总在 joinable 前被赋值
- [ ] 在 `NapiStop` 中重置上述全部静态状态
- [ ] 移除 `exitGame` 的 50ms 延迟竞态（改用同步、或加"停止中"禁用启动）

---

## 问题 2：Xbox 系列手柄无法识别

**这是我一直标记为「未真机验证」的点，现在有了实测证据。**

### 2.1 需要先区分两种"无法识别"

| 情况 | 含义 |
|---|---|
| 应用完全收不到按键事件 | 我的 ArkUI 事件方案（`onKeyEvent` / `onFocusAxisEvent`）未生效 |
| 收到事件但映射不对 | 按键码与预期不符，改映射表即可 |

**现有诊断日志可区分**：`HPS2_PAD` 标签下会打印
`KEY code=... type=...` / `AXIS model=... raw=...`：
- **有这些行** → 事件收到了，问题在映射
- **没有这些行** → 事件未送达，需换方案

### 2.2 若事件未送达，可能的原因（按可能性排序）

1. **焦点问题**：`onKeyEvent` 只在组件获得焦点时触发。
   我们已加 `.onAppear(() => requestFocus(FOCUS_ID))`，但
   **在真机上是否成功从未验证**（日志会打印 `requested focus for gamepad catcher`）。
2. **Xbox 手柄的按键码与预期不同**：我们按 HarmonyOS 标准码
   （`KEYCODE_BUTTON_A=2301` 等）映射，但实际设备可能上报别的值。
3. **手柄需要先被系统识别**：蓝牙配对后在系统层面是否已被正确识别为手柄。
4. **`GamepadCatcher` 只在游玩页挂载** —— 若在首页测试则收不到事件。

### 2.3 备选方案（若 ArkUI 方案不通）

OHOS 官方 `GameControllerKit`（`libohgame_controller.z.so`，
`OH_GameDevice_RegisterDeviceMonitor` + 逐键回调），
需新写一个 `InputSource` 实现。当前代码中**引用数为 0**。

### 2.4 需要测试者提供的信息

**关键**：让他启动游戏后按手柄键，然后把 `HPS2_PAD` 标签的日志发给我们。
（若日志为空，说明事件根本没到应用。）

---

## 问题 3：音乐不正常

### 3.1 已知的音频现状

设备日志显示音频**已经建立**：

```
Creating OHAudio audio stream, sample rate = 48000, expansion = Disabled,
  buffer = 50, latency = 20, stretching enabled
OpenHarmony audio negotiated format: 48000 Hz, 2 channels, sample format 1,
  callback frames 4458
OpenHarmony audio stream prepared: 48000 Hz, stereo format 1
```

即：**OHAudio 后端已接入、流已创建**，并非"没有声音"。

### 3.2 "不正常"的具体表现需要澄清

可能是：
- 爆音/断续（缓冲或时序问题）
- 音调不对（采样率/时钟）
- 延迟明显（buffer=50、latency=20 的组合）
- 与画面不同步
- 只有部分音轨（如只有 BGM 没有音效）

**不同表现对应完全不同的修法**，不能凭猜测改。

### 3.3 另注

`expansion = Disabled` —— SPU2 的混响（reverb）被禁用，
会影响部分游戏的音效听感。这可能是"不正常"的一个来源，需确认是否刻意为之。

### 3.4 需要测试者提供的信息

- 具体是"爆音 / 断续 / 音调不对 / 延迟 / 缺音轨"中的哪一种
- 是否所有游戏都如此（我们已知《最终幻想12》这一个案例）
- 关闭 MTVU 后是否改善（MTVU 改变了时序，可能影响音频同步）

---

## 处理建议（按优先级）

| # | 项 | 理由 |
|---|---|---|
| 1 | **修闪退** | "不能用"级问题；且有明确的可疑代码可查 |
| 2 | **辨明手柄"无法识别"的层级** | 只需一条日志即可确定方向；且这是我方案的最大未验证点 |
| 3 | **澄清音频"不正常"的具体表现** | 描述不清则无法对症，避免盲目改动 |

**三者都需要测试者的补充信息**（尤其 2 和 3）。
在拿到之前，我可以先做 1 的静态修复（重置静态状态 + 消除竞态），
但那**需要在真机上复现验证**，不能仅凭代码推断就宣称修好。
