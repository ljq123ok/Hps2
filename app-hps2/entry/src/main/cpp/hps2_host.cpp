/*
 * Hps2 — Host 接口实现（HarmonyOS）
 *
 * 来源：直接复用 pcsx2-eerunner/Main.cpp 的 Host 实现区块（第 216-525 行）。
 * 该区块经核实无 Linux 专属依赖，且 eerunner 本身即为无头运行，
 * 与 HAP 的 native 层需求一致。
 *
 * 上游依据：
 *   ARMSX2 commit d7e8d01678107f066d6ec988ca178d80089bd9f5
 *   GPL-3.0+（与本项目一致）
 */
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "fmt/format.h"

#include "common/Assertions.h"
#include "common/Console.h"
#include "common/CrashHandler.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include "common/MemorySettingsInterface.h"
#include "common/Path.h"
#include "common/Perf.h"
#include "common/ProgressCallback.h"
#include "common/SettingsWrapper.h"
#include "common/StringUtil.h"

#include "pcsx2/PrecompiledHeader.h"
#include "pcsx2/Achievements.h"
#include "pcsx2/DebugTools/Debug.h"
#include "pcsx2/GS/GS.h"
#include "pcsx2/MTGS.h"
#include "pcsx2/Host.h"
#include "pcsx2/INISettingsInterface.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/VMManager.h"

#include "hps2_surface.h"

#include <native_window/external_window.h>

// 以下头文件声明了 Host 接口中与 UI 相关的成员
// （LocaleCircleConfirm / RequestExitApplication / BeginTextInput /
//  ShouldPreferHostFileSelector / OnCoverDownloaderOpenRequested 等）。
// 这些方法由前端实现，但声明位于 ImGui UI 头文件中。
#include "pcsx2/ImGui/FullscreenUI.h"
#include "pcsx2/ImGui/ImGuiFullscreen.h"
#include "pcsx2/ImGui/ImGuiManager.h"

// 说明：eerunner 原始文件另含 <linux/perf_event.h> 等 Linux 专属头，
// 那是其性能剖析功能所需，与本 Host 实现无关，故不引入。



void Host::CommitBaseSettingChanges()
{
	// nothing to save, settings are entirely in memory
}

void Host::LoadSettings(SettingsInterface& si, std::unique_lock<std::mutex>& lock)
{
}

void Host::CheckForSettingsChanges(const Pcsx2Config& old_config)
{
}

bool Host::RequestResetSettings(bool folders, bool core, bool controllers, bool hotkeys, bool ui)
{
	// not running any UI, so no settings requests will come in
	return false;
}

void Host::SetDefaultUISettings(SettingsInterface& si)
{
	// nothing
}

bool Host::LocaleCircleConfirm()
{
	// not running any UI, so no settings requests will come in
	return false;
}

std::unique_ptr<ProgressCallback> Host::CreateHostProgressCallback()
{
	return ProgressCallback::CreateNullProgressCallback();
}

void Host::ReportInfoAsync(const std::string_view title, const std::string_view message)
{
	if (!title.empty() && !message.empty())
		INFO_LOG("ReportInfoAsync: {}: {}", title, message);
	else if (!message.empty())
		INFO_LOG("ReportInfoAsync: {}", message);
}

void Host::ReportErrorAsync(const std::string_view title, const std::string_view message)
{
	if (!title.empty() && !message.empty())
		ERROR_LOG("ReportErrorAsync: {}: {}", title, message);
	else if (!message.empty())
		ERROR_LOG("ReportErrorAsync: {}", message);
}

void Host::OpenURL(const std::string_view url)
{
	// noop
}

bool Host::CopyTextToClipboard(const std::string_view text)
{
	return false;
}

std::string Host::GetTextFromClipboard()
{
	return std::string();
}

void Host::BeginTextInput()
{
	// noop
}

void Host::EndTextInput()
{
	// noop
}

std::optional<WindowInfo> Host::GetTopLevelWindowInfo()
{
	// Headless — never present anything.
	WindowInfo wi;
	wi.type = WindowInfo::Type::Surfaceless;
	return wi;
}

void Host::OnInputDeviceConnected(const std::string_view identifier, const std::string_view device_name)
{
}

void Host::OnInputDeviceDisconnected(const InputBindingKey key, const std::string_view identifier)
{
}

