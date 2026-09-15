# 阶段 4：图形接入（出画面）—— 工作量评估

**目标**：让 PS2 游戏画面真实显示在 HAP 窗口中。

---

## 1. 必须打通的链路

```
ArkTS/XComponent  →  OHNativeWindow  →  VkSurface (vkCreateSurfaceOHOS)
                                            ↓
                    PCSX2 GS  →  GSDeviceVK  →  Vulkan 渲染  →  窗口呈现
                                            ↑
                             shaderc（GLSL → SPIR-V 编译）← ⚠️ 关键阻塞
```

## 2. 已确认的平台能力（好消息）

| 组件 | 状态 | 证据 |
|---|---|---|
| Vulkan 头文件 | ✅ | `sysroot/usr/include/vulkan/`（含 `vulkan_core.h`）|
| **OHOS Vulkan 扩展** | ✅ | `vulkan_ohos.h` 提供 `vkCreateSurfaceOHOS` / `VkSurfaceCreateInfoOHOS` |
| Vulkan 版本 | ✅ | `VK_HEADER_VERSION 309`（Vulkan 1.4）|
| libvulkan | ✅ | `sysroot/usr/lib/aarch64-linux-ohos/libvulkan.so` |
| 原生窗口 | ✅ | `sysroot/usr/include/native_window/external_window.h` |
| ArkTS XComponent | ✅ | 标准 UI 组件，可导出 `OHNativeWindow` |

**OHOS 的 Vulkan 支持是完整的**，且提供了专门的 OHOS 扩展用于窗口绑定。

## 3. 🔴 关键阻塞：shaderc

| 项 | 结果 |
|---|---|
| `sysroot` 是否提供 shaderc | ❌ 无 |
| `sysroot` 是否提供 glslang | ❌ 无 |
| 设备是否提供 `libshaderc` | ❌ 无（`/system/lib64/` 下无）|

PCSX2 的 Vulkan 后端**必须**编译 GLSL 着色器：

```cpp
// VKShaderCache.cpp:22
#include "shaderc/shaderc.h"

// VKShaderCache.cpp:103
#if defined(__ANDROID__) || defined(ARMSX2_LINK_SHADERC)
    // 静态链接：直接调用
#else
    // 动态加载：运行时 dlopen("shaderc_shared")
#endif
```

两条路径都需要 shaderc 存在：
- 静态链接 → 需**自行交叉编译** shaderc 的 ARM64 版本
- 动态加载 → 需设备上**存在**该库（实测不存在）

**因此：必须自行交叉编译 shaderc（含 glslang + SPIRV-Tools）。**

上游原话（`pcsx2/CMakeLists.txt:795`）也印证了这一困难：

> VKShaderCache.cpp calls shaderc directly on Android, where every other
> platform links its own vendored `shaderc` target... stopped on twenty
> undefined `shaderc_*` symbols without this.

## 4. 工作量分解

| # | 任务 | 规模 | 说明 |
|---|---|---|---|
| 1 | 交叉编译 shaderc（ARM64/OHOS） | **大** | shaderc 依赖 glslang + SPIRV-Tools，构建体系复杂（原用 Python 脚本驱动，交叉编译需绕开）|
| 2 | 启用 `USE_VULKAN` 重新配置核心 | 中 | 需处理之前为规避而关闭的配置 |
| 3 | ArkTS 侧加 XComponent | 中 | 取得 `OHNativeWindow` 并传给 native |
| 4 | `VkSurface` 创建（`vkCreateSurfaceOHOS`） | 中 | 需与 PCSX2 的 GS 窗口层对接 |
| 5 | 打通 PCSX2 的窗口抽象 | **大** | PCSX2 的 GS 假定桌面窗口模型，需适配 OHOS |
| 6 | 渲染器切到 Vulkan 并调试 | 大 | 首次运行时大概率遇到多个问题 |

**评估：这是本项目目前最大的一块工作**，且第 1 项（shaderc 交叉编译）
本身就是一个独立的中等规模任务。

## 5. 建议的推进方式

分步验证，每步可独立验收，避免一次性堆到最后：

- **4.1** 交叉编译 shaderc → 产出 ARM64 `libshaderc.a`（可独立验证）
- **4.2** 启用 Vulkan 重新配置/编译核心（验证能编过、能链接）
- **4.3** ArkTS XComponent + OHNativeWindow 打通（验证能拿到窗口句柄）
- **4.4** `vkCreateSurfaceOHOS` 创建 surface（验证 Vulkan 认这个窗口）
- **4.5** 接入 GS 渲染并出画面（最终目标）

