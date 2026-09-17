# OHOS EGL / NativeWindow format 查证记录

日期：2026-09-16

## 结论

当前 `GLContextEGLOHOS::GetNativeWindow()` 不应把 `EGL_NATIVE_VISUAL_ID` 直接作为
`SET_FORMAT` 的参数。第一修复候选是移除 `SET_FORMAT`，也一并移除未经 OHOS 文档确认的
`SET_BUFFER_GEOMETRY(window, 0, 0)`，让 `eglChooseConfig()` 选择窗口渲染配置，再直接调用
`eglCreateWindowSurface()`。

这份结论可以解释并规避本轮崩溃，但在没有设备的情况下，不能宣称已经证明了该机型的
EGL 配置与 XComponent 默认 NativeWindow 格式一定兼容。

## 官方契约

1. OpenHarmony `external_window.h` 定义：
   - `GET_FORMAT` 的输出值属于 `OH_NativeBuffer_Format`；
   - `SET_FORMAT` 的输入值也必须属于 `OH_NativeBuffer_Format`；
   - `SET_BUFFER_GEOMETRY` 的输入是 `width`、`height`；
   - `OH_NativeWindow_NativeWindowHandleOpt()` 的可变参数必须与操作码一一对应。
   见 [OpenHarmony external_window.h](https://raw.githubusercontent.com/openharmony/interface_sdk_c/master/graphic/graphic_2d/native_window/external_window.h)，尤其是操作码定义和函数注释。

2. OpenHarmony `OH_NativeBuffer_Format` 的枚举从 0 开始连续定义：
   `CLUT8=0`、`CLUT1=1`、`CLUT4=2`、`RGB_565=3`，随后是 RGB/RGBA/BGR/BGRA
   格式。因此在当前公开头文件中，`RGBX_8888=11`、`RGBA_8888=12`、
   `RGB_888=13`；但代码应使用枚举名，不应硬编码数字。
   见 [OpenHarmony buffer_common.h](https://raw.githubusercontent.com/openharmony/interface_sdk_c/master/graphic/graphic_2d/native_buffer/buffer_common.h)。

3. Khronos EGL 规范把 `EGL_NATIVE_VISUAL_ID` 定义为 native visual 的标识符，且明确其
   解释是平台相关的；它不是跨平台保证等于某个操作系统像素格式枚举的通用转换接口。
   见 [EGL 1.5 specification](https://registry.khronos.org/EGL/specs/eglspec.1.5.pdf)，
   配置管理的 `EGL_NATIVE_VISUAL_ID` 段落。

4. OpenHarmony 官方 OpenGL ES 文档的 XComponent/NativeWindow 示例在获取窗口后直接
   调用 `eglCreateWindowSurface()`，没有把 `EGL_NATIVE_VISUAL_ID` 传给
   `SET_FORMAT`。同一文档还说明 `EGL_BAD_MATCH` 只能作为“窗口与 EGL 配置不兼容”的
   线索，不能据此推导出必须调用 `SET_FORMAT`。
   见 [OpenHarmony OpenGL ES 文档](https://github.com/openharmony-rs/openharmony-docs/blob/master/en/application-dev/reference/native-lib/opengles.md)。

## 本地代码事实

- `upstream/ARMSX2/pcsx2/GS/Renderers/OpenGL/GLContextEGLOHOS.cpp` 当前未提交修改在
  `GetNativeWindow()` 中调用：
  `OH_NativeWindow_NativeWindowHandleOpt(window, SET_FORMAT, native_visual_id)`。
- 随后的 `upstream/ARMSX2/pcsx2/GS/Renderers/OpenGL/GLContextEGL.cpp` 会把返回的同一窗口
  传给 `eglCreateWindowSurface()`。
- Android 对照代码使用 `ANativeWindow_setBuffersGeometry(..., visual_id)`，但 Android
  API 的保证不能自动移植到 OHOS；两者的参数类型/编号契约不同。

## 建议的代码变更

先做最小安全修复：

1. 删除 OHOS `GetNativeWindow()` 中查询 `EGL_NATIVE_VISUAL_ID` 的代码。
2. 删除 `SET_FORMAT` 调用。
3. 删除 `SET_BUFFER_GEOMETRY(window, 0, 0)` 调用；官方 OHOS 头文件只定义了其输入为
   宽高，没有在该接口契约中定义 Android 式“0 表示保持当前尺寸”。XComponent 已经提供
   了窗口尺寸，当前代码也已从回调保存 `m_wi.surface_width/height`。
4. 保留空窗口检查、尺寸日志，最后直接返回 `OHNativeWindow*`。
5. 让现有 `eglCreateWindowSurface()` 负责创建窗口 EGL surface。

不要把 `12` 作为长期修复写进代码。若设备验证后确实需要主动设置格式，应先通过
`GET_FORMAT` 读取窗口当前格式，并确认该值与候选 `EGLConfig` 的
`EGL_NATIVE_VISUAL_ID` 在该设备实现中确实一一对应；只有在这个运行时证据成立时，才
考虑使用 `SET_FORMAT(window, static_cast<int32_t>(NATIVEBUFFER_PIXEL_FMT_RGBA_8888))`，并
且检查返回值，失败不能继续当作成功。

## 设备接回后的最小验证

按下面顺序只改一个变量：

1. 版本 A：不调用 `SET_FORMAT`，不调用 `SET_BUFFER_GEOMETRY(0,0)`，直接创建 EGL window
   surface；记录所有候选 config 的 `EGL_CONFIG_ID`、`EGL_NATIVE_VISUAL_ID`、RGB/A 位数、
   `eglCreateWindowSurface()` 错误码。
2. 若 A 返回 `EGL_BAD_MATCH`：调用 `GET_FORMAT` 读取 OHOS 窗口格式，再记录它与上述
   `EGL_NATIVE_VISUAL_ID` 的实际关系；不要立即写回窗口。
3. 只有确认两套值在该设备上相等且属于支持的 `OH_NativeBuffer_Format` 后，才做版本 B：
   使用明确的 `OH_NativeBuffer_Format` 枚举值调用 `SET_FORMAT`，随后重新创建 surface。
4. 每次调用都记录返回值；出现 `SET_FORMAT failed` 时立刻停止这条路径，不再让 EGL 继续
   使用可能已被底层拒绝的窗口状态。

## 其他探针结论

SMT/大小核部分应标记为“当前内核拓扑字段不可判定”，不能写成 `smt=NO`。这与 EGL 修复
无关，后续应通过各 CPU 绑定线程的实测吞吐/延迟差异来补证据。