void Host::SetMouseMode(bool relative_mode, bool hide_cursor)
{
}

void Host::SetMouseLock(bool state)
{
}

std::optional<WindowInfo> Host::AcquireRenderWindow(bool recreate_window)
{
	// [Hps2] 这是 GS 取得渲染窗口的唯一入口（GSDevice.cpp:474 调用）。
	//
	// 上游 eerunner 的版本固定返回 Surfaceless（它用 Null 渲染器、不需窗口），
	// 我们最初直接沿用了那段实现 —— 后果是：即使 ArkTS 已经通过 setSurface()
	// 交出了 OHNativeWindow，GS 也永远看不到它，画面不可能显示。
	//
	// 现在的行为：
	//   前端有可用表面 → 返回 WindowInfo{type=OHOS}，GS 走 OpenGL 真正渲染；
	//   前端没有表面   → 退回 Surfaceless，配合 Null 渲染器只验证核心逻辑。
	const Hps2Surface::Snapshot surf = Hps2Surface::Get();

	WindowInfo wi;
	if (surf.ready && surf.window != nullptr)
	{
		wi.type = WindowInfo::Type::OHOS;
		wi.window_handle = surf.window;

		// ------------------------------------------------------------------
		// 尺寸以**窗口缓冲区的实测值**为准，而不是前端上报值。
		//
		// 原因：GS 用 surface_width/height 建立视口、scissor 与正交投影
		// （GSDeviceOGL.cpp:3390），必须与 EGL 实际的缓冲区尺寸一致。
		//
		// ArkTS 的 onAreaChange 返回 **vp（虚拟像素）**，而 OHNativeWindow
		// 的缓冲区是**物理像素**（本机缩放约 2.6x）。前端按 vp 上报时
		// 408x158 对应真实缓冲区约 1071x414 —— 视口小于缓冲区会让画面
		// 挤在左下角（OpenGL 视口原点在左下角），真机症状正是如此。
		//
		// 直接查询缓冲区尺寸可避开 vp/px 换算的正确性假设，
		// 无论前端上报什么单位、缩放如何变化，都以硬件事实为准。
		//
		// 注意 OHOS 文档写明 GET_BUFFER_GEOMETRY 的输出顺序是
		//   [out] int32_t *height, [out] int32_t *width
		// 与直觉相反（Android 是 getWidth/getHeight），故此处按文档传参。
		// ------------------------------------------------------------------
		int32_t buf_h = 0, buf_w = 0;
		const int32_t geo_err = OH_NativeWindow_NativeWindowHandleOpt(
			static_cast<OHNativeWindow*>(surf.window), GET_BUFFER_GEOMETRY, &buf_h, &buf_w);

		if (geo_err == 0 && buf_w > 0 && buf_h > 0)
		{
			wi.surface_width = static_cast<u32>(buf_w);
			wi.surface_height = static_cast<u32>(buf_h);
			Console.WriteLn("Host::AcquireRenderWindow: OHOS surface %dx%d (from native buffer; "
			                "frontend reported %dx%d; window=%p)",
				buf_w, buf_h, surf.width, surf.height, surf.window);

			if (buf_w != surf.width || buf_h != surf.height)
			{
				Console.WriteLn("Host::AcquireRenderWindow: frontend size differs from the native "
				                "buffer (likely vp vs px); using the native value for the viewport");
			}
		}
		else
		{
			// 查询失败则退回前端上报值，并明确记录，避免静默使用可疑数据
			wi.surface_width = static_cast<u32>(surf.width);
			wi.surface_height = static_cast<u32>(surf.height);
			Console.Warning("Host::AcquireRenderWindow: GET_BUFFER_GEOMETRY failed (%d); "
			                "falling back to frontend size %ux%u",
				geo_err, wi.surface_width, wi.surface_height);
		}

		wi.surface_scale = 1.0f;
	}
	else
	{
		wi.type = WindowInfo::Type::Surfaceless;
		Console.WriteLn("Host::AcquireRenderWindow: no OHOS surface yet, returning Surfaceless");
	}

	return wi;
}

void Host::ReleaseRenderWindow()
{
	// 表面由 ArkTS 侧持有并管理生命周期（XComponent 的 onSurfaceDestroyed），
	// 这里不需要释放 OHNativeWindow。
}

