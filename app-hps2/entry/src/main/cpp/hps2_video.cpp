/*
 * Hps2 — 画面显示控制实现。设计说明见 hps2_video.h。
 */

#include "hps2_video.h"

#include <hilog/log.h>

#include <atomic>
#include <cmath>

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
#define VLOGW(...) OH_LOG_Print(LOG_APP, LOG_WARN,  LOG_DOMAIN, LOG_TAG, __VA_ARGS__)
#define VLOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__)

namespace Hps2Video
{
	namespace
	{
		std::atomic<AspectMode> s_mode{AspectMode::Auto};
		std::atomic<bool> s_landscape{false};
		std::atomic<float> s_upscale_multiplier{1.0f};

		// MTVU 状态。默认 false 以保持与我们初始化设置一致
		// （初始化里显式写了 vuThread=false）。
		std::atomic<bool> s_vu_thread{false};
		std::atomic<unsigned int> s_pending_width{0};
		std::atomic<unsigned int> s_pending_height{0};

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

		// ArkUI/N-API runs outside PCSX2's CPU thread. Stage the values here;
		// MTGS::ApplySettings() is called by the VM CPU thread at boot.
		VLOGI("aspect mode queued as %{public}d (landscape=%{public}d) -> pcsx2 AR %{public}d",
			static_cast<int>(mode), landscape ? 1 : 0, static_cast<int>(ar));
		return true;
	}

	AspectMode GetAspectMode()
	{
		return s_mode.load();
	}

	bool SetUpscaleMultiplier(float multiplier)
	{
		if (!std::isfinite(multiplier) || multiplier < 1.0f || multiplier > 4.0f)
			return false;

		s_upscale_multiplier.store(multiplier);
		// Do not call MTGS::ApplySettings() from ArkUI. Upstream requires that
		// RunOnGSThread is entered from the VM CPU thread; direct UI calls can
		// assert, race GS, and explain both delayed crashes and no-op changes.
		VLOGI("upscale multiplier queued as %{public}f (safe CPU-thread apply)", multiplier);
		return true;
	}

	// ---------------------------------------------------------------------
	// MTVU（VU1 独立线程）
	//
	// 上游 Config.h:1366 的默认值是 vuThread : 1（开启）。
	// 我们在初始化时显式设为 false，理由是早期"减少线程依赖"以保证
	// 能稳定启动 —— 但那是阶段2 的权宜，现已能稳定运行游戏。
	//
	// 效果：VU1 是 PS2 三大计算单元之一，把它移到独立线程可让 EE
	// 与 VU1 并行，典型收益 10~30%。
	//
	// 做成开关而非强制开启：MTVU 改变了线程模型，个别游戏可能因此
	// 出现兼容问题，需要让用户能按游戏切换。
	// ---------------------------------------------------------------------
	bool SetVuThread(bool enabled)
	{
		s_vu_thread.store(enabled);
		// 与 upscale/aspect 同理：真正的应用在 CPU 线程上进行
		// （见 ApplyPendingSettingsOnCPUThread），避免从 ArkUI 直接改
		// 运行中的 VM 状态。
		VLOGI("MTVU (vuThread) staged as %{public}d (safe CPU-thread apply)",
			enabled ? 1 : 0);
		return true;
	}

	bool GetVuThread()
	{
		return s_vu_thread.load();
	}

	void ApplyPendingSettingsOnCPUThread()
	{
		const float multiplier = s_upscale_multiplier.load();
		const AspectRatioType ar = ToPcsx2Mode(s_mode.load(), s_landscape.load());
		GSConfig.AspectRatio = ar;
		EmuConfig.CurrentAspectRatio = ar;
		EmuConfig.GS.AspectRatio = ar;
		GSConfig.UpscaleMultiplier = multiplier;
		EmuConfig.GS.UpscaleMultiplier = multiplier;

		// MTVU：写 EmuConfig.Speedhacks.vuThread。
		// THREAD_VU1 = REC_VU1 && Speedhacks.vuThread（Config.h:1730）。
		//
		// 【重要】MTVU **无法在运行期可靠切换**：
		//   vu1Thread.Open() 只在 recMicroVU1::Reserve()（VU1 重编译器
		//   初始化时）调用一次（microVU-arm64.cpp:1934），与 vuThread
		//   设置无关；而 VU1 的执行路径由 THREAD_VU1 宏在编译 JIT 代码时
		//   决定。运行期改这个标志会让已编译的 VU1 代码与新的宏取值不一致。
		//
		// 因此本设置按"**下次启动游戏生效**"设计，UI 也会如此说明。
		// 此处只在 VM 尚未启动时写入，避免对运行中的 VM 造成不一致。
		const bool vu_thread = s_vu_thread.load();
		if (!VMManager::HasValidVM())
		{
			if (EmuConfig.Speedhacks.vuThread != vu_thread)
			{
				EmuConfig.Speedhacks.vuThread = vu_thread;
				VLOGI("MTVU (vuThread) applied at startup: %{public}d", vu_thread ? 1 : 0);
			}
		}
		else if (EmuConfig.Speedhacks.vuThread != vu_thread)
		{
			VLOGW("MTVU change deferred: VM is running, takes effect on next game start");
		}

		if (MTGS::IsOpen())
		{
			MTGS::ApplySettings();
			const unsigned int width = s_pending_width.load();
			const unsigned int height = s_pending_height.load();
			if (width > 0 && height > 0)
			{
				MTGS::ResizeDisplayWindow(width, height, 1.0f);
				MTGS::UpdateDisplayWindow();
				VLOGI("display resize applied on CPU thread: %{public}ux%{public}u", width, height);
			}
			VLOGI("upscale multiplier applied on CPU thread: %{public}f", multiplier);
		}
		else
		{
			VLOGI("upscale multiplier staged: %{public}f (GS not open)", multiplier);
		}
	}

	void ApplyPendingConfigBeforeVM()
	{
		const float multiplier = s_upscale_multiplier.load();
		const AspectRatioType ar = ToPcsx2Mode(s_mode.load(), s_landscape.load());

		// VMManager::ApplySettings() rebuilds EmuConfig from the settings layer.
		// Apply the frontend value after that rebuild and before VMManager::Initialize()
		// opens GS.  This makes GSopen() receive the selected value on first creation,
		// instead of trying to repair the renderer after it is already running.
		GSConfig.AspectRatio = ar;
		EmuConfig.CurrentAspectRatio = ar;
		EmuConfig.GS.AspectRatio = ar;
		GSConfig.UpscaleMultiplier = multiplier;
		EmuConfig.GS.UpscaleMultiplier = multiplier;
		VLOGI("boot graphics config: upscale=%{public}f aspect=%{public}d landscape=%{public}d",
			multiplier, static_cast<int>(ar), s_landscape.load() ? 1 : 0);
	}

	float GetUpscaleMultiplier()
	{
		return MTGS::IsOpen() ? GSConfig.UpscaleMultiplier : s_upscale_multiplier.load();
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

		// ArkUI 的回调不在 PCSX2 CPU 线程。只记录尺寸；真正的
		// ResizeDisplayWindow/UpdateDisplayWindow 由 ApplyPendingSettingsOnCPUThread
		// 提交，避免 MTGS::RunOnGSThread 的跨线程断言和环形队列竞态。
		s_pending_width.store(width);
		s_pending_height.store(height);
		VLOGI("NotifyResize queued: %{public}ux%{public}u (landscape=%{public}d, orientation_changed=%{public}d)",
			width, height, landscape ? 1 : 0, orientation_changed ? 1 : 0);
		return true;
	}
}