> ⚠️ 每一步都可能暴露新的平台差异。考虑到此前已遇到
> "Apple 假设当 ARM64 通用"（页大小/缓存行/preserve_all）这类系统性问题，
> 图形栈很可能还有同类坑。

---

## 6. 官方 API 调研结论（用户要求"先看有没有官方 API 支持"）

### 6.1 OHOS 官方图形能力（实测 sysroot + 设备）

| 能力 | 证据 | 状态 |
|---|---|---|
| **EGL** | `sysroot/usr/include/EGL/eglplatform.h:55` `typedef void *EGLNativeWindowType`；`libEGL.so` | ✅ |
| **OpenGL ES 3.x** | `sysroot/usr/include/GLES3/gl32.h`；`libGLESv3.so` | ✅ |
| **Vulkan** | `sysroot/usr/include/vulkan/`（VK_HEADER_VERSION 309 = **Vulkan 1.4**）；`libvulkan.so` | ✅ |
| **OHOS Vulkan 扩展** | `vulkan_ohos.h`：`vkCreateSurfaceOHOS` / `VkSurfaceCreateInfoOHOS` / `OHNativeWindow` | ✅ |
| **原生窗口** | `native_window/external_window.h`：`OH_NativeWindow_NativeWindowHandleOpt`（含 `SET_BUFFER_GEOMETRY`）| ✅ |
| **shaderc / glslang** | sysroot 与设备 `/system/lib64/` 均无 | ❌ |

**结论：OHOS 对 OpenGL ES 与 Vulkan 都有官方原生支持**，平台层不是阻塞。

### 6.2 两条后端路径的阻塞差异（关键发现）

| | Vulkan 后端 | **OpenGL 后端** |
|---|---|---|
| 是否需要 shaderc | **✅ 强制需要** | **❌ 不需要** |
| 证据 | `VKShaderCache.cpp:22` `#include "shaderc/shaderc.h"` | `grep shaderc Renderers/OpenGL/*.cpp` → **零命中** |
| 上游现成参照 | 无 | **`GLContextEGLAndroid.cpp`** ✅ |
| 平台阻塞 | shaderc 需自行交叉编译 | 无 |

### 6.3 Android EGL 实现可直接仿照（OpenGL 路径）

上游已有 `GLContextEGLAndroid`，接口极小（4 个方法）：

```cpp
class GLContextEGLAndroid final : public GLContextEGL {
    static std::unique_ptr<GLContext> Create(const WindowInfo&, const Version*, size_t);
    std::unique_ptr<GLContext> CreateSharedContext(const WindowInfo&, Error*) override;
    void ResizeSurface(u32 = 0, u32 = 0) override;
protected:
    EGLNativeWindowType GetNativeWindow(EGLConfig config) override;
};
```

其 `GetNativeWindow` 做的事，与 OHOS API 一一对应：

| Android | OHOS 对应 |
|---|---|
| `eglGetConfigAttrib(..., EGL_NATIVE_VISUAL_ID, ...)` | 同（EGL 通用）|
| `ANativeWindow_setBuffersGeometry(w, 0, 0, visual_id)` | `OH_NativeWindow_NativeWindowHandleOpt(w, SET_BUFFER_GEOMETRY, ...)` |
| `ANativeWindow_getWidth/Height()` | `OH_NativeWindow_NativeWindowHandleOpt` / `OH_NativeWindow_GetSurfaceId` |
| `EGLNativeWindowType` = `void*` | 同为 `void*` |

### 6.4 需要的集成点（已定位）

1. `common/WindowInfo.h:12` 的 `Type` 枚举需加 `OHOS` 项
   （现有：Surfaceless / Win32 / X11 / Wayland / MacOS / Android / VulkanDirect）
2. `GLContext::Create`（`GLContext.cpp:42-110`）需加 OHOS 分派分支
3. 新增 `GLContextEGLOHOS.{h,cpp}`（仿 `GLContextEGLAndroid`）
4. Vulkan 侧：`GSDeviceVK` 的 surface 创建需走 `vkCreateSurfaceOHOS`

## 7. 用户决策：**OpenGL 与 Vulkan 都必须能正常渲染**

因此 shaderc 无法绕开 —— 它是 Vulkan 后端的硬前提。已在推进：

- shaderc + glslang + SPIRV-Tools + SPIRV-Headers 源码获取中
- 目标：交叉编译出 ARM64/OHOS 的 `libshaderc.a`

**推进顺序**（先易后难，尽早可见成果）：

| 步 | 任务 | 阻塞 |
|---|---|---|
| 1 | OpenGL ES 路径（无 shaderc 依赖）| 无 |
| 2 | shaderc 交叉编译 | 无（源码可获取）|
| 3 | Vulkan 路径 | 依赖步 2 |
