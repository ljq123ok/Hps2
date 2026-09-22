# 外接手柄功能现状（2026-09-22）

**结论：外接手柄功能 ❌ 尚未实现。**

已实现的是**屏幕虚拟按键**（把触屏上的虚拟按键表达为 SDL 虚拟手柄）。
两者是不同的事，不能混为一谈。

---

## 1. 已完成：屏幕虚拟按键

```
ArkUI 虚拟按键
  → N-API (vpadButton/vpadAxis)
  → SDL_SetJoystickVirtualButton/Axis
  → SDL 事件队列
  → SDLInputSource
  → PCSX2 Pad
```

走的是 **`SDL_JOYSTICK_VIRTUAL`**（SDL 的"虚拟手柄"设施）——
它让应用**凭空造出一个手柄**，而不是去发现真实硬件。

**这条链路已接通并通过真机验证**（JIT 可用时游戏可操作）。

## 2. 未实现：外接（蓝牙/USB）手柄

外接手柄需要**发现真实硬件**，这与虚拟手柄是两条不同的路径。

### 2.1 当前 SDL 构建的实际配置

从 `SDL_build_config.h`（我们自编译的 SDL3）读到：

| 开关 | 状态 | 含义 |
|---|---|---|
| `SDL_JOYSTICK_VIRTUAL` | **1** | 虚拟手柄 —— 已用 |
| `SDL_JOYSTICK_HIDAPI` | **1** | HIDAPI 后端 |
| `SDL_JOYSTICK_LINUX` | **未定义** | **无 evdev 后端** |
| `SDL_JOYSTICK_ANDROID` 等 | 未定义 | 其它平台后端均无 |

### 2.2 为什么 HIDAPI 这条路大概率走不通

真实手柄只能靠 `SDL_JOYSTICK_HIDAPI`。但：

- 真机实测 **`/dev/hidraw*` 不存在**（shell 域确认）
- HIDAPI 通常需要 **udev** 做设备枚举，而 **OHOS 没有 udev**
- Android 上 HIDAPI 需 USB host 权限；OHOS 的权限模型未验证

**即：即使插上手柄，SDL 也可能完全发现不了它。**
（这是基于配置与设备事实的判断，**未在真机用手柄实测过**。）

### 2.3 另一条路：OHOS 官方 GameControllerKit（未接入）

OHOS 有官方手柄 API，这是**更可靠**的路径：

```
sysroot/usr/include/GameControllerKit/
  game_device.h     OH_GameDevice_RegisterDeviceMonitor()   ← 手柄插拔检测
  game_pad.h        OH_GamePad_<按键>_RegisterButtonInputMonitor()
  game_device_event.h
库：libohgame_controller.z.so
syscap：SystemCapability.Game.GameController
@since 21（设备 API 26，满足）
无需权限声明（头文件中无 @permission）
```

**代价**：需要一个**新的 `InputSource` 实现**，把 OHOS 的按键回调
翻译成 `InputBindingKey` 喂给 PCSX2 —— PCSX2 没有现成实现。

**当前代码中该 API 的引用数为 0**（已 grep 确认），
即**完全未接入**。

---

## 3. 待办：实现外接手柄

### 3.1 建议顺序

1. **先做低成本探测**（在 native 层）：
   - `dlopen("libohgame_controller.z.so")` 能否成功？
   - `OH_GameDevice_GetAllDeviceInfos()` 能否调用、返回什么？
   - 设备上是否有可枚举的手柄？
2. 若探测通过 → 实现 `Hps2GamepadInputSource : public InputSource`
3. 若不通 → 退回尝试 SDL HIDAPI（需实测 `/dev/hidraw*` 可访问性）

### 3.2 与虚拟按键的关系

两者**不冲突**，应共存：
- 虚拟按键：`SDL_JOYSTICK_VIRTUAL`，player id 0
- 真实手柄：OHOS API 或 SDL HIDAPI

PCSX2 的 Pad 支持多设备绑定，可同时把两者映射到同一端口（或分到 1P/2P）。
接入手柄后，UI 上的虚拟按键可自动隐藏（`showPad` 开关已具备）。
