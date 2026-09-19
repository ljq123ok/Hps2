# 蓝牙手柄接入方案

**目标**（用户要求）：接入蓝牙手柄操控；随后重做前端。

---

## 1. 已确认的现状

### 1.1 SDL 手柄框架**已在工作**（真机日志）

```
SDLInputSource: Using Controller DB from resources.
SDLInputSource: 1 gamepad mappings are loaded.
SDLInputSource: Gamepad 1 inserted
SDLInputSource: Opened gamepad 1 (instance id 1, player id 0): Hps2 Virtual Gamepad
SDLInputSource: Gamepad 0 has 4 axes and 17 buttons
SDLInputSource: Rumble is supported on 'Hps2 Virtual Gamepad' via gamepad
```

**说明**：SDL 输入源已初始化、已能枚举并打开手柄（虚拟手柄走的正是这条路径）。
所以**按键 → PCSX2 Pad 的整条下游链路是通的**。

### 1.2 但 SDL 缺 evdev 后端

我们自己交叉编译的 SDL3 配置：

| 开关 | 状态 |
|---|---|
| `SDL_JOYSTICK_HIDAPI` | **1（启用）** |
| `SDL_JOYSTICK_LINUX` | **未定义**（无 evdev）|
| `SDL_JOYSTICK_VIRTUAL` | 1 |

**含义**：真实手柄只能走 **HIDAPI** 后端，它需要访问 `/dev/hidraw*`。

### 1.3 风险：HIDAPI 在 OHOS 上大概率不通

- shell 域实测：`/dev/hidraw*` **不存在**
- HIDAPI 通常还依赖 udev 做设备枚举，而 **OHOS 无 udev**
- Android 上 HIDAPI 需要 USB host 权限；OHOS 的权限模型未知

**结论**：不能假定 SDL HIDAPI 能发现蓝牙手柄。

---

## 2. 另一条路：OHOS 官方 GameControllerKit

### 2.1 API 能力（已核实头文件）

```
sysroot/usr/include/GameControllerKit/
  game_device.h        OH_GameDevice_RegisterDeviceMonitor()    ← 手柄插拔
                       OH_GameDevice_GetAllDeviceInfos()
  game_pad.h           OH_GamePad_<按键>_RegisterButtonInputMonitor()  ← 逐键注册
                       OH_GamePad_<轴>_RegisterAxisInputMonitor()
  game_device_event.h  回调与设备信息查询
库：libohgame_controller.z.so
syscap：SystemCapability.Game.GameController
```

### 2.2 优势

| 项 | 说明 |
|---|---|
| **无需权限声明** | 头文件中 **无** `@permission` 标注 |
| API 版本 | `@since 21`（设备为 API 26，满足）|
| 枚举与权限 | 由系统处理，不依赖 hidraw/udev |
| 设计意图 | OHOS 就是给游戏用手柄的 |

### 2.3 代价

需要一个**新的 `InputSource` 实现**（PCSX2 无现成实现），
把 OHOS 的按键回调翻译成 `InputBindingKey`。

---

## 3. 建议方案：先探测，再实现

### 3.1 探测（低成本，决定后续方向）

在 native 层加一个探针，回答三个问题：

1. `libohgame_controller.z.so` 能否**加载**（dlopen）？
2. `OH_GameDevice_GetAllDeviceInfos()` 能否调用、返回什么？
3. 设备上是否有可枚举的手柄（用户需先配对蓝牙手柄）？

**若三者皆通** → 走 OHOS 官方 API（路线 A）
**若不通** → 退回尝试 SDL HIDAPI（路线 B）

### 3.2 路线 A：OHOS GameControllerKit

```
OH_GameDevice_RegisterDeviceMonitor()   ← 检测插拔
  → 回调里拿到 deviceId
  → 注册各按键/轴的回调 OH_GamePad_*_RegisterButtonInputMonitor()
  → 回调触发时，构造 InputBindingKey 喂给 PCSX2
```

需要新写 `Hps2GamepadInputSource : public InputSource`。

### 3.3 路线 B：SDL HIDAPI

若 OHOS 官方 API 不可用，则尝试让 SDL 的 HIDAPI 后端发现设备。
前提是应用域能打开 `/dev/hidraw*` —— **需实测**。

---

## 4. 与虚拟手柄的关系

两者**不冲突**，应共存：

- 虚拟手柄：`SDL_JOYSTICK_VIRTUAL`，player id 0
- 真实手柄：走 OHOS API 或 SDL HIDAPI

PCSX2 的 Pad 支持多设备绑定，可同时把虚拟手柄与真实手柄映射到同一端口
（或分别映射到 1P/2P）。

---

## 5. 前端重做（用户同步提出）

**用户原话**：「现在这个样子的前端不可游玩」。

当前前端的问题（我自己也能看到）：

| 问题 | 说明 |
|---|---|
| 布局是「设置页 + 小画面」| 画面只占屏幕一小块（`408x158` vp），不适合游玩 |
| 设置项与游戏画面挤在一起 | 游玩时不该看到 BIOS/游戏选择按钮 |
| 虚拟按键覆盖在画面上 | 但画面本身太小，遮挡严重 |
| 无横屏 | PS2 是 4:3，应横屏全屏游玩 |

**重做方向**：
- **两种模式**：设置模式（选 BIOS/游戏）与 游玩模式（全屏画面 + 虚拟按键）
- 游玩时**横屏全屏**，虚拟按键半透明叠加
- 接入手柄后，虚拟按键可隐藏

## 6. 待用户确认

1. **蓝牙手柄的具体型号**？（不同手柄的按键映射可能不同）
2. **前端重做的优先级**：先做手柄还是先做前端？
3. 是否接受**横屏全屏**的游玩形态？
