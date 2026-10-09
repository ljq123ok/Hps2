# Hps2 未修复 Bug 交接（给 Codex）

> # ✅ 已解决 —— 本文的"未修复"结论已作废（2026-10-09 更新）
>
> **本文档写于 2026-10-07，当时两个 bug 确实都未验证。之后均已修复并真机验证。**
>
> | 本文声称 | 实际结果 | 证据 |
> |---|---|---|
> | Bug A 拖动布局「还修好」（§1） | ✅ 已修复并验证 | 拖动后 D-pad 框实测 `[143,368]→[214,367]`，重启保持；后续又修掉更深的**跟手比例**问题（见下） |
> | Bug B 内外屏切换「画面位置不对」（§2） | ✅ 已修复并验证 | `NotifyResize: apply posted to CPU thread` + `display resize applied`；折叠/展开多轮成功 |
> | 「未推送；远端 = 4a9032b」（§头部） | 已推送 | `origin/master` = `88d33df`（2026-10-09） |
> | 「5 个文件未提交」（§3） | 已提交 | 见 `d219204` / `9a5d88` / `b4cabb0` / `349b857` |
>
> **额外发现（本文未记载）**：Bug A 当时只是"能拖、能存"，**跟手比例只有 36%**
> （手指移 300px、控件只走 107px ≈ 1/2.75）。根因是 `windowX/windowY` 按官方
> 文档单位是 **vp**，而代码误当 px 又除了一次 density。已在 `d219204` 修复，
> 实测恢复 1:1（300px→292px、200px→196px）。
>
> **因此：请把本文当作历史诊断记录阅读，不要据其"未修复"结论安排工作。**
> 下面保留原文，因为其中的排查过程与已排除项仍有参考价值。
>
> ---

**日期**：2026-10-07
**交接方**：dsh
**接手方**：Codex
**当前 HEAD（当时）**：`cc48034`（未推送；远端 `origin/master` = `4a9032b` v0.14）
**工作区（当时）**：5 个文件有**未提交**改动，共 +764 / −169 行

> ⚠️ **本文档只记录已核实的事实。** 凡未经真机验证的结论都显式标注。
> 上一轮交接中我曾因"只在主仓库 grep 就下结论"而给出错误判断，
> 请以本文的"证据"栏为准，不要沿用我的推断。

---

## 0. 一句话现状（当时）

**两个 bug 都还没修好。** 最新一次修改（自持状态 + 尺寸应用投递）**已构建通过并装机，但尚未在真机验证过**——设备在验证前掉线。

---

## 1. Bug A：虚拟按键布局编辑器无法拖动

### 现象（用户实测）

- 能进入编辑页（虚线框、透明度滑杆、配色、保存按钮都正常显示）
- **拖动十字键/摇杆的虚线框，按键不动**

### 已确证的事实链（真机日志，非推断）

| 环节 | 证据 | 结论 |
|---|---|---|
| 拖动事件到达 | `HPS2_DRAG: group=dpad px=(2.4,1.8) vp=(0.87,0.65)` 大量输出 | ✅ 正常 |
| 到达父组件 | `HPS2_CHAIN_1: parent received drag group=dpad` | ✅ 正常 |
| 版本号自增 | `HPS2_CHAIN_2: padLayoutVersion -> 67` | ✅ 正常 |
| 数据落盘 | `saved pad layout`；`pad-layout.json` 内 `dpad dx=0.067` | ✅ 正常 |
| **组件重渲染** | **拖动期间完全没有 `HPS2_PAD_RENDER` 输出** | ❌ **断在这里** |

**关键判定**：`Index` 侧一切正常（事件、数据、持久化），但 `VirtualPad` 的 `build()` **在拖动后从未重新执行**。

### 已排除的假设（都实测证伪，请勿重复尝试）

| 假设 | 如何证伪 |
|---|---|
| `Map` 深拷贝失败 | 改为 `Array` 后问题依旧 |
| `@Prop` 跨层不传播 | 改用 `@StorageLink` 后依旧；且 `dx` 值本身正确 |
| 版本号没变化 | 版本号从 2 涨到 428，正常 |
| `@Watch` 没触发 | 触发 429 次 |
| `@Builder` 值传递限制 | 改为对象参数 + 25 处调用点后依旧；且内联渲染也无效 |
| 数组快照路径断 | 改用 primitive `@State` 后依旧 |

**共同点**：以上五类"从外部传播进来的状态"**都无法让 `VirtualPad` 重绘**。

### 当前代码里的修法（**未验证**）

