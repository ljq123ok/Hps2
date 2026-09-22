# 蓝牙手柄接入方案（已确定路线）

**手柄**：盖世小鸡 X5s 拉伸蓝牙手柄
**日期**：2026-09-22

---

## 1. 重大发现：系统已把手柄解析成标准事件

原计划走 OHOS `GameControllerKit`（需新写 `InputSource`）。
但核查 SDK 后发现**一条简单得多且不依赖硬件探测的路径**：

HarmonyOS **已定义完整的手柄按键码**，且 ArkUI 支持接收：

```typescript
// @ohos.multimodalInput.keyCode.d.ts
KEYCODE_BUTTON_A      = 2301
KEYCODE_BUTTON_B      = 2302
KEYCODE_BUTTON_X      = 2304
KEYCODE_BUTTON_Y      = 2305
KEYCODE_BUTTON_L1     = 2307
KEYCODE_BUTTON_R1     = 2308
KEYCODE_BUTTON_L2     = 2309
KEYCODE_BUTTON_R2     = 2310
KEYCODE_BUTTON_SELECT = 2311
KEYCODE_BUTTON_START  = 2312
KEYCODE_BUTTON_MODE   = 2313
KEYCODE_BUTTON_THUMBL = 2314
KEYCODE_BUTTON_THUMBR = 2315

KEYCODE_DPAD_UP    = 2012
KEYCODE_DPAD_DOWN  = 2013
KEYCODE_DPAD_LEFT  = 2014
KEYCODE_DPAD_RIGHT = 2015

// 组件上可监听
onKeyEvent(event: Callback<KeyEvent, boolean>): T
onAxisEvent(event: Callback<AxisEvent>): T
```

**含义**：系统已经把蓝牙手柄的输入解析成标准按键/轴事件，
应用**不需要自己去发现设备、不需要 hidraw、不需要 udev**。
这绕开了原方案的所有不确定性。

### 1.1 摇杆用标准 Linux evdev 轴码

```typescript
// component/enums.d.ts: AxisModel
ABS_X = 0,  ABS_Y = 1        // 左摇杆
ABS_Z = 2,  ABS_RZ = 3       // L2 / R2 扳机
ABS_GAS = 4, ABS_BRAKE = 5
ABS_HAT0X = 6, ABS_HAT0Y = 7 // 十字键
ABS_RX = 8, ABS_RY = 9       // 右摇杆
ABS_THROTTLE = 10, ABS_RUDDER = 11
```

`AxisEvent.axisMap: Map<AxisModel, number>` 直接给出各轴当前值。

**这是标准 evdev 码** —— 说明底层就是 Linux 输入子系统，
HarmonyOS 在其上做了封装并转发给应用。

---

## 2. 实现方案

### 2.1 数据流

```
蓝牙手柄
  → HarmonyOS 输入子系统（解析为 KeyEvent / AxisEvent）
  → ArkUI 组件 onKeyEvent / onAxisEvent
  → N-API（复用现有 vpadButton / vpadAxis 或新增独立通道）
  → PCSX2 Pad
```

**关键复用点**：现有虚拟按键已经打通了
「N-API → SDL 虚拟手柄 → SDLInputSource → PCSX2 Pad」这条链路。
真实手柄只需在其**前端**接上 ArkUI 的事件源即可 —— 下游完全复用。

### 2.2 按键映射表（手柄码 → SDL 虚拟手柄编号）

| HarmonyOS 按键码 | SDL 编号（现有 VpadCodes）| PS2 |
|---|---|---|
| `KEYCODE_BUTTON_A` (2301) | `SOUTH` (0) | × |
| `KEYCODE_BUTTON_B` (2302) | `EAST` (1) | ○ |
| `KEYCODE_BUTTON_X` (2304) | `WEST` (2) | □ |
| `KEYCODE_BUTTON_Y` (2305) | `NORTH` (3) | △ |
| `KEYCODE_BUTTON_SELECT` (2311) | `BACK` (4) | Select |
| `KEYCODE_BUTTON_START` (2312) | `START` (6) | Start |
| `KEYCODE_BUTTON_L1` (2307) | `LEFT_SHOULDER` (9) | L1 |
| `KEYCODE_BUTTON_R1` (2308) | `RIGHT_SHOULDER` (10) | R1 |
| `KEYCODE_DPAD_UP` (2012) | `DPAD_UP` (11) | 十字键上 |
| `KEYCODE_DPAD_DOWN` (2013) | `DPAD_DOWN` (12) | 十字键下 |
| `KEYCODE_DPAD_LEFT` (2014) | `DPAD_LEFT` (13) | 十字键左 |
| `KEYCODE_DPAD_RIGHT` (2015) | `DPAD_RIGHT` (14) | 十字键右 |

**L2/R2 是轴不是按键**（映射到 `VpadAxis.LEFT_TRIGGER/RIGHT_TRIGGER`），
与现有虚拟按键的处理一致。

### 2.3 摇杆轴映射

| AxisModel | SDL 轴（VpadAxis）| PS2 |
|---|---|---|
| `ABS_X` / `ABS_Y` | `LEFTX` / `LEFTY` | 左摇杆 |
| `ABS_RX` / `ABS_RY` | `RIGHTX` / `RIGHTY` | 右摇杆 |
| `ABS_Z` / `ABS_RZ` | `LEFT_TRIGGER` / `RIGHT_TRIGGER` | L2 / R2 |

**注意**：轴值范围需归一化。evdev 轴通常是 -32768..32767（或 0..255 视设备），
需实测 X5s 的实际取值范围后再做换算，**不能假定**。

### 2.4 焦点问题（必须处理）

`onKeyEvent` 只在组件**获得焦点**时触发。因此需要：

- 在游玩页（GameScreen）的根容器上挂 `onKeyEvent` / `onAxisEvent`
- 并确保该容器 `focusable(true)` 且**主动请求焦点**

若不处理，手柄按了没反应 —— 这是最可能的坑，需优先验证。

---

## 3. 待验证（先做，成本低）

1. **X5s 连上后，系统是否真的产生 KeyEvent**？
   验证：在页面挂 `onKeyEvent` 打印 keyCode，按手柄键看日志
2. **轴事件的取值范围与触发频率**
3. **焦点是否需要显式请求**

**这三项都能通过"只加日志、不改逻辑"验证** —— 风险低。

---

## 4. 与虚拟按键的关系

两者**并存**：
- 虚拟按键：`SDL_JOYSTICK_VIRTUAL`，player id 0
- 真实手柄：同样经 `SDL_JOYSTICK_VIRTUAL`（复用现有链路），
  只是事件来源不同

**可加自动切换**：检测到手柄按键事件后，自动隐藏虚拟按键
（`showPad` 开关已具备）。这样用户插上手柄就不用手动关按键。

---

## 5. 下一步

按 §3 先做探测（加日志验证事件能否收到），确认后再实现映射。
**不先写完整实现** —— 因为焦点/事件送达这两点未验证，
若不通需要换方案（退回 GameControllerKit）。
