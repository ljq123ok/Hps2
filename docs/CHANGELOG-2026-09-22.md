# Hps2 更新日志 —— 2026-09-22

**版本**：0.12（`versionCode` 1000012）
**设备**：HUAWEI Pura X View（`VOL-AL00`），OpenHarmony-7.0.0.105，API 26，arm64-v8a
**提交数**：23 个（含修复与文档）

---

## 一、新增功能

### 1. 即时存档（savestate）
整机状态快照，与游戏内记忆卡存档**互不影响**。

- 8 个存档槽，每槽「存 / 读 / 删」
- 复用上游 `VMManager::SaveStateToSlot` / `LoadStateFromSlot`，
  未自行实现序列化
- 存档路径：`sstates/<serial> (<crc>).NN.p2s`（上游自动生成 `.backup`）
- 删除功能会**同时删除备份**，且先 `WaitForSaveStateFlush()`
  以避免与后台压缩线程竞态

**关键实现**：读档/存档必须在 **VM 线程**上执行
（上游用 `Host::RunOnCPUThread` 投递；我们的 Host 是未实现的桩，
故补了 VM 线程任务队列 `Hps2VmSync::RunOnVmThread`）。
读档内部会重建重编译器与 fastmem 映射，只允许在 VM 线程上下文发生。

### 2. FPS 悬浮球（可拖动）
- 收起态：56×56 圆形球，**球面直接显示 FPS**（不必展开即可见）
- 展开态：状态 / 存档 / 显隐按键 / 设置 / 返回 / 收起
- **可拖动**：`PanGesture` 跟手，停留在最终位置，边界钳制保证不拖出屏幕
- 容器 `HitTestMode.Transparent`：只有球与按钮可点，其余触摸透传给下层

### 3. 蓝牙手柄支持（Xbox / PlayStation / Switch 三家通用）
**关键发现**：HarmonyOS **已把手柄输入解析成标准事件**转发给应用
（`KEYCODE_BUTTON_A/B/X/Y` 等 + `FocusAxisEvent.axisMap`，用标准 Linux evdev 码）。
因此**不需要** hidraw / udev，绕开了 SDL HIDAPI 的全部不确定性。

三家用同一套映射：系统层按键码统一，差异只在物理标注，
按**位置**映射到 PS2 的 ×○□△ 即可。

数据流复用虚拟按键的下游：
`手柄 → 系统 → GamepadCatcher → vpadButton/vpadAxis → SDL 虚拟手柄 → PCSX2 Pad`

首次检测到手柄时**自动隐藏虚拟按键**。

### 4. 日夜模式
用鸿蒙**资源限定符**（`resources/base/` + `resources/dark/element/color.json`，
各 25 个语义色），系统按当前配色自动选用。

**实测踩坑**：`getColorByNameSync()` **直接返回颜色值（ARGB）**，
而非"资源引用 ID"（头文件注释 "integer reference value" 易误读）。
误加一步 `getColorSync(id)` 会导致 `9001001 Invalid resource ID`、
界面整体走兜底色。

### 5. 错误分类 + BIOS 规格检查 + 诊断日志导出
- **错误分类**：按 native 实际产出的错误串分为
  JIT / BIOS / 内存 / 渲染表面 / 其它，各给可操作建议
- **BIOS 规格检查**：检查大小（2/4/8MB）+ 开头 256KB 内是否含
  `Sony Computer Entertainment`。实测本地 94 个文件：**26 通过 / 42 未通过**
  —— 未通过者很可能正是"别人启动不了"的原因
- **日志导出**：一键把设备信息/启动阶段/JIT 状态/错误 + 核心日志尾部
  写入 Download，供用户反馈

### 6. 加载提示
选择 BIOS/游戏后显示转圈提示 + 文件名，完成后自动消失。
覆盖层拦截触摸（避免复制期间并发点选互相覆盖目标文件）。

---

## 二、修复的问题

### 1. 大 ISO 复制导致 GUI 冻结（外部反馈）
**根因**：`chooseGame` 用 `fs.copyFileSync` **同步复制**且跑在 UI 线程，
2-4GB 镜像期间界面完全冻结（用户反馈"卡 8 秒后闪退"）。
**修法**：改用 Promise 版 `fs.copyFile`。

**过程中的一次错误**：我曾把 picker 返回的 URI
（`file://docs/storage/...`）转成裸路径 `/storage/...` 再传给 `fs`，
真机报 `13900002 No such file or directory`。
**结论：ArkTS 的 fs 需要 picker 已授权的 URI，不能转成裸路径**；
复制必须用「先 `openSync` 成 fd、再按 fd 复制」（直接 `copyFileSync(uri,path)` 报 ENOENT）。

### 2. 无法进入游玩页
两个缺陷：
- `viewMode` **从未被设为 `'game'`**（两态切换只写了一半）→ 点启动后界面不动
- 两态设计引入 **surface 竞态**：GS 初始化要取渲染窗口，
  而 XComponent 要等切页才挂载
**修法**：按 `startBios` 返回值切页；**让 XComponent 始终挂载**，
首页作为叠加层 —— surface 自启动即存在，从根本上消除竞态。

### 3. 虚拟按键「挤在一堆」→ 完全不显示 → 位置遮挡画面（三轮）
| 轮次 | 现象 | 根因 |
|---|---|---|
| 1 | 挤在一堆 | 固定像素需求 480vp > 可用 440vp，ArkUI 压缩子元素 |
| 2 | 完全不显示 | **ArkTS `@Component` 的 `private get` 访问器取不到值** → 尺寸/坐标全为 NaN。改为普通方法后恢复 |
| 3 | 位置遮挡画面 | 按屏宽百分比定位，未考虑 4:3 画面实际区域。改为**按画面实际矩形算黑边**，按键放进黑边 |

