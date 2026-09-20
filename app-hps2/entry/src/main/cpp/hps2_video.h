/*
 * Hps2 — 画面显示控制（宽高比 + 旋转适配）
 *
 * 解决的问题：用户要求「横竖屏都要支持」，且「虚拟按键或手柄都要能全屏显示」。
 *
 * 机制依据（均已核实，非推测）：
 *
 * 1) 宽高比由 AspectRatioType 控制（pcsx2/Config.h:224）。
 *    GSRenderer.cpp:412 的 CalculateDrawDstRect 里：
 *        float targetAr = clientAr;          // 默认 = 窗口比例
 *        if (... RAuto4_3_3_2) targetAr = 4/3;
 *        else if (... R4_3)    targetAr = 4/3;
 *        ...
 *    而 Stretch **不在任何分支里** => targetAr 保持窗口比例 => **铺满窗口**。
 *    所以全屏只需改配置，不必动渲染器。
 *
 * 2) 运行期改尺寸必须用 MTGS::ResizeDisplayWindow(w, h, scale)
 *    （MTGS.h:73），它经 RunOnGSThread 投递到 GS 线程。
 *    仅改 surface 尺寸不够 —— GS 的正交投影是 GSDeviceOGL 用
 *    WindowInfo.surface_width/height 计算的（本项目在此踩过坑，
 *    见 docs/stage4-resolution-issue.md）。
 *
 * 3) 配置变更走 MTGS::ApplySettings()（MTGS.h:72），
 *    它会拿当前 GSConfig 重新配置渲染器。
 */
#pragma once

namespace Hps2Video
{
	/// 画面比例策略。数值与 ArkTS 侧约定一致，勿随意调整。
	enum class AspectMode : int
	{
		Auto = 0,      // 自动：横屏铺满、竖屏保持 4:3（默认，见说明）
		Keep4_3 = 1,   // 始终 4:3，不变形（黑边放虚拟按键）
		Stretch = 2,   // 始终铺满，接受变形
		Wide16_9 = 3,  // 16:9（适合有宽屏补丁的游戏）
	};

	/// 设置画面比例模式并立即生效。返回 true 表示已应用。
	bool SetAspectMode(AspectMode mode);

	/// 读取当前模式。
	AspectMode GetAspectMode();

	/// 设置内部渲染倍率（1.0 为原生分辨率）。运行时记录为待应用值，
	/// 由 VM CPU 线程安全应用，避免从 ArkUI 线程直接调用 MTGS。
	bool SetUpscaleMultiplier(float multiplier);

	/// 在 VM CPU 线程调用，把待应用倍率提交给 GS。
	void ApplyPendingSettingsOnCPUThread();

	/// 在 VMManager::ApplySettings() 之后、VMManager::Initialize() 之前调用。
	/// 此时 GS 尚未打开，只写入启动配置，保证 GS 第一次创建时就使用前端选择的倍率。
	void ApplyPendingConfigBeforeVM();

	/// 读取当前内部渲染倍率。
	float GetUpscaleMultiplier();

	/// 屏幕方向变化后调用：把新的窗口尺寸通知 GS，让它重建视口与投影。
	///
	/// 为什么必须调：GS 的正交投影与视口是用 WindowInfo 的尺寸算的
	/// （GSDeviceOGL.cpp:3390）。旋转后若只改 surface 尺寸而不通知 GS，
	/// 画面会错位或只占一角 —— 这正是本项目已经踩过的坑。
	///
	/// 必须在 GS 线程上下文可用后调用（即 VM 启动后）。
	bool NotifyResize(unsigned int width, unsigned int height);

	/// 根据当前方向与模式，返回"应该使用"的具体宽高比模式。
	/// 用于「自动」模式下按横竖屏选择。
	AspectMode ResolveForOrientation(bool landscape);
}
