# 阶段 4 输入接入方案

**问题**（用户反馈）：游戏可正常运行，但**前端无法操作** ——
没有虚拟按键，也未接入蓝牙手柄，无法进行游玩测试。

---

## 1. 已确认的现状（实测）

### 1.1 PCSX2 侧已有完整输入框架

```
pcsx2/Input/
  InputManager.cpp        输入源管理与绑定
  InputSource.h/.cpp      输入源基类
  SDLInputSource.cpp/.h   ← SDL 输入源（已存在）
  DInputSource / XInputSource  Windows 专用
```

`InputManager.cpp:1942` 已有：
```cpp
UpdateInputSourceState<SDLInputSource>(si, settings_lock, InputSourceType::SDL);
```

**即：SDL 输入源已接入核心，无需新写输入抽象。**

### 1.2 SDL3 已成功交叉编译（阶段 2 成果）

但我们当前的 SDL3 构建中：

| 开关 | 状态 | 含义 |
|---|---|---|
| `SDL_JOYSTICK_HIDAPI` | **1（启用）** | HIDAPI 后端可用（USB/蓝牙手柄）|
| `SDL_JOYSTICK_LINUX` | **未定义** | **无 evdev 后端** |
| `SDL_JOYSTICK_MFI` | 未定义 | 无 Apple 手柄后端 |
| `SDL_JOYSTICK_VIRTUAL` | 1 | 虚拟手柄（可用于自绘虚拟按键！）|
| `SDL_VIDEO_DRIVER_DUMMY` | 1 | 视频为 dummy（不需要 SDL 显示）|

`linux/hidraw.h` 在 sysroot 中存在。

### 1.3 OHOS 有官方手柄支持（另一条路）

```
sysroot/usr/include/GameControllerKit/
  game_controller_type.h
  game_device.h
  game_device_event.h
  game_pad.h
  game_pad_event.h
sysroot/usr/lib/aarch64-linux-ohos/libohgame_controller.z.so
```

## 2. 两条可选路径

### 路径 A：SDL3 输入（复用核心已有的 SDLInputSource）

**优点**
- 核心侧零改动（`SDLInputSource` 已接入）
- 一套代码将来在 Vulkan/多平台复用
- `SDL_JOYSTICK_VIRTUAL` 正好可用于自绘虚拟按键 —— 把屏幕触控映射为
  虚拟手柄，喂给 SDL

**风险**
- `SDL_JOYSTICK_LINUX`（evdev）未启用，**只能用 HIDAPI 后端**
- HIDAPI 在 OHOS 上能否打开设备未知：需 `/dev/hidraw*` 可访问
  （Android 上 HIDAPI 通常需要 USB host 权限；OHOS 的权限模型待验证）
- SDL 的 HIDAPI 后端在非 Android/iOS 平台通常还依赖 udev 做设备枚举，
  OHOS 无 udev

### 路径 B：OHOS GameControllerKit（官方 API）

**优点**
- 官方支持，权限/枚举由系统处理
- OHOS 设计上就是给游戏用手柄的

**风险**
- 需要写一个新的 `InputSource` 实现（PCSX2 无现成实现）
- API 细节需逐个核实（`game_pad.h` / `game_device_event.h`）
- ArkTS 与 native 的边界需确认（部分 OHOS 游戏 API 可能需要 ArkTS 侧配合）

## 3. 虚拟按键（无论哪条路都需要）

用户明确提到"没有虚拟按键"。这部分**必须在 ArkTS 侧实现**：

- 用 ArkUI 在游戏画面上叠加虚拟摇杆/按钮
- 触控/按键事件需送进 native 输入层

**关键设计选择**：虚拟按键应表达为 **SDL 虚拟手柄**（`SDL_JOYSTICK_VIRTUAL`）
还是直接注入 PCSX2 的 `InputSource`？

- 走 SDL 虚拟手柄：核心侧零改动，且与真实手柄走同一条路径
- 直接注入 InputSource：少一层，但要新增一个 InputSource 实现

## 4. 建议顺序

1. **先做虚拟按键**（不依赖蓝牙、不依赖 OHOS 手柄 API、可立即验证游玩）
   —— 用 ArkTS 实现 UI，触控事件经 N-API 送入 native
2. **再做蓝牙手柄** —— 先试 SDL HIDAPI（零核心改动），
   不行则走 OHOS GameControllerKit（需新写 InputSource）

**理由**：虚拟按键能立刻解决"无法游玩"的阻塞，且不依赖任何未验证的平台能力。

## 5. 待确认事项（不猜测）

- [ ] OHOS 上 `/dev/hidraw*` 与 `/dev/input/*` 对普通应用是否可读
- [ ] SDL HIDAPI 后端在无 udev 的 OHOS 上能否枚举设备
- [ ] `libohgame_controller.z.so` 的 API 是否可从 native 直接调用
      （还是需要 ArkTS 侧配合）
- [ ] PCSX2 的绑定配置如何持久化（当前 settings 全在内存中）
