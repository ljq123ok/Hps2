# 阶段 4 遗留问题：画面分辨率（vp/px）与内存分配

## 1. 当前状态

**游戏可正常启动并显示画面**（Codex 于 2026-09-16 修复 EGL 配置问题后）。

实测性能（真机）：
```
PerfLog: 111.1 fps | EE 100% GS 81% VU 0% GPU 1% | frame 17732
GL_RENDERER: Maleoon 935F
GL_VERSION:  OpenGL ES 3.2
```

| 指标 | 值 | 解读 |
|---|---|---|
| fps | 111 | 约 PS2 标准（59.94）的 1.85 倍 |
| EE | 100% | EE 线程跑满一核（关键路径，正常） |
| GS | 81% | **图形管线确实在工作** |
| GPU | 1% | GPU 占用低 → 瓶颈在 CPU 侧 |

## 2. 遗留问题 A：画面只在黑色区域左下角

**症状**：游戏画面仅占据显示区左下角一小块。

**已知数据**：
```
Host::AcquireRenderWindow: OHOS surface 408x158
GLContextEGLOHOS: using OHNativeWindow 0x5b993f77e0, surface 408x158
```

`408x158` 宽高比 **2.58:1**（PS2 应为 4:3 = 1.33:1）。

**推断（待实测确认）**：

OpenGL 视口原点在**左下角**；画面贴着左下角且偏小 ⇒ **视口小于实际缓冲区**。

GS 用 `WindowInfo.surface_width/height` 建立视口与 scissor
（`GSDeviceOGL.cpp:3390`）。若该值小于 EGL 实际缓冲区尺寸，就会出现此症状。

数值上：`onAreaChange` 返回的是 **vp（虚拟像素）**，
而 OHNativeWindow 的缓冲区是**物理像素**（本机缩放约 2.6x）。
408 × 2.6 ≈ 1071，与截图中黑色区的物理像素宽度量级吻合。

**已加入诊断**（`GLContextEGLOHOS::GetNativeWindow`）：
```cpp
int32_t buf_h = 0, buf_w = 0;
OH_NativeWindow_NativeWindowHandleOpt(window, GET_BUFFER_GEOMETRY, &buf_h, &buf_w);
// 打印 reported vs native buffer
```
> 注意 OHOS 文档写明 `GET_BUFFER_GEOMETRY` 的输出顺序是
> `[out] height, [out] width`，与直觉相反（Android 是 getWidth/getHeight）。

**待办**：读取实测的 `native buffer` 值，与 `reported 408x158` 对照，
确认是否为 vp/px 单位问题；若确认，则改为按物理像素上报。

## 3. 遗留问题 B：JIT 代码内存分配失败（本次出现）

**症状**：
```
ReportErrorAsync: Error: Failed to allocate code memory.
ReportErrorAsync: Error: Failed to allocate VM memory.
BOOT_ERROR=CPUThreadInitialize failed
```

**失败点**：`pcsx2/Memory.cpp:206` ——
`SharedMemoryMappingArea::Map(nullptr, 0, base, HostMemoryMap::CodeSize, ...)`

`HostMemoryMap::CodeSize = SWrecOffset + SWrecSize = 305 MB`（`Memory.h:90`）。

**与内存压力的关系**：

| 时刻 | MemFree | 结果 |
|---|---|---|
| Codex 修复后可运行 | （充足）| `code_generation=1`，正常 |
| 本次失败 | **仅 220–286 MB** | 305MB 连续映射失败 |

**判断**：这是**设备内存压力**导致的，不是代码回归 ——
本次唯一的代码差异是 `GetNativeWindow()` 里新增的
`GET_BUFFER_GEOMETRY` 诊断查询，它在 `CPUThreadInitialize` **之后**才执行，
不可能影响此前的内存分配。

**结论**：该失败与分辨率问题无关，属运行环境（设备可用内存）
问题。需在内存较空闲时复现验证，并在文档中记录为
"运行期资源条件"，与阶段 1 发现的"JIT 可用性是运行期属性"同类。

## 4. 下一步

1. 读取 `native buffer` 实测值，确认 vp/px 假设
2. 若确认 → 按物理像素上报 surface 尺寸（ArkTS 侧 `px2vp`/`vp2px` 换算）
3. 在内存空闲时重测，确认 JIT 内存分配恢复正常
4. 修好分辨率后重测性能（当前 111fps 是在画面尺寸错误下取得的，
   真实数字会不同）
