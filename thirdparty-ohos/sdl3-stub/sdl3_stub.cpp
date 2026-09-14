/*
 * Hps2 — SDL3 minimal stub for HarmonyOS (OHOS)
 *
 * 为什么需要这个文件：
 *   ARMSX2 的核心无条件编入 3 个使用 SDL 的源文件
 *   (Host/SDLAudioStream.cpp, Input/SDLInputSource.cpp,
 *    USB/usb-pad/usb-pad-sdl-ff.cpp)，因此核心要编译就必须满足 SDL3 符号。
 *   而 SDL3 没有 HarmonyOS 平台支持（其平台检测只有 UNIX/Android/Apple，
 *   OHOS 落到 UNIX_SYS 后要求 X11/Wayland/ALSA，这些在 OHOS 上都不存在）。
 *
 * 本 stub 的定位：
 *   **只保证链接通过**，不提供任何真实功能。音频与输入将由 OHOS 原生实现
 *   替换（libohaudio.so / libohgame_controller.z.so）。
 *
 * 设计原则：
 *   1. 使用 SDL3 **真实头文件**，保证类型/枚举/ABI 与上游代码预期完全一致
 *      （已验证这些头文件可在 OHOS toolchain 下编译）。
 *   2. 函数签名由真实头文件自动提取生成，避免手写出错。
 *   3. 所有函数返回"失败/空"的默认值，且不崩溃 —— 调用方拿到失败后会
 *      走各自的错误分支，而不是产生未定义行为。
 */

#include <SDL3/SDL.h>

// 仅在 OHOS 上编译
#if defined(__OHOS__)