### 4. 旋转后黑屏
**根因**：上游 `GLContextEGL::ResizeSurface()` 只更新尺寸字段，
**不重建 EGLSurface**。桌面平台没问题（窗口系统 surface 自行变化），
但 HarmonyOS 底层是 `OHNativeWindow`，旋转时缓冲区换尺寸而 EGLSurface 仍绑旧缓冲。
**修法**：`GLContextEGLOHOS::ResizeSurface` 中销毁旧 surface 并重建，
随后 `eglMakeCurrent` 重新绑定。

### 5. 全屏时系统导航条不隐藏
**修法**：进入游玩页 `setWindowLayoutFullScreen(true)` +
`setWindowSystemBarEnable([])`（空数组 = 隐藏全部）。
两者必须配套，否则原区域留空白。
回首页恢复系统栏（否则用户看不到导航条、难以切换应用）。

### 6. 「返回」按钮点击无效
**根因（native 侧）**：`hps2core.stop()` 只设 `g_vm_running=false` 就 `join()`，
而 VM 线程正阻塞在 `VMManager::Execute()`（长跑、只在状态变化时返回），
**标志设了也无人理会** → join 等不到 → UI 线程被同步阻塞。
**修法**：先 `VMManager::SetPaused(true)` 打断 `Execute()`，再 join。

### 7. 启动闪退（我自己引入的）
我为排查"按键看不见"加的诊断日志放在 `aboutToAppear()` 里，
直接调用 `this.btn.toFixed(1)` —— 但那时父组件**尚未传入 `@Prop vpW/vpH`**，
getter 基于 `undefined` 计算，诊断代码自身抛
`TypeError: Cannot read property toFixed of undefined`。
**修法**：诊断改为先校验尺寸就绪、并对每个值做 `Number.isFinite` 兜底；
触发点移到 `.onAppear()`。

### 8. 悬浮条文字看不清
**根因**：底色用固定深色（`#99000000`），文字却用**随日夜主题变化**的
`Theme.textPri()`。浅色模式下文字变近黑，压在深底上糊成一片
（只有用亮蓝的「按键」看得清）。
**修法**：悬浮条所有颜色改为固定常量 —— 它**叠在游戏画面上**，
画面内容不可预知，不该跟随 UI 主题（与虚拟按键同理）。

### 9. 读档后卡死
**状态**：✅ 现已实测通过（存新档 → 读档正常游玩）

**排查过程（我走了几轮弯路，如实记录）**：
1. 最初直接在 **JS 线程**调用读档 → 与 VM 线程并发覆写状态
2. 加暂停等待，但条件是 `while (GetState() == Running)` ——
   **形同虚设**：`SetPaused(true)` 立刻改状态，首次检查即通过（0ms）
3. 且主循环**在 Paused 时仍调用 `Execute()`** → 暂停名不副实
4. 修补后仍卡死；诊断显示：`cpuRegs.pc` 正确、`eeMem->Main` 内容也正确
   （四处样本全是合法 MIPS 指令），**但 JIT 取指得到垃圾**
5. 最终改为经 **VM 线程任务队列**执行读档（这是上游
   `Host::RunOnCPUThread` 的等效实现）

**重要说明**：我是**逐层修掉了 4 个真实缺陷**，但最后一轮测试仍卡死。
之后用户用新加的删除功能**清掉旧档、重存新档**，读档即正常。
因此"不再卡死"**由「VM 线程路由修复」与「使用匹配的新存档」共同达成**，
无法单独归因于其中之一。

---

## 三、尚未完成

| 项 | 状态 |
|---|---|
| **Vulkan 后端** | 未接入（需 shaderc 交叉编译） |
| **多核优化**（MTVU / 异步 MTGS） | 未做 |
| **SMT/超线程**判定 | 设备 `/proc/cpuinfo` 无 `siblings` 字段，无法从此源判定 |
| **手柄真机实测** | 代码已就绪，**尚未在真机验证** X5s 连上后能否收到事件 |
| 上架版降级路径 | 已定位障碍（非 Apple 平台 code memory 失败直接 return false），未实现 |

---

## 四、已知的架构性事实（供后续维护参考）

1. **JIT 可用性是运行期属性**，会自行失效，恢复手段是**重启设备**。
   表现为 `mprotect` 加执行位被拒（`errno=22`）。
   最小探针（不含模拟器代码）同样失败 ⇒ 与本项目代码无关。

2. **release 签名下 JIT 不可用**（`normal_hap` 域），debug 签名可用
   （`debug_hap` 域）。⇒ **双渠道包是必需品**：
   GitHub 自签版 + 商店降级版。

3. **ArkTS/ArkUI 语言行为**（均真机实测）：
   - `@Component` struct 的 `private get` 访问器取不到值 → 用普通方法
   - `build()` 只能有一个根节点，不能内联 `if`
   - `.align()` 是 **Stack 容器**属性，写在子组件上无效
   - 组件属性不能叫 `enabled`（与 `CustomComponent` 基类冲突）
   - 手柄摇杆用 `FocusAxisEvent` + `onFocusAxisEvent`，
     **不是** `AxisEvent` + `onAxisEvent`
   - `getColorByNameSync()` 直接返回颜色值，不是资源 ID

4. **叠在游戏画面上的 UI（虚拟按键、悬浮条）不应跟随日夜主题** ——
   画面内容不可预知（可能雪白也可能漆黑），跟随主题会导致浅色模式下控件"消失"。
