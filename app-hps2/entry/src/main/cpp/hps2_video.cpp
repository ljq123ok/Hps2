/*
 * Hps2 — 画面显示控制实现。设计说明见 hps2_video.h。
 */

#include "hps2_video.h"

#include <hilog/log.h>

#include <atomic>

// PCSX2 侧
#include "Config.h"
#include "GS/GS.h"
#include "MTGS.h"
#include "VMManager.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3202
#define LOG_TAG "HPS2_VIDEO"

#define VLOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define VLOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace Hps2Video
{
	namespace
	{
		std::atomic<AspectMode> s_mode{AspectMode::Auto};
		std::atomic<bool> s_landscape{false};

		/// 把 AspectMode 翻译成 PCSX2 的 AspectRatioType。
		AspectRatioType ToPcsx2Mode(AspectMode m, bool landscape)
		{
			switch (m)
			{
				case AspectMode::Keep4_3:
					return AspectRatioType::R4_3;
				case AspectMode::Stretch:
					return AspectRatioType::Stretch;
				case AspectMode::Wide16_9:
					return AspectRatioType::R16_9;
				case AspectMode::Auto:
				default:
					// 自动策略的依据（本机实测数字，非感觉）：
					//   横屏 Stretch 的横向拉伸约 1.26x —— 不明显，可接受，
					//   换来完全铺满，观感更好；
					//   竖屏 Stretch 的纵向拉伸约 1.81x —— 人物会明显变瘦长，
					//   宁可保持 4:3 留黑边（黑边正好放虚拟按键）。
					return landscape ? AspectRatioType::Stretch : AspectRatioType::R4_3;
			}
		}
	}

	AspectMode ResolveForOrientation(bool landscape)
	{
		return ToPcsx2Mode(s_mode.load(), landscape) == AspectRatioType::Stretch
			? AspectMode::Stretch
			: (landscape ? AspectMode::Stretch : AspectMode::Keep4_3);
	}

	bool SetAspectMode(AspectMode mode)
	{
		s_mode.store(mode);

		const bool landscape = s_landscape.load();
		const AspectRatioType ar = ToPcsx2Mode(mode, landscape);

		// 直接改当前生效的 GS 配置，再让 MTGS 重新应用。
		//
		// 为什么不走 SettingsInterface：本应用目前用 MemorySettingsInterface，
		// 配置全在内存；而 GSConfig 是 GS 线程实际读取的那份，
		// 改它 + ApplySettings 是上游的运行期生效路径
		// （见 GS.cpp 里多处 MTGS::ApplySettings 调用）。
		GSConfig.AspectRatio = ar;
		EmuConfig.CurrentAspectRatio = ar;

		if (MTGS::IsOpen())
		{
			MTGS::ApplySettings();
			VLOGI("aspect mode set to %{public}d (landscape=%{public}d) -> pcsx2 AR %{public}d",
				static_cast<int>(mode), landscape ? 1 : 0, static_cast<int>(ar));
			return true;
		}

		// VM 尚未启动：配置已写入 GSConfig，启动时会生效。
		VLOGI("aspect mode recorded as %{public}d (VM not running; will apply on boot)",
			static_cast<int>(mode));
		return true;
	}

	AspectMode GetAspectMode()
	{
		return s_mode.load();
	}

	bool NotifyResize(unsigned int width, unsigned int height)
	{
		if (width == 0 || height == 0)
		{
			VLOGE("NotifyResize: invalid size %{public}ux%{public}u", width, height);
			return false;
		}

		const bool landscape = (width > height);
		const bool orientation_changed = (landscape != s_landscape.load());
		s_landscape.store(landscape);

		if (!MTGS::IsOpen())
		{
			// VM 未运行：只记录方向。「自动」模式下的比例会在启动时按此决定。
			VLOGI("NotifyResize: %{public}ux%{public}u (landscape=%{public}d) — VM not running, "
			      "orientation recorded only",
				width, height, landscape ? 1 : 0);
			return false;
		}

		// 方向变化时，「自动」模式需要切换宽高比：
		// 横屏铺满、竖屏保持 4:3（理由见 ToPcsx2Mode 的注释）。
		if (orientation_changed && s_mode.load() == AspectMode::Auto)
		{
			const AspectRatioType ar = ToPcsx2Mode(AspectMode::Auto, landscape);
			GSConfig.AspectRatio = ar;
			EmuConfig.CurrentAspectRatio = ar;
			VLOGI("orientation changed -> landscape=%{public}d, auto AR switched to %{public}d",
				landscape ? 1 : 0, static_cast<int>(ar));
		}

		// 关键：把新尺寸通知 GS，让它重建视口、投影与（可能的）交换链。
		// 上游用法见 MTGS.cpp:1006 —— 必须经 GS 线程，不能直接改 device。
		MTGS::ResizeDisplayWindow(width, height, 1.0f);
		MTGS::UpdateDisplayWindow();

		VLOGI("NotifyResize applied: %{public}ux%{public}u (landscape=%{public}d)",
			width, height, landscape ? 1 : 0);
		return true;
	}
}
