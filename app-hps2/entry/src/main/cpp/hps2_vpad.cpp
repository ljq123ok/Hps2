/*
 * Hps2 — 虚拟手柄实现
 *
 * 见 hps2_vpad.h 的设计说明。
 */

#include "hps2_vpad.h"

#include <hilog/log.h>

#include <atomic>
#include <mutex>
#include <string>

#include <SDL3/SDL.h>

// PCSX2 侧：自动映射
#include "Input/InputManager.h"
#include "SIO/Pad/Pad.h"
#include "VMManager.h"
#include "Host.h"
#include "common/SettingsInterface.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3202
#define LOG_TAG "HPS2_VPAD"

#define VLOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define VLOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace Hps2VPad
{
	namespace
	{
		std::mutex s_mutex;
		SDL_JoystickID s_joystick_id = 0;
		// SDL_SetJoystickVirtual* 需要 SDL_Joystick* 句柄（不是 instance id）。
		// 由 SDL_OpenJoystick(instance_id) 取得 —— 见 SDL_joystick.h:613/668。
		SDL_Joystick* s_joystick = nullptr;
		std::atomic<bool> s_ready{false};
		std::atomic<bool> s_mapped{false};
		bool s_sdl_initialized = false;

		// 虚拟手柄的能力声明。取值需要与 SDLInputSource 的通用映射预期一致：
		// 它假定"所有按键都存在"，因此这里声明完整的一套 PS2 手柄可用输入。
		constexpr Uint16 kNumAxes = 4;    // LX, LY, RX, RY
		constexpr Uint16 kNumButtons = 17;
	}

	// 完成后由 Initialize 调用：等 SDL 把设备注册进 joystick 列表后，
	// 用上游的自动映射流程绑定到手柄端口。
	bool MapToPadPort(int port)
	{
		if (!s_ready.load())
		{
			VLOGE("MapToPadPort: virtual pad not ready");
			return false;
		}

		// 设备名格式为 "SDL-<player_id>"，注意是 **player index** 而非
		// SDL instance id —— 两者是不同的概念，很容易搞错（我最初就搞错了）。
		//
		// 依据：SDLInputSource::GetGenericBindingMapping 里
		//   （SDLInputSource.cpp:1696-1701）
		//     const std::optional<s32> player_id = FromChars<s32>(device.substr(4));
		//     GetControllerDataForPlayerId(player_id.value());
		// 它按 **player id** 查表，函数名也写明了 PlayerId。
		//
		// 实测对照（真机日志）：
		//   SDLInputSource: Opened gamepad 1 (instance id 1, player id 0)
		// 即 instance id=1 而 player id=0。
		// 我原先用 instance id 拼出 "SDL-1"，查不到 player id 0，映射因而失败：
		//   virtual pad mapping FAILED for port 0 (device=SDL-1)
		//
		// Player index 由 SDL 分配，需向 SDL 查询而不是自己推算。
		int player_index = SDL_GetJoystickPlayerIndex(s_joystick);
		if (player_index < 0)
		{
			// 未分配 player index 时，SDL3 的 JoinGamepad 也未把它们纳入
			// 球籍，无法映射。明确报出而不是静默用错值。
			VLOGE("MapToPadPort: SDL_GetJoystickPlayerIndex returned %{public}d "
			      "(instance id %{public}d) — cannot build a device name",
				player_index, static_cast<int>(s_joystick_id));
			return false;
		}

		const std::string device = "SDL-" + std::to_string(player_index);

		// 直接调用，只取 settings 锁 —— 与上游 SetupWizardDialog.cpp:567 的做法
		// 完全一致（那里也是 `auto lock = Host::GetSettingsLock();`
		// 然后直接 Pad::MapController）。
		//
		// 注意不要改用 Host::RunOnCPUThread 来"确保在 CPU 线程上"：
		// 我们的 Host 实现继承自 eerunner 的无头版本，该函数是
		// pxFailRel("Not implemented")（hps2_host.cpp:305）—— 调用它会直接
		// 触发断言失败。而且上游证明映射并不需要 CPU 线程。
		// ------------------------------------------------------------------
		// 前置条件检查：输入源必须已创建。
		//
		// 为什么必须查：输入源是**懒创建**的 —— 只有
		// InputManager::ReloadSources() 跑过之后
		// s_input_sources[] 才会被填充（InputManager.cpp:1902 自己就写着
		// `if (!s_input_sources[type])` 才创建）。
		//
		// ReloadSources() 由 VMManager::LoadSettings() 调用
		// （VMManager.cpp:704），而后者在 **CPU 线程**的
		// CPUThreadInitialize 内部执行。
		//
		// 因此若在 startBios() 一返回就调用本函数，输入源尚为空，
		// InputManager::GetGenericBindingMapping() 会在
		//   s_input_sources[i]->IsInitialized()
        // （InputManager.cpp:1885，**没有 null 检查**）
		// 处解引用空指针 → SIGSEGV → 应用闪退。这是实测到的崩溃。
		//
		// 正确时机：VM 线程完成 VMManager::Initialize() 之后
		// （见 napi_init.cpp 的 VMThreadMain）。
		// ------------------------------------------------------------------
		// 用 GetInputSourceInterface() 判空 —— 它返回 s_input_sources[].get()，
		// 未创建时为 nullptr（InputManager.cpp:718-721）。这是可靠的就绪判据，
		// 不是我们自造的接口。
		if (InputManager::GetInputSourceInterface(InputSourceType::SDL) == nullptr)
		{
			VLOGE("MapToPadPort: the SDL input source does not exist yet; refusing to "
			      "call GetGenericBindingMapping, which dereferences s_input_sources[] "
			      "without a null check (InputManager.cpp:1885) and would crash");
			return false;
		}

		bool result = false;
		{
			auto lock = Host::GetSettingsLock();
			SettingsInterface* si = Host::Internal::GetBaseSettingsLayer();
			if (!si)
			{
				VLOGE("MapToPadPort: no base settings layer");
				return false;
			}
			result = Pad::MapController(*si, static_cast<u32>(port),
				InputManager::GetGenericBindingMapping(device));
		}

		// 与上游一致：映射后提交设置。
		// 我们的 Host::CommitBaseSettingChanges 是空实现（settings 全在内存中，
		// 无文件可落盘），调用它是为了与上游流程保持同构，便于将来接入持久化。
		if (result)
			Host::CommitBaseSettingChanges();

		if (result)
			VLOGI("virtual pad mapped to port %{public}d (device=%{public}s)", port, device.c_str());
		else
			VLOGE("virtual pad mapping FAILED for port %{public}d (device=%{public}s) — "
			      "is the SDL input source enabled and the device enumerated?",
				port, device.c_str());

		return result;
	}

	bool Initialize()
	{
		std::lock_guard<std::mutex> lock(s_mutex);
		if (s_ready.load())
		{
			VLOGI("virtual pad already initialized");
			return true;
		}

		// SDL 的事件/手柄子系统。SDLInputSource 也会初始化它们；
		// SDL_InitSubSystem 是引用计数的，重复调用安全。
		if (!SDL_InitSubSystem(SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD | SDL_INIT_EVENTS))
		{
			VLOGE("SDL_InitSubSystem failed: %{public}s", SDL_GetError());
			return false;
		}
		s_sdl_initialized = true;

		// version 字段不是版本号，而是**结构体大小** —— 这是 SDL 的接口
		// 版本检查惯用法（SDL_INIT_INTERFACE 宏，见 SDL_stdinc.h:1342）。
		// 后端会校验 `desc->version < sizeof(*desc)` 并拒绝非法值
		// （SDL_virtualjoystick.c:145）。手写常量会踩坑，直接用官方宏。
		SDL_VirtualJoystickDesc desc;
		SDL_INIT_INTERFACE(&desc);
		desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
		desc.vendor_id = 0x1209;   // 任意值，仅用于标识
		desc.product_id = 0x0001;
		desc.naxes = kNumAxes;
		desc.nbuttons = kNumButtons;
		desc.name = "Hps2 Virtual Gamepad";

		// 声明全部轴与按键有效，与 SDLInputSource 的"假定全部存在"一致。
		desc.axis_mask = (1u << SDL_GAMEPAD_AXIS_LEFTX) | (1u << SDL_GAMEPAD_AXIS_LEFTY) |
		                 (1u << SDL_GAMEPAD_AXIS_RIGHTX) | (1u << SDL_GAMEPAD_AXIS_RIGHTY);
		desc.button_mask = 0xFFFFFFFFu;

		s_joystick_id = SDL_AttachVirtualJoystick(&desc);
		if (s_joystick_id == 0)
		{
			VLOGE("SDL_AttachVirtualJoystick failed: %{public}s", SDL_GetError());
			return false;
		}

		// 打开句柄：后续 SDL_SetJoystickVirtual* 需要它
		s_joystick = SDL_OpenJoystick(s_joystick_id);
		if (!s_joystick)
		{
			VLOGE("SDL_OpenJoystick(%{public}d) failed: %{public}s",
				static_cast<int>(s_joystick_id), SDL_GetError());
			SDL_DetachVirtualJoystick(s_joystick_id);
			s_joystick_id = 0;
			return false;
		}

		s_ready.store(true);
		VLOGI("virtual gamepad attached: id=%{public}d axes=%{public}u buttons=%{public}u",
			static_cast<int>(s_joystick_id), kNumAxes, kNumButtons);

		// 设备刚挂上时，SDL 需要处理一次事件队列才会把它放进 device 列表。
		SDL_PumpEvents();
		SDL_UpdateJoysticks();

		return true;
	}

	bool IsReady()
	{
		return s_ready.load();
	}

	void Shutdown()
	{
		std::lock_guard<std::mutex> lock(s_mutex);
		if (s_joystick)
		{
			SDL_CloseJoystick(s_joystick);
			s_joystick = nullptr;
		}
		if (s_ready.load() && s_joystick_id != 0)
		{
			SDL_DetachVirtualJoystick(s_joystick_id);
			s_joystick_id = 0;
		}
		s_ready.store(false);
		if (s_sdl_initialized)
		{
			SDL_QuitSubSystem(SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD | SDL_INIT_EVENTS);
			s_sdl_initialized = false;
		}
		VLOGI("virtual gamepad shut down");
	}

	void SetButton(int button, bool pressed)
	{
		if (!s_ready.load() || !s_joystick)
			return;
		SDL_SetJoystickVirtualButton(s_joystick, button, pressed);
		SDL_UpdateJoysticks();
	}

	void SetAxis(int axis, int value)
	{
		if (!s_ready.load() || !s_joystick)
			return;
		SDL_SetJoystickVirtualAxis(s_joystick, axis, static_cast<Sint16>(value));
		SDL_UpdateJoysticks();
	}
}
