/*
 * Hps2 — HarmonyOS GameControllerKit bridge.
 *
 * GameControllerKit was introduced in API 21 while Hps2 still declares API 20
 * compatibility.  The implementation therefore resolves the API at runtime:
 * API 21+ devices get native controller discovery/input, older devices keep the
 * existing ArkUI/SDL fallback without failing to load libhps2core.so.
 */
#pragma once

#include <string>
#include <utility>
#include <vector>

namespace Hps2Gamepad
{
	/// Load GameControllerKit and register the global gamepad input monitors.
	bool Initialize();

	/// Enumerate the gamepads known to HarmonyOS GameControllerKit.
	std::vector<std::pair<std::string, std::string>> EnumerateDevices();

	/// Select a GameControllerKit device for PS2 port 0.
	bool SelectDevice(const std::string& identifier, int port);

	/// True after the native GameControllerKit monitors were registered.
	bool IsAvailable();

	bool IsOfficialDeviceId(const std::string& identifier);
}
