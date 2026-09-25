/*
 * Hps2 — 虚拟手柄实现。
 *
 * 触摸按键直接写入 PCSX2 的 DualShock 2 状态，避免 SDL 虚拟设备、
 * SDL 事件队列和启动期自动映射带来的丢事件与线程竞态。
 * 蓝牙/实体手柄仍然使用 SDLInputSource 和单独的映射流程。
 */

#include "hps2_vpad.h"
#include "hps2_gamepad.h"

#include <hilog/log.h>

#include <algorithm>
#include <atomic>
#include <mutex>
#include <string>

#include <SDL3/SDL.h>

#include "Input/InputManager.h"
#include "Input/InputSource.h"
#include "SIO/Pad/Pad.h"
#include "SIO/Pad/PadDualshock2.h"
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
		std::atomic<bool> s_ready{false};

		float NormalizeAxis(int value)
		{
			value = std::clamp(value, -32768, 32767);
			return value < 0 ? static_cast<float>(value) / 32768.0f
							: static_cast<float>(value) / 32767.0f;
		}

		void SetHalfAxis(PadDualshock2::Inputs negative, PadDualshock2::Inputs positive, float value)
		{
			Pad::SetControllerState(0, negative, std::max(0.0f, -value));
			Pad::SetControllerState(0, positive, std::max(0.0f, value));
		}

		int ButtonToPadInput(int button)
		{
			switch (button)
			{
				case SDL_GAMEPAD_BUTTON_SOUTH: return PadDualshock2::PAD_CROSS;
				case SDL_GAMEPAD_BUTTON_EAST: return PadDualshock2::PAD_CIRCLE;
				case SDL_GAMEPAD_BUTTON_WEST: return PadDualshock2::PAD_SQUARE;
				case SDL_GAMEPAD_BUTTON_NORTH: return PadDualshock2::PAD_TRIANGLE;
				case SDL_GAMEPAD_BUTTON_BACK: return PadDualshock2::PAD_SELECT;
				case SDL_GAMEPAD_BUTTON_START: return PadDualshock2::PAD_START;
				case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return PadDualshock2::PAD_L1;
				case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return PadDualshock2::PAD_R1;
				case SDL_GAMEPAD_BUTTON_LEFT_STICK: return PadDualshock2::PAD_L3;
				case SDL_GAMEPAD_BUTTON_RIGHT_STICK: return PadDualshock2::PAD_R3;
				case SDL_GAMEPAD_BUTTON_DPAD_UP: return PadDualshock2::PAD_UP;
				case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return PadDualshock2::PAD_DOWN;
				case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return PadDualshock2::PAD_LEFT;
				case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return PadDualshock2::PAD_RIGHT;
				default: return -1;
			}
		}
	}

	bool MapToPadPort(int port)
	{
		if (!s_ready.load() || port < 0)
		{
			VLOGE("MapToPadPort: virtual pad not ready");
			return false;
		}

		// 触摸虚拟手柄不再创建 SDL 设备，也不需要 ReloadInputBindings。
		// 这条路径直接更新 DualShock 2 的绑定状态，避免启动阶段调用
		// InputManager::GetGenericBindingMapping() 和重载输入绑定。
		VLOGI("virtual pad direct binding ready for port %{public}d", port);
		return true;
	}

	bool MapControllerToPadPort(const std::string& device, int port)
	{
		if (device.empty() || port < 0)
			return false;
		if (Hps2Gamepad::IsOfficialDeviceId(device))
			return Hps2Gamepad::SelectDevice(device, port);

		InputSource* source = InputManager::GetInputSourceInterface(InputSourceType::SDL);
		if (source == nullptr || !source->IsInitialized())
		{
			VLOGE("MapControllerToPadPort: SDL input source is not ready");
			return false;
		}

		const InputManager::GenericInputBindingMapping mapping =
			InputManager::GetGenericBindingMapping(device);
		if (mapping.empty())
		{
			VLOGE("MapControllerToPadPort: no generic mapping for device %{public}s", device.c_str());
			return false;
		}

		bool result = false;
		{
			auto lock = Host::GetSettingsLock();
			SettingsInterface* si = Host::Internal::GetBaseSettingsLayer();
			if (si == nullptr)
			{
				VLOGE("MapControllerToPadPort: no base settings layer");
				return false;
			}
			result = Pad::MapController(*si, static_cast<u32>(port), mapping);
		}

		if (result)
		{
			Host::CommitBaseSettingChanges();
			VMManager::ReloadInputBindings(true);
			VLOGI("real controller mapped to port %{public}d (device=%{public}s)",
				port, device.c_str());
		}
		else
		{
			VLOGE("real controller mapping failed for port %{public}d (device=%{public}s)",
				port, device.c_str());
		}

		return result;
	}

	std::string EnumerateControllersJson()
	{
		InputSource* source = InputManager::GetInputSourceInterface(InputSourceType::SDL);

		auto escape = [](const std::string& value) {
			std::string out;
			for (const char c : value)
			{
				if (c == '"' || c == '\\')
					out += '\\';
				if (c == '\n' || c == '\r')
				{
					out += ' ';
					continue;
				}
				out += c;
			}
			return out;
		};

		std::vector<std::pair<std::string, std::string>> devices = Hps2Gamepad::EnumerateDevices();
		if (source != nullptr && source->IsInitialized())
		{
			const auto sdl_devices = source->EnumerateDevices();
			devices.insert(devices.end(), sdl_devices.begin(), sdl_devices.end());
		}
		std::string json = "[";
		bool first = true;
		for (const auto& [identifier, name] : devices)
		{
			if (identifier.rfind("SDL-", 0) != 0 && !Hps2Gamepad::IsOfficialDeviceId(identifier))
				continue;
			if (!first)
				json += ',';
			first = false;
			json += "{\"id\":\"" + escape(identifier) + "\",\"name\":\"" + escape(name) + "\"}";
		}
		json += "]";
		return json;
	}

	bool Initialize()
	{
		std::lock_guard<std::mutex> lock(s_mutex);
		if (s_ready.load())
		{
			VLOGI("virtual pad already initialized");
			return true;
		}

		s_ready.store(true);
		VLOGI("virtual pad direct input initialized");
		const bool official_gamepad = Hps2Gamepad::Initialize();
		VLOGI("official gamepad input initialized=%{public}d", official_gamepad ? 1 : 0);
		return true;
	}

	bool IsReady()
	{
		return s_ready.load();
	}

	void Shutdown()
	{
		std::lock_guard<std::mutex> lock(s_mutex);
		s_ready.store(false);
		VLOGI("virtual pad direct input shut down");
	}

	void SetButton(int button, bool pressed)
	{
		if (!s_ready.load())
			return;

		const int input = ButtonToPadInput(button);
		if (input < 0)
		{
			VLOGE("SetButton ignored: unsupported SDL button=%{public}d", button);
			return;
		}

		Pad::SetControllerState(0, static_cast<u32>(input), pressed ? 1.0f : 0.0f);
	}

	void SetAxis(int axis, int value)
	{
		if (!s_ready.load())
			return;

		const float normalized = NormalizeAxis(value);
		switch (axis)
		{
			case SDL_GAMEPAD_AXIS_LEFTX:
				SetHalfAxis(PadDualshock2::PAD_L_LEFT, PadDualshock2::PAD_L_RIGHT, normalized);
				break;
			case SDL_GAMEPAD_AXIS_LEFTY:
				SetHalfAxis(PadDualshock2::PAD_L_UP, PadDualshock2::PAD_L_DOWN, normalized);
				break;
			case SDL_GAMEPAD_AXIS_RIGHTX:
				SetHalfAxis(PadDualshock2::PAD_R_LEFT, PadDualshock2::PAD_R_RIGHT, normalized);
				break;
			case SDL_GAMEPAD_AXIS_RIGHTY:
				SetHalfAxis(PadDualshock2::PAD_R_UP, PadDualshock2::PAD_R_DOWN, normalized);
				break;
			case SDL_GAMEPAD_AXIS_LEFT_TRIGGER:
				Pad::SetControllerState(0, PadDualshock2::PAD_L2,
					std::clamp((normalized + 1.0f) * 0.5f, 0.0f, 1.0f));
				break;
			case SDL_GAMEPAD_AXIS_RIGHT_TRIGGER:
				Pad::SetControllerState(0, PadDualshock2::PAD_R2,
					std::clamp((normalized + 1.0f) * 0.5f, 0.0f, 1.0f));
				break;
			default:
				VLOGE("SetAxis ignored: unsupported SDL axis=%{public}d", axis);
				break;
		}
	}
}
