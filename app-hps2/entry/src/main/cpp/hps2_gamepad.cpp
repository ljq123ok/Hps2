/*
 * Hps2 — native HarmonyOS gamepad input.
 *
 * The system MultimodalInput service already classifies supported Bluetooth
 * pads as game controllers.  SDL on OHOS cannot see those devices because this
 * build has no evdev backend, and ArkUI focus events are not delivered for all
 * controller modes.  GameControllerKit is the platform-owned input path.
 */

#include "hps2_gamepad.h"

#include "hps2_vpad.h"

#include <GameControllerKit/game_device.h>
#include <GameControllerKit/game_pad.h>

#include <SDL3/SDL_gamepad.h>
#include <dlfcn.h>
#include <hilog/log.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <mutex>
#include <string>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3202
#define LOG_TAG "HPS2_PAD"

#define GPLOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define GPLOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace Hps2Gamepad
{
	namespace
	{
		constexpr const char* DEVICE_PREFIX = "OHOS-";

		struct Api
		{
			void* library = nullptr;

			decltype(&OH_GameDevice_GetAllDeviceInfos) get_all_devices = nullptr;
			decltype(&OH_GameDevice_AllDeviceInfos_GetCount) get_device_count = nullptr;
			decltype(&OH_GameDevice_AllDeviceInfos_GetDeviceInfo) get_device_info = nullptr;
			decltype(&OH_GameDevice_DestroyAllDeviceInfos) destroy_all_devices = nullptr;
			decltype(&OH_GameDevice_DestroyDeviceInfo) destroy_device_info = nullptr;
			decltype(&OH_GameDevice_DeviceInfo_GetDeviceId) get_device_id = nullptr;
			decltype(&OH_GameDevice_DeviceInfo_GetName) get_device_name = nullptr;
			decltype(&OH_GameDevice_DeviceInfo_GetDeviceType) get_device_type = nullptr;

			decltype(&OH_GamePad_ButtonEvent_GetButtonAction) get_button_action = nullptr;
			decltype(&OH_GamePad_ButtonEvent_GetButtonCode) get_button_code = nullptr;
			decltype(&OH_GamePad_ButtonEvent_GetDeviceId) get_button_device_id = nullptr;
			decltype(&OH_GamePad_AxisEvent_GetDeviceId) get_axis_device_id = nullptr;
			decltype(&OH_GamePad_AxisEvent_GetAxisSourceType) get_axis_source = nullptr;
			decltype(&OH_GamePad_AxisEvent_GetXAxisValue) get_axis_x = nullptr;
			decltype(&OH_GamePad_AxisEvent_GetYAxisValue) get_axis_y = nullptr;
			decltype(&OH_GamePad_AxisEvent_GetZAxisValue) get_axis_z = nullptr;
			decltype(&OH_GamePad_AxisEvent_GetRZAxisValue) get_axis_rz = nullptr;
			decltype(&OH_GamePad_AxisEvent_GetBrakeAxisValue) get_axis_brake = nullptr;
			decltype(&OH_GamePad_AxisEvent_GetGasAxisValue) get_axis_gas = nullptr;

			decltype(&OH_GamePad_ButtonA_RegisterButtonInputMonitor) register_a = nullptr;
			decltype(&OH_GamePad_ButtonB_RegisterButtonInputMonitor) register_b = nullptr;
			decltype(&OH_GamePad_ButtonX_RegisterButtonInputMonitor) register_x = nullptr;
			decltype(&OH_GamePad_ButtonY_RegisterButtonInputMonitor) register_y = nullptr;
			decltype(&OH_GamePad_ButtonMenu_RegisterButtonInputMonitor) register_menu = nullptr;
			decltype(&OH_GamePad_ButtonHome_RegisterButtonInputMonitor) register_home = nullptr;
			decltype(&OH_GamePad_LeftShoulder_RegisterButtonInputMonitor) register_l1 = nullptr;
			decltype(&OH_GamePad_RightShoulder_RegisterButtonInputMonitor) register_r1 = nullptr;
			decltype(&OH_GamePad_LeftTrigger_RegisterButtonInputMonitor) register_l2_button = nullptr;
			decltype(&OH_GamePad_RightTrigger_RegisterButtonInputMonitor) register_r2_button = nullptr;
			decltype(&OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor) register_dpad_up = nullptr;
			decltype(&OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor) register_dpad_down = nullptr;
			decltype(&OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor) register_dpad_left = nullptr;
			decltype(&OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor) register_dpad_right = nullptr;
			decltype(&OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor) register_l3 = nullptr;
			decltype(&OH_GamePad_RightThumbstick_RegisterButtonInputMonitor) register_r3 = nullptr;
			decltype(&OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor) register_left_stick = nullptr;
			decltype(&OH_GamePad_RightThumbstick_RegisterAxisInputMonitor) register_right_stick = nullptr;
			decltype(&OH_GamePad_LeftTrigger_RegisterAxisInputMonitor) register_l2_axis = nullptr;
			decltype(&OH_GamePad_RightTrigger_RegisterAxisInputMonitor) register_r2_axis = nullptr;
		};

		Api s_api;
		std::mutex s_mutex;
		bool s_load_attempted = false;
		bool s_monitors_registered = false;
		std::string s_selected_device;

		template <typename T>
		bool LoadSymbol(T& target, const char* name)
		{
			target = reinterpret_cast<T>(dlsym(s_api.library, name));
			if (target == nullptr)
				GPLOGE("GameControllerKit missing symbol %{public}s", name);
			return target != nullptr;
		}

		bool LoadApiLocked()
		{
			if (s_load_attempted)
				return s_api.library != nullptr;
			s_load_attempted = true;

			s_api.library = dlopen("libohgame_controller.z.so", RTLD_NOW | RTLD_LOCAL);
			if (s_api.library == nullptr)
			{
				GPLOGI("GameControllerKit unavailable (API < 21 or missing syscap)");
				return false;
			}

			bool ok = true;
#define LOAD(member, symbol) ok = LoadSymbol(s_api.member, #symbol) && ok
			LOAD(get_all_devices, OH_GameDevice_GetAllDeviceInfos);
			LOAD(get_device_count, OH_GameDevice_AllDeviceInfos_GetCount);
			LOAD(get_device_info, OH_GameDevice_AllDeviceInfos_GetDeviceInfo);
			LOAD(destroy_all_devices, OH_GameDevice_DestroyAllDeviceInfos);
			LOAD(destroy_device_info, OH_GameDevice_DestroyDeviceInfo);
			LOAD(get_device_id, OH_GameDevice_DeviceInfo_GetDeviceId);
			LOAD(get_device_name, OH_GameDevice_DeviceInfo_GetName);
			LOAD(get_device_type, OH_GameDevice_DeviceInfo_GetDeviceType);
			LOAD(get_button_action, OH_GamePad_ButtonEvent_GetButtonAction);
			LOAD(get_button_code, OH_GamePad_ButtonEvent_GetButtonCode);
			LOAD(get_button_device_id, OH_GamePad_ButtonEvent_GetDeviceId);
			LOAD(get_axis_device_id, OH_GamePad_AxisEvent_GetDeviceId);
			LOAD(get_axis_source, OH_GamePad_AxisEvent_GetAxisSourceType);
			LOAD(get_axis_x, OH_GamePad_AxisEvent_GetXAxisValue);
			LOAD(get_axis_y, OH_GamePad_AxisEvent_GetYAxisValue);
			LOAD(get_axis_z, OH_GamePad_AxisEvent_GetZAxisValue);
			LOAD(get_axis_rz, OH_GamePad_AxisEvent_GetRZAxisValue);
			LOAD(get_axis_brake, OH_GamePad_AxisEvent_GetBrakeAxisValue);
			LOAD(get_axis_gas, OH_GamePad_AxisEvent_GetGasAxisValue);
			LOAD(register_a, OH_GamePad_ButtonA_RegisterButtonInputMonitor);
			LOAD(register_b, OH_GamePad_ButtonB_RegisterButtonInputMonitor);
			LOAD(register_x, OH_GamePad_ButtonX_RegisterButtonInputMonitor);
			LOAD(register_y, OH_GamePad_ButtonY_RegisterButtonInputMonitor);
			LOAD(register_menu, OH_GamePad_ButtonMenu_RegisterButtonInputMonitor);
			LOAD(register_home, OH_GamePad_ButtonHome_RegisterButtonInputMonitor);
			LOAD(register_l1, OH_GamePad_LeftShoulder_RegisterButtonInputMonitor);
			LOAD(register_r1, OH_GamePad_RightShoulder_RegisterButtonInputMonitor);
			LOAD(register_l2_button, OH_GamePad_LeftTrigger_RegisterButtonInputMonitor);
			LOAD(register_r2_button, OH_GamePad_RightTrigger_RegisterButtonInputMonitor);
			LOAD(register_dpad_up, OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor);
			LOAD(register_dpad_down, OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor);
			LOAD(register_dpad_left, OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor);
			LOAD(register_dpad_right, OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor);
			LOAD(register_l3, OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor);
			LOAD(register_r3, OH_GamePad_RightThumbstick_RegisterButtonInputMonitor);
			LOAD(register_left_stick, OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor);
			LOAD(register_right_stick, OH_GamePad_RightThumbstick_RegisterAxisInputMonitor);
			LOAD(register_l2_axis, OH_GamePad_LeftTrigger_RegisterAxisInputMonitor);
			LOAD(register_r2_axis, OH_GamePad_RightTrigger_RegisterAxisInputMonitor);
#undef LOAD

			if (!ok)
			{
				dlclose(s_api.library);
				s_api = {};
				return false;
			}
			return true;
		}

		std::string ReadEventDeviceId(const GamePad_ButtonEvent* event)
		{
			char* raw = nullptr;
			if (s_api.get_button_device_id(event, &raw) != GAME_CONTROLLER_SUCCESS || raw == nullptr)
				return {};
			std::string result(raw);
			std::free(raw);
			return result;
		}

		std::string ReadEventDeviceId(const GamePad_AxisEvent* event)
		{
			char* raw = nullptr;
			if (s_api.get_axis_device_id(event, &raw) != GAME_CONTROLLER_SUCCESS || raw == nullptr)
				return {};
			std::string result(raw);
			std::free(raw);
			return result;
		}

		bool AcceptDevice(const std::string& device_id)
		{
			std::lock_guard<std::mutex> lock(s_mutex);
			return s_selected_device.empty() || device_id.empty() || s_selected_device == device_id;
		}

		void DispatchButton(const GamePad_ButtonEvent* event, int sdl_button)
		{
			if (event == nullptr || !AcceptDevice(ReadEventDeviceId(event)))
				return;

			GamePad_Button_ActionType action = UP;
			int32_t raw_code = -1;
			if (s_api.get_button_action(event, &action) != GAME_CONTROLLER_SUCCESS)
				return;
			s_api.get_button_code(event, &raw_code);
			GPLOGI("official button code=%{public}d action=%{public}d mapped=%{public}d",
				raw_code, static_cast<int>(action), sdl_button);
			Hps2VPad::SetButton(sdl_button, action == DOWN);
		}

		void DispatchTriggerButton(const GamePad_ButtonEvent* event, int sdl_axis)
		{
			if (event == nullptr || !AcceptDevice(ReadEventDeviceId(event)))
				return;
			GamePad_Button_ActionType action = UP;
			if (s_api.get_button_action(event, &action) != GAME_CONTROLLER_SUCCESS)
				return;
			Hps2VPad::SetAxis(sdl_axis, action == DOWN ? 32767 : -32768);
		}

#define BUTTON_CALLBACK(name, button) \
		void name(const GamePad_ButtonEvent* event) { DispatchButton(event, button); }
		BUTTON_CALLBACK(OnA, SDL_GAMEPAD_BUTTON_SOUTH)
		BUTTON_CALLBACK(OnB, SDL_GAMEPAD_BUTTON_EAST)
		BUTTON_CALLBACK(OnX, SDL_GAMEPAD_BUTTON_WEST)
		BUTTON_CALLBACK(OnY, SDL_GAMEPAD_BUTTON_NORTH)
		BUTTON_CALLBACK(OnMenu, SDL_GAMEPAD_BUTTON_START)
		BUTTON_CALLBACK(OnHome, SDL_GAMEPAD_BUTTON_BACK)
		BUTTON_CALLBACK(OnL1, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER)
		BUTTON_CALLBACK(OnR1, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER)
		BUTTON_CALLBACK(OnUp, SDL_GAMEPAD_BUTTON_DPAD_UP)
		BUTTON_CALLBACK(OnDown, SDL_GAMEPAD_BUTTON_DPAD_DOWN)
		BUTTON_CALLBACK(OnLeft, SDL_GAMEPAD_BUTTON_DPAD_LEFT)
		BUTTON_CALLBACK(OnRight, SDL_GAMEPAD_BUTTON_DPAD_RIGHT)
		BUTTON_CALLBACK(OnL3, SDL_GAMEPAD_BUTTON_LEFT_STICK)
		BUTTON_CALLBACK(OnR3, SDL_GAMEPAD_BUTTON_RIGHT_STICK)
#undef BUTTON_CALLBACK
		void OnL2Button(const GamePad_ButtonEvent* event) { DispatchTriggerButton(event, SDL_GAMEPAD_AXIS_LEFT_TRIGGER); }
		void OnR2Button(const GamePad_ButtonEvent* event) { DispatchTriggerButton(event, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER); }

		int StickToSdl(double value)
		{
			if (std::abs(value) <= 1.5)
				value *= (value < 0.0 ? 32768.0 : 32767.0);
			return static_cast<int>(std::clamp(value, -32768.0, 32767.0));
		}

		int TriggerToSdl(double value)
		{
			// GameControllerKit exposes Hall triggers as 0..1. SDL's trigger rest
			// value is -32768, so convert into its full signed axis domain.
			if (value >= -0.01 && value <= 1.01)
				value = value * 65535.0 - 32768.0;
			return static_cast<int>(std::clamp(value, -32768.0, 32767.0));
		}

		void OnAxis(const GamePad_AxisEvent* event)
		{
			if (event == nullptr || !AcceptDevice(ReadEventDeviceId(event)))
				return;
			GamePad_AxisSourceType source = LEFT_THUMBSTICK;
			if (s_api.get_axis_source(event, &source) != GAME_CONTROLLER_SUCCESS)
				return;

			double first = 0.0;
			double second = 0.0;
			switch (source)
			{
				case LEFT_THUMBSTICK:
					if (s_api.get_axis_x(event, &first) == GAME_CONTROLLER_SUCCESS)
						Hps2VPad::SetAxis(SDL_GAMEPAD_AXIS_LEFTX, StickToSdl(first));
					if (s_api.get_axis_y(event, &second) == GAME_CONTROLLER_SUCCESS)
						Hps2VPad::SetAxis(SDL_GAMEPAD_AXIS_LEFTY, StickToSdl(second));
					break;
				case RIGHT_THUMBSTICK:
					if (s_api.get_axis_z(event, &first) == GAME_CONTROLLER_SUCCESS)
						Hps2VPad::SetAxis(SDL_GAMEPAD_AXIS_RIGHTX, StickToSdl(first));
					if (s_api.get_axis_rz(event, &second) == GAME_CONTROLLER_SUCCESS)
						Hps2VPad::SetAxis(SDL_GAMEPAD_AXIS_RIGHTY, StickToSdl(second));
					break;
				case LEFT_TRIGGER:
					if (s_api.get_axis_brake(event, &first) == GAME_CONTROLLER_SUCCESS)
						Hps2VPad::SetAxis(SDL_GAMEPAD_AXIS_LEFT_TRIGGER, TriggerToSdl(first));
					break;
				case RIGHT_TRIGGER:
					if (s_api.get_axis_gas(event, &first) == GAME_CONTROLLER_SUCCESS)
						Hps2VPad::SetAxis(SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, TriggerToSdl(first));
					break;
				default:
					return;
			}
			GPLOGI("official axis source=%{public}d first=%{public}f second=%{public}f",
				static_cast<int>(source), first, second);
		}

		bool RegisterMonitorsLocked()
		{
			if (s_monitors_registered)
				return true;
			int succeeded = 0;
			int attempted = 0;
#define REGISTER(member, callback) \
			do { attempted++; if (s_api.member(callback) == GAME_CONTROLLER_SUCCESS) succeeded++; } while (false)
			REGISTER(register_a, OnA);
			REGISTER(register_b, OnB);
			REGISTER(register_x, OnX);
			REGISTER(register_y, OnY);
			REGISTER(register_menu, OnMenu);
			REGISTER(register_home, OnHome);
			REGISTER(register_l1, OnL1);
			REGISTER(register_r1, OnR1);
			REGISTER(register_l2_button, OnL2Button);
			REGISTER(register_r2_button, OnR2Button);
			REGISTER(register_dpad_up, OnUp);
			REGISTER(register_dpad_down, OnDown);
			REGISTER(register_dpad_left, OnLeft);
			REGISTER(register_dpad_right, OnRight);
			REGISTER(register_l3, OnL3);
			REGISTER(register_r3, OnR3);
			REGISTER(register_left_stick, OnAxis);
			REGISTER(register_right_stick, OnAxis);
			REGISTER(register_l2_axis, OnAxis);
			REGISTER(register_r2_axis, OnAxis);
#undef REGISTER
			s_monitors_registered = (succeeded == attempted);
			GPLOGI("GameControllerKit monitors registered %{public}d/%{public}d", succeeded, attempted);
			return succeeded > 0;
		}
	}

	bool Initialize()
	{
		std::lock_guard<std::mutex> lock(s_mutex);
		return LoadApiLocked() && RegisterMonitorsLocked();
	}

	std::vector<std::pair<std::string, std::string>> EnumerateDevices()
	{
		std::lock_guard<std::mutex> lock(s_mutex);
		std::vector<std::pair<std::string, std::string>> result;
		if (!LoadApiLocked())
			return result;

		GameDevice_AllDeviceInfos* all = nullptr;
		if (s_api.get_all_devices(&all) != GAME_CONTROLLER_SUCCESS || all == nullptr)
			return result;

		int32_t count = 0;
		if (s_api.get_device_count(all, &count) == GAME_CONTROLLER_SUCCESS)
		{
			for (int32_t index = 0; index < count; index++)
			{
				GameDevice_DeviceInfo* info = nullptr;
				if (s_api.get_device_info(all, index, &info) != GAME_CONTROLLER_SUCCESS || info == nullptr)
					continue;
				GameDevice_DeviceType type = UNKNOWN;
				char* id = nullptr;
				char* name = nullptr;
				const bool is_pad = s_api.get_device_type(info, &type) == GAME_CONTROLLER_SUCCESS && type == GAME_PAD;
				const bool has_id = s_api.get_device_id(info, &id) == GAME_CONTROLLER_SUCCESS && id != nullptr;
				const bool has_name = s_api.get_device_name(info, &name) == GAME_CONTROLLER_SUCCESS && name != nullptr;
				if (is_pad && has_id)
					result.emplace_back(std::string(DEVICE_PREFIX) + id, has_name ? name : "HarmonyOS Gamepad");
				std::free(id);
				std::free(name);
				s_api.destroy_device_info(&info);
			}
		}
		s_api.destroy_all_devices(&all);
		GPLOGI("GameControllerKit enumerated %{public}zu gamepad(s)", result.size());
		return result;
	}

	bool SelectDevice(const std::string& identifier, int port)
	{
		if (!IsOfficialDeviceId(identifier) || port != 0 || !Initialize())
			return false;
		std::lock_guard<std::mutex> lock(s_mutex);
		s_selected_device = identifier.substr(std::char_traits<char>::length(DEVICE_PREFIX));
		GPLOGI("GameControllerKit device selected for port 0");
		return true;
	}

	bool IsAvailable()
	{
		std::lock_guard<std::mutex> lock(s_mutex);
		return s_monitors_registered;
	}

	bool IsOfficialDeviceId(const std::string& identifier)
	{
		return identifier.rfind(DEVICE_PREFIX, 0) == 0;
	}
}
