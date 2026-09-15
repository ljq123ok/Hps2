/*
 * Hps2 — 渲染表面在 native 层的共享状态。
 *
 * 为什么需要单独的头文件：
 *   ArkTS 侧通过 setSurface() 交出 surfaceId（在 napi_init.cpp 处理），
 *   而 GS 创建渲染设备时会调用 Host::AcquireRenderWindow()
 *   （在 hps2_host.cpp 处理）。两者在不同翻译单元，必须共享同一份状态。
 *
 * 数据流：
 *   ArkTS XComponent (surfaceId, w, h)
 *     → napi_init.cpp: setSurface()
 *     → OH_NativeWindow_CreateNativeWindowFromSurfaceId() → OHNativeWindow*
 *     → 本结构
 *     → hps2_host.cpp: Host::AcquireRenderWindow() 填 WindowInfo{type=OHOS}
 *     → GLContextEGLOHOS 交给 EGL
 */
#pragma once

#include <condition_variable>
#include <mutex>

namespace Hps2Surface
{
	// 由 ArkTS 提供、napi_init.cpp 写入
	extern std::mutex g_mutex;
	extern void* g_window;        // OHNativeWindow*（避免在头里引入 OHOS 头）
	extern int g_width;
	extern int g_height;
	extern bool g_ready;
	extern std::condition_variable g_cv;

	// 便捷查询：返回是否已有可用表面，并一次性取出所需字段
	struct Snapshot
	{
		bool ready = false;
		void* window = nullptr;
		int width = 0;
		int height = 0;
	};

	inline Snapshot Get()
	{
		std::lock_guard<std::mutex> lock(g_mutex);
		return Snapshot{g_ready, g_window, g_width, g_height};
	}
} // namespace Hps2Surface