void Host::BeginPresentFrame()
{
	// Headless — nothing to present.
}

void Host::RequestResizeHostDisplay(s32 width, s32 height)
{
}

void Host::OnVMStarting()
{
}

void Host::OnVMStarted()
{
}

void Host::OnVMDestroyed()
{
}

void Host::OnVMPaused()
{
}

void Host::OnVMResumed()
{
}

void Host::OnGameChanged(const std::string& title, const std::string& elf_override, const std::string& disc_path,
	const std::string& disc_serial, u32 disc_crc, u32 current_crc)
{
}

void Host::OnPerformanceMetricsUpdated()
{
}

void Host::OnSaveStateLoading(const std::string_view filename)
{
}

void Host::OnSaveStateLoaded(const std::string_view filename, bool was_successful)
{
}

void Host::OnSaveStateSaved(const std::string_view filename)
{
}

void Host::RunOnCPUThread(std::function<void()> function, bool block /* = false */)
{
	pxFailRel("Not implemented");
}

void Host::RefreshGameListAsync(bool invalidate_cache)
{
}

void Host::CancelGameListRefresh()
{
}

bool Host::IsFullscreen()
{
	return false;
}

void Host::SetFullscreen(bool enabled)
{
}

void Host::RequestExitApplication(bool allow_confirm)
{
}

void Host::RequestExitBigPicture()
{
}

void Host::RequestVMShutdown(bool allow_confirm, bool allow_save_state, bool default_save_state)
{
	VMManager::SetState(VMState::Stopping);
}

void Host::OnAchievementsLoginSuccess(const char* username, u32 points, u32 sc_points, u32 unread_messages)
{
	// noop
}

void Host::OnAchievementsLoginRequested(Achievements::LoginRequestReason reason)
{
	// noop
}

void Host::OnAchievementsHardcoreModeChanged(bool enabled)
{
	// noop
}

bool Host::HasNativeAchievementNotifications() { return false; }
void Host::OnAchievementNotification(const char*, float, const char*, const char*, const char*) {}

void Host::OnAchievementsRefreshed()
{
	// noop
}

void Host::OnCoverDownloaderOpenRequested()
{
	// noop
}

void Host::OnCreateMemoryCardOpenRequested()
{
	// noop
}

bool Host::InBatchMode()
{
	return false;
}

bool Host::InNoGUIMode()
{
	return false;
}

bool Host::ShouldPreferHostFileSelector()
{
	return false;
}

void Host::OpenHostFileSelectorAsync(std::string_view title, bool select_directory, FileSelectorCallback callback,
	FileSelectorFilters filters, std::string_view initial_directory)
{
	callback(std::string());
}

int Host::LocaleSensitiveCompare(std::string_view lhs, std::string_view rhs)
{
	const int res = std::strncmp(lhs.data(), rhs.data(), std::min(lhs.size(), rhs.size()));
	if (res != 0)
		return res;
	return lhs.size() > rhs.size() ? 1 : (lhs.size() < rhs.size() ? -1 : 0);
}

std::optional<u32> InputManager::ConvertHostKeyboardStringToCode(const std::string_view str)
{
	return std::nullopt;
}

std::optional<std::string> InputManager::ConvertHostKeyboardCodeToString(u32 code)
{
	return std::nullopt;
}

const char* InputManager::ConvertHostKeyboardCodeToIcon(u32 code)
{
	return nullptr;
}

BEGIN_HOTKEY_LIST(g_host_hotkeys)
END_HOTKEY_LIST()

void Host::PumpMessagesOnCPUThread()
{
	// Headless — no platform message pump.
}

s32 Host::Internal::GetTranslatedStringImpl(
	const std::string_view context, const std::string_view msg, char* tbuf, size_t tbuf_space)
{
	if (msg.size() > tbuf_space)
		return -1;
	else if (msg.empty())
		return 0;

	std::memcpy(tbuf, msg.data(), msg.size());
	return static_cast<s32>(msg.size());
}

std::string Host::TranslatePluralToString(const char* context, const char* msg, const char* disambiguation, int count)
{
	TinyString count_str = TinyString::from_format("{}", count);

	std::string ret(msg);
	for (;;)
	{
		std::string::size_type pos = ret.find("%n");
		if (pos == std::string::npos)
			break;

		ret.replace(pos, 2, count_str.view());
	}

	return ret;
}
