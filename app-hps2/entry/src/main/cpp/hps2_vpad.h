/*
 * Hps2 — 虚拟手柄（屏幕虚拟按键）
 *
 * 目标：让手机上无需实体手柄即可游玩。
 *
 * 设计：把 ArkUI 上绘制的虚拟按键表达为 **SDL 虚拟手柄**
 * （SDL_AttachVirtualJoystick），而不是自己实现一套 InputSource。
 *
 * 为什么选这条路径：
 *   1. PCSX2 已有完整的 SDLInputSource 并已接入
 *      （InputManager.cpp:1942），虚拟手柄会通过标准的
 *      SDL_EVENT_JOYSTICK_ADDED 被它发现 —— 核心侧零改动。
 *   2. 虚拟手柄与真实手柄走完全相同的代码路径，
 *      将来接蓝牙手柄时行为一致，不会出现"虚拟按键能用但手柄不能用"的分叉。
 *   3. 上游 FullscreenUI 已有"自动映射"的现成用法可照抄
 *      （FullscreenUI_Settings.cpp:1581）：
 *        Pad::MapController(*si, port, InputManager::GetGenericBindingMapping(name));
 *
 * 数据流：
 *   ArkUI 触控 → N-API → SetButton()/SetAxis() → SDL_SetJoystickVirtual*
 *              → SDL 事件队列 → SDLInputSource → PCSX2 Pad
 */
#pragma once

namespace Hps2VPad
{
	/// 创建并挂载虚拟手柄，并为手柄端口 0 做自动按键映射。
	/// 返回 true 表示虚拟手柄已就绪（可开始接收 SetButton/SetAxis）。
	bool Initialize();

	/// 是否已就绪。
	bool IsReady();

	/// 关闭虚拟手柄。
	void Shutdown();

	/// 设置按键状态。button 使用 SDL_GAMEPAD_BUTTON_* 编号。
	void SetButton(int button, bool pressed);

	/// 设置轴。axis 使用 SDL_GAMEPAD_AXIS_*；value 范围 -32768..32767。
	void SetAxis(int axis, int value);

	/// 为手柄端口做自动映射（需要虚拟手柄已挂载且被 SDL 识别）。
	/// 由 Initialize() 内部调用，也可手动重试。
	bool MapToPadPort(int port);
}