extern "C" {

void SDLCALL SDL_CloseGamepad(SDL_Gamepad *gamepad)
{
    /* stub: 无实现 */
}

void SDLCALL SDL_CloseHaptic(SDL_Haptic *haptic)
{
    /* stub: 无实现 */
}

void SDLCALL SDL_CloseJoystick(SDL_Joystick *joystick)
{
    /* stub: 无实现 */
}

SDL_HapticEffectID SDLCALL SDL_CreateHapticEffect(SDL_Haptic *haptic, const SDL_HapticEffect *effect)
{
    /* stub: 恒返回失败值 */
    return 0;
}

void SDLCALL SDL_DestroyAudioStream(SDL_AudioStream *stream)
{
    /* stub: 无实现 */
}

void SDLCALL SDL_DestroyHapticEffect(SDL_Haptic *haptic, SDL_HapticEffectID effect)
{
    /* stub: 无实现 */
}

bool SDLCALL SDL_GetAudioDeviceFormat(SDL_AudioDeviceID devid, SDL_AudioSpec *spec, int *sample_frames)
{
    /* stub: 恒返回失败值 */
    return false;
}

SDL_AudioDeviceID SDLCALL SDL_GetAudioStreamDevice(SDL_AudioStream *stream)
{
    /* stub: 恒返回失败值 */
    return 0;
}

bool SDLCALL SDL_GetBooleanProperty(SDL_PropertiesID props, const char *name, bool default_value)
{
    /* stub: 恒返回失败值 */
    return false;
}

const char * SDLCALL SDL_GetError(void)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

SDL_GamepadBinding ** SDLCALL SDL_GetGamepadBindings(SDL_Gamepad *gamepad, int *count)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

SDL_GamepadButtonLabel SDLCALL SDL_GetGamepadButtonLabel(SDL_Gamepad *gamepad, SDL_GamepadButton button)
{
    /* stub: 恒返回失败值 */
    return {};
}

SDL_Joystick * SDLCALL SDL_GetGamepadJoystick(SDL_Gamepad *gamepad)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

char ** SDLCALL SDL_GetGamepadMappings(int *count)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

const char * SDLCALL SDL_GetGamepadName(SDL_Gamepad *gamepad)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

int SDLCALL SDL_GetGamepadPlayerIndex(SDL_Gamepad *gamepad)
{
    /* stub: 恒返回失败值 */
    return 0;
}

SDL_PropertiesID SDLCALL SDL_GetGamepadProperties(SDL_Gamepad *gamepad)
{
    /* stub: 恒返回失败值 */
    return 0;
}

Uint32 SDLCALL SDL_GetHapticFeatures(SDL_Haptic *haptic)
{
    /* stub: 恒返回失败值 */
    return 0;
}

SDL_JoystickID SDLCALL SDL_GetJoystickID(SDL_Joystick *joystick)
{
    /* stub: 恒返回失败值 */
    return 0;
}

const char * SDLCALL SDL_GetJoystickName(SDL_Joystick *joystick)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

int SDLCALL SDL_GetJoystickPlayerIndex(SDL_Joystick *joystick)
{
    /* stub: 恒返回失败值 */
    return 0;
}

int SDLCALL SDL_GetNumJoystickAxes(SDL_Joystick *joystick)
{
    /* stub: 恒返回失败值 */
    return 0;
}

int SDLCALL SDL_GetNumJoystickButtons(SDL_Joystick *joystick)
{
    /* stub: 恒返回失败值 */
    return 0;
}

int SDLCALL SDL_GetNumJoystickHats(SDL_Joystick *joystick)
{
    /* stub: 恒返回失败值 */
    return 0;
}

SDL_GamepadType SDLCALL SDL_GetRealGamepadType(SDL_Gamepad *gamepad)
{
    /* stub: 恒返回失败值 */
    return (SDL_GamepadType)0;
}

bool SDLCALL SDL_HapticRumbleSupported(SDL_Haptic *haptic)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_InitHapticRumble(SDL_Haptic *haptic)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_InitSubSystem(SDL_InitFlags flags)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_IsGamepad(SDL_JoystickID instance_id)
{
    /* stub: 恒返回失败值 */
    return false;
}

SDL_AudioStream * SDLCALL SDL_OpenAudioDeviceStream(SDL_AudioDeviceID devid, const SDL_AudioSpec *spec, SDL_AudioStreamCallback callback, void *userdata)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

SDL_Gamepad * SDLCALL SDL_OpenGamepad(SDL_JoystickID instance_id)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

SDL_Haptic * SDLCALL SDL_OpenHapticFromJoystick(SDL_Joystick *joystick)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

SDL_Joystick * SDLCALL SDL_OpenJoystick(SDL_JoystickID instance_id)
{
    /* stub: 恒返回失败值 */
    return nullptr;
}

bool SDLCALL SDL_PauseAudioDevice(SDL_AudioDeviceID devid)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_PlayHapticRumble(SDL_Haptic *haptic, float strength, Uint32 length)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_PollEvent(SDL_Event *event)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_PutAudioStreamData(SDL_AudioStream *stream, const void *buf, int len)
{
    /* stub: 恒返回失败值 */
    return false;
}

void SDLCALL SDL_QuitSubSystem(SDL_InitFlags flags)
{
    /* stub: 无实现 */
}

bool SDLCALL SDL_ResumeAudioDevice(SDL_AudioDeviceID devid)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_RumbleGamepad(SDL_Gamepad *gamepad, Uint16 low_frequency_rumble, Uint16 high_frequency_rumble, Uint32 duration_ms)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_RunHapticEffect(SDL_Haptic *haptic, SDL_HapticEffectID effect, Uint32 iterations)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_SetGamepadLED(SDL_Gamepad *gamepad, Uint8 red, Uint8 green, Uint8 blue)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_SetHapticAutocenter(SDL_Haptic *haptic, int autocenter)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_SetHint(const char *name, const char *value)
{
    /* stub: 恒返回失败值 */
    return false;
}

void SDLCALL SDL_SetLogOutputFunction(SDL_LogOutputFunction callback, void *userdata)
{
    /* stub: 无实现 */
}

void SDLCALL SDL_SetLogPriorities(SDL_LogPriority priority)
{
    /* stub: 无实现 */
}

bool SDLCALL SDL_StopHapticEffect(SDL_Haptic *haptic, SDL_HapticEffectID effect)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_StopHapticRumble(SDL_Haptic *haptic)
{
    /* stub: 恒返回失败值 */
    return false;
}

bool SDLCALL SDL_UpdateHapticEffect(SDL_Haptic *haptic, SDL_HapticEffectID effect, const SDL_HapticEffect *data)
{
    /* stub: 恒返回失败值 */
    return false;
}

void SDLCALL SDL_free(void *mem)
{
    /* stub: 无实现 */
}

}  // extern "C"

#endif  // __OHOS__