`VirtualPad.ets` 改为**自持状态**，不再依赖任何跨组件传播：

```
拖动 → applyLocalDelta() → this.offsets = next   ← 写组件自身 @State
                         → pushLocalToStore()     ← 同步给父组件持久化
```

依据：ArkUI 对「组件写自身 `@State`」必定重绘。

**验证方法**：拖动后观察是否出现 `HPS2_VPAD_LOAD` / `HPS2_PAD_RENDER`，以及按键是否跟随移动。

### 若仍未修好，建议排查方向

1. **`build()` 未被标记脏**：`VirtualPad` 挂在 `GameScreen` 的 `Stack` 里，
   而 `GameScreen` 自身不订阅任何布局状态。可尝试让 `GameScreen` 也订阅版本号。
2. **`@Builder` 的 `as XxxSpec` 断言**：官方文档称「按引用传递只在传入**一个参数且该参数直接传入对象字面量**时生效」。
   当前调用形如 `this.padButton({...} as BtnSpec)`，**类型断言是否破坏"直接字面量"条件，文档未明确**——这是一个**未验证的可疑点**。
3. **组件实例生命周期**：`HPS2_VC_LIFE` 实测只出现 2 次（组件创建），
   可确认是否存在"实例活着但被冻结"的情况。

---

## 2. Bug B：内外屏切换后画面位置不对且无法全屏

### 现象（用户实测）

外屏（折叠）启动 BIOS 正常 → **展开内屏** → 画面位置不对、没有全屏。

### 已确证的根因（静态代码分析，高置信）

```
hps2_video.h:50      声明 ApplyPendingSettingsOnCPUThread()
hps2_video.cpp:132   定义它 —— 内部才调 MTGS::ResizeDisplayWindow + UpdateDisplayWindow
hps2_video.cpp:174   真正的窗口 resize 在这里
                      ↓
napi_init.cpp:1354   NotifyResize(...)              ← ArkTS 送来新尺寸
hps2_video.cpp:222   NotifyResize 只做 s_pending_width/height.store()   【仅暂存】
                      ↓
              ❌ 全工程没有任何地方调用 ApplyPendingSettingsOnCPUThread()
```

**验证方式**：修复**之前** `grep -rn "ApplyPendingSettingsOnCPUThread" app-hps2/` 共 3 处命中
——1 声明（`hps2_video.h:50`）、1 定义（`hps2_video.cpp:132`）、1 注释，**零调用点**。
（现已由本次改动加上调用点：`napi_init.cpp:1375`，即下方"当前修法"，**尚未验证**。）

**为什么启动时正常**：`ApplyPendingConfigBeforeVM()`（`napi_init.cpp:561`）**有**被调用，所以**启动时**尺寸/倍率正确；只有**运行期变更**这条路径断了。

### 相关背景（已核实）

- ArkTS 侧的 vp→px 换算**已经修好**：`GameScreen.vp2px()`，真机日志证实
  `setSurface(1264x1664 px [vp=460x605, density=2.750])`
- 沉浸式与 surface 顺序：日志显示 `Immersive.set(1) done` 之后
  `onAreaChange` 会重新触发，尺寸自动校正为满屏（`2584x1828`）。
  **但那只在启动路径有效**，内外屏切换时是否重新触发**未验证**。

### 当前代码里的修法（**未验证**）

在 `NapiNotifyResize` 中投递到 VM 线程应用：

```cpp
if (ok) {
    const bool dispatched = Hps2VmSync::RunOnVmThread([]() {
        Hps2Video::ApplyPendingSettingsOnCPUThread();
    }, 3000);
    LOGI("NotifyResize: apply dispatched=%{public}d", dispatched ? 1 : 0);
}
```

依据：MTGS 调用必须在 CPU 线程；`RunOnVmThread` 内建 `g_vm_running` 检查与串行化。

**验证方法**：切换内/外屏后观察 `NotifyResize: apply dispatched=1`，以及画面是否居中且全屏。

---

## 3. 当前工作区的改动清单（全部未提交）

| 文件 | 改动 | 状态 |
|---|---|---|
| `app-hps2/entry/src/main/cpp/napi_init.cpp` | +26 | Bug B 修复（投递应用尺寸）|
| `.../ets/components/VirtualPad.ets` | +435 −122 | Bug A 修复（自持状态）+ 大量诊断 |
| `.../ets/components/GameScreen.ets` | +56 −9 | vp→px 换算 + 透传 editMode |
| `.../ets/pages/Index.ets` | +138 −23 | 编辑器 UI + 布局持久化 + 诊断 |
| `.../ets/common/PadLayout.ets` | +109 −15 | 布局模型（Array 而非 Map）+ 共享单例 |

