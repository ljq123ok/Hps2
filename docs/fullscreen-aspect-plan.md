# 全屏显示与横竖屏适配方案

**用户要求**：横竖屏都要支持；虚拟按键与手柄都要能全屏显示画面。

---

## 1. 已核实的上游机制

### 1.1 宽高比由 `AspectRatioType` 控制（`pcsx2/Config.h:224`）

| 模式 | 语义 |
|---|---|
| `Stretch` | **铺满整个窗口**（`targetAr = clientAr`）|
| `RAuto4_3_3_2` | 自动（默认；有宽屏补丁时跟随）|
| `R4_3` / `R16_9` / `R10_7` / `R19_5_9` / `R20_9` / `R21_9` | 固定比例 |
| `Custom` | 自定义（clamp 到 0.5–5.0）|

### 1.2 关键代码（`GSRenderer.cpp:412-419`）

```cpp
static GSVector4 CalculateDrawDstRect(s32 window_width, s32 window_height, ...)
{
    const float clientAr = f_width / f_height;

    float targetAr = clientAr;                    // ← 默认就是"铺满窗口"
    if (CurrentAspectRatio == RAuto4_3_3_2) { targetAr = 4/3; ... }
    else if (CurrentAspectRatio == R4_3)   { targetAr = 4/3; }
    ...
    // 注意：Stretch 不在任何分支里 → targetAr 保持 clientAr → 铺满
}
```

**结论**：`Stretch` 就是"铺满窗口"，无需改渲染器，只要设置配置项。

### 1.3 上游对手机场景的说明（`Config.h:231-234`，原文注释）

> Ultrawide. Only meaningful with a widescreen/ultrawide patch applied — without one
> the game still renders 4:3 content and this just crops or pillarboxes it.
> **Requested for fold and tablet users, DeX, and phones driving a 21:9 display,
> who otherwise had to use Stretch and accept the distortion.**

即上游已知"手机用户要么用 Stretch 接受变形，要么留黑边"。

### 1.4 运行期改尺寸的 API（旋转时必须用）

```
pcsx2/MTGS.h:73   void MTGS::ResizeDisplayWindow(u32 width, u32 height, float scale);
pcsx2/MTGS.h:74   void MTGS::UpdateDisplayWindow();
```

上游用法（`MTGS.cpp:1006-1021`）—— 都通过 `RunOnGSThread` 投递到 GS 线程：

```cpp
void MTGS::ResizeDisplayWindow(u32 width, u32 height, float scale)
{
    pxAssertRel(IsOpen(), "MTGS is running");
    RunOnGSThread([width, height, scale]() {
        GSResizeDisplayWindow(width, height, scale);
        if (VMManager::GetState() == VMState::Paused)
            GSPresentCurrentFrame();
    });
}
```

**旋转屏幕时必须调用它**，否则视口仍是旧尺寸（会出现画面错位或只占一角）。

---

## 2. 本机设备的实际数字

设备：Pura X View（`VOL-AL00`），比例 16:9.5 ≈ **1.68:1**

### 竖屏

| 模式 | 结果 | 评价 |
|---|---|---|
| `R4_3` | 画面铺满宽度，高度只占 **55%**，上下各留 22% 黑边 | 不变形，黑边大 |
| `Stretch` | 100% 铺满 | **纵向拉伸 1.81x，明显变形** |

### 横屏

| 模式 | 结果 | 评价 |
|---|---|---|
| `R4_3` | 画面铺满**高度**，左右留黑边 | ✅ 黑边正好放虚拟按键 |
| `Stretch` | 100% 铺满 | 横向拉伸 1.26x，变形较轻 |

> 横屏 `Stretch` 的变形（1.26x）比竖屏（1.81x）**小得多**，是可接受的。

---

## 3. 方案：做成可切换设置，默认按方向推荐

### 3.1 设置项

在设置里提供「画面比例」选项：

| 选项 | 说明 |
|---|---|
| **自动**（默认）| 横屏 → `Stretch`（变形小、满屏）；竖屏 → `R4_3`（不变形）|
| 保持 4:3 | 始终 `R4_3`，黑边放虚拟按键 |
| 铺满屏幕 | 始终 `Stretch`，接受变形 |
| 宽屏 16:9 | `R16_9`（适合有宽屏补丁的游戏）|

**「自动」的默认策略**：横屏用 Stretch（1.26x 变形可接受），
竖屏用 R4_3（1.81x 变形太大，宁可留黑边放按键）。

### 3.2 旋转适配

```
ArkUI onAreaChange（或窗口尺寸变化回调）
  → 检测宽高是否互换（方向变了）
  → 重新 pushSurface（native 更新 OHNativeWindow 尺寸）
  → native 调 MTGS::ResizeDisplayWindow(w, h, scale)
  → GS 重建视口与投影
```

**关键**：仅改 surface 尺寸不够 —— GS 的正交投影矩阵是在
`GSDeviceOGL.cpp:3390` 用 `m_window_info.surface_width/height` 算的
（本项目已在此处踩过坑：见 `docs/stage4-resolution-issue.md`），
必须让 GS 知道新尺寸。

---

## 4. 待办

- [ ] module.json5 配置支持横竖屏（当前未配置 orientation）
- [ ] 设置项「画面比例」+ 持久化
- [ ] 旋转时调用 resize API
- [ ] 虚拟按键布局随方向调整（参考设计稿；PPSSPP 的做法是横竖屏各自独立布局）
- [ ] 手柄接入后自动隐藏虚拟按键