**构建状态**：`BUILD SUCCESSFUL`（hvigor，JIT 版 `HPS2_STORE_BUILD=OFF`）
**签名安装**：已完成（`/tmp/hps2-fullfix.hap`，2026-10-07 15:36）
**真机验证**：❌ **未做**（设备在验证前掉线）

---

## 4. 需要清理的诊断代码

以下日志是排查期间加的，**修好后建议删除**（当前保留可用于本次验证）：

| 标签 | 位置 | 用途 |
|---|---|---|
| `HPS2_DRAG` | VirtualPad | 拖动位移（px/vp/归一化）|
| `HPS2_PAD_RENDER` | VirtualPad | 渲染坐标（不节流不去重）|
| `HPS2_VPAD_LOAD` | VirtualPad | 挂载时载入布局 |
| `HPS2_VC_LIFE` | VirtualPad | 组件创建 |
| `HPS2_VPAD_MOUNT` | VirtualPad | 挂载时版本号 |
| `HPS2_CHAIN_1/2` | Index | 父组件回调 / 版本号写入 |

⚠️ **`VirtualPad.ets:840-850` 有一段过时注释**，声称 `build()` 里有
`if (this.layoutVersion >= 0)` 用于登记依赖——**该 if 已被移除**，
注释未同步。属文档瑕疵，非功能缺陷（修复 1 已改为自持状态）。

---

## 5. 构建 / 签名 / 安装方式（已跑通）

```bash
# 构建（JIT 版）
cd app-hps2
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

**签名**（关键，踩过坑）：

- 密钥库：`~/.ohos/config/hps2-mate60-debug-20261001.p12`
- Profile：`/tmp/hps2-hop-20261006.p7b` ← **必须用这个**
- 证书：`~/Downloads/hps2-mate60-debug-20261001.cer`
- 口令：macOS 钥匙串条目 `Hps2 Mate60 Debug 20261001`
- 工具：`hap-sign-tool.jar sign-app`（参数见 git 历史或我的会话）

> ⚠️ **坑 1**：`~/.ohos/config/hps2-mate60-debug-20261001.p7b` 只绑 **Mate 60**，
> 当前设备是 **Pura X Max（HOP-AL10）**，用它会报
> `device is unauthorized — UDID not in profile`。
> 含本机 UDID 的 profile 是 `/tmp/hps2-hop-20261006.p7b`。
>
> ⚠️ **坑 2**：`/tmp` 会被系统清理。**该 profile 一旦丢失，就无法再签名安装到这台设备**——
> 建议尽快备份到安全位置。

---

## 6. 环境事实

| 项 | 值 |
|---|---|
| 测试设备 | HUAWEI Pura X Max 典藏版（`HOP-AL10`），折叠屏 |
| 系统 | OpenHarmony-7.0.0.105 / API 26 / arm64-v8a |
| 内屏（展开）| 1828×2584 px；横屏 2584×1828 |
| 外屏（折叠）| 1264×1848 px |
| 屏幕密度 | 2.75（vp→px 换算比）|
| 包名 | `com.hps2.jitprobe` |
| hdc | `/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc` |

---

## 7. 我的建议排查顺序

1. **先验证当前两个修复**（构建已在，只需装机 + 真机操作）
   - Bug A：拖十字键，看是否出现 `HPS2_VPAD_LOAD`/`HPS2_PAD_RENDER`
   - Bug B：切换内外屏，看是否出现 `NotifyResize: apply dispatched=1`
2. 若 Bug A 仍未好，**优先查 `as XxxSpec` 断言**（第 1 节建议方向 2）——
   那是我引入的、且官方文档未明确覆盖的变量
3. 若 Bug B 仍未好，检查 `onAreaChange` 在内外屏切换时**是否真的触发**
   （可加日志到 `GameScreen` 的 `onAreaChange`）

---

## 8. 备份与回退

| 位置 | 内容 |
|---|---|
| `backup/pre-align-20261006` 分支 | 对齐 v0.14 前的状态 |
| `.backup-fullfix-20261007-1534/` | 本次修复前的 3 个文件 |
| `.backup-dpad-probe-20261007-1506/` | D-pad 探测前 |
| `.backup-hA-fix-20261007-1519/` | H-A 方案前 |
| `.backup-bugfix-20261006-2258/` | 更早一轮 |

均未纳入版本库（`.gitignore` 已覆盖部分）。**交接后请自行判断是否保留。**
