# HPS2 v0.14 P2：图形可行性与性能验收

## Vulkan 范围

OpenGL/EGL/GLES 是当前默认图形路径，保持现状。P2 先验证 HarmonyOS Vulkan 平台连接，不接入 PCSX2 GS，不改变默认后端，也不移除 OpenGL。

阶段验收顺序：

1. CMake 能找到目标设备 ABI 的 Vulkan loader、头文件和 shaderc/SPIR-V 工具链。
2. 真机创建 Vulkan instance 并枚举 physical device，记录厂商、型号和 API 版本。
3. 通过 OH_NativeWindow 建立 surface、队列和 swapchain；覆盖尺寸改变、横竖屏、前后台和 surface 重建。
4. 清屏并在真机看到稳定画面；重复进入/退出 20 次无泄漏或崩溃。
5. 只有以上独立 demo 通过后，另行评估 GS backend 接入。

对 HX360E 的源码只抽取平台层参考：`entry/src/main/cpp/napi_init.cpp` 注册 XComponent 创建/变化/销毁回调，经 `CreateNativeWindowFromSurfaceId` 获得 `OHNativeWindow`，再交给 Xenia 的 OhosWindow；`vulkan_context.cpp` 创建 Vulkan surface、physical/logical device、swapchain 与 image views，记录 GPU/driver/API 信息。surface resize 回调通知 `OnSurfaceResized()`，`ohos_emulator.cc` 在 UI thread 调用 `OhosWindow::UpdateSurface()`。GamePage 还记录了页面离场和 surface 拆除顺序对崩溃的影响。这些可作为 surface/lifecycle/rebuild 检查清单；不复用 Xenia renderer、资源绑定或命令提交逻辑。仓库 README 称其呈现采用 `OH_NativeWindow + Vulkan`，源码结构与此相符，但本次只是静态检查，没有重新构建或在真机复测 HX360E。

本机 DevEco sysroot 有 `vulkan/vulkan.h`、`vulkan_ohos.h` 和 arm64 `libvulkan.so`；一个只调用 `vkEnumerateInstanceVersion` 的 OHOS AArch64 shared-library smoke probe 已交叉编译并链接通过。仓库内有 shaderc/SPIRV 源码，但第三方构建脚本尚未编译它们，HPS2 CMake 仍配置 `USE_VULKAN=OFF`。入口仍由 `hps2_surface`/EGL/OpenGL 负责，未发现 HPS2 Vulkan instance、surface 或 swapchain 实现。因此 Vulkan 系统 API/loader 的本地 ABI 编译链接已确认，shaderc/SPIR-V 工具链和真机 surface/display 仍未验证；该 smoke probe 未安装或运行在真机，本轮没有声称 Vulkan 已出图。OpenGL 回归必须持续通过。

## 固定性能基准

使用同一台真机、同一系统版本、同一游戏存档、同一场景、同一供电/散热条件。每个设置预热 5 分钟，记录其后连续 10 分钟；每种组合重复三次。不得将不同场景的数字直接比较。

| 游戏/负载 | 渲染倍率 | FPS | speed% | EE% | GS% | VU% | GPU% | EE ms | GS ms | 内存 | 温度 | 功耗 | 设备/系统/构建 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 暴走山地自行车（汉化v1.1）开机+骑行 | 1x | 49.9 | 100.0 | 38 | 40 | 0 | 10 | 7.67 | 7.94 | 不可读 | 不可读 | 不可读 | Pura X Max / API26 / 349b857 |
| 暴走山地自行车（汉化v1.1）开机+骑行 | 2x | 待测 | | | | | | | | | | | |
| 暴走山地自行车（汉化v1.1）开机+骑行 | 3x | 49.9 | 100.0 | 52 | 41 | 0 | 9 | 10.23 | 8.21 | 不可读 | 不可读 | 不可读 | Pura X Max / API26 / 349b857 |
| 中负载（填写标题/场景） | 1x | 待测 | | | | | | | | | | | |
| 中负载（填写标题/场景） | 2x | 待测 | | | | | | | | | | | |
| 中负载（填写标题/场景） | 3x | 待测 | | | | | | | | | | | |
| 重负载（填写标题/场景） | 1x | 待测 | | | | | | | | | | | |
| 重负载（填写标题/场景） | 2x | 待测 | | | | | | | | | | | |
| 重负载（填写标题/场景） | 3x | 待测 | | | | | | | | | | | |

> **采样强度说明（与上方"固定性能基准"的差异）**
> 上表 1x / 3x 两行是**快速采样**，不是该方法要求的完整基准：
> 每档预热约 25 s、记录 60–70 s、仅 1 次（要求：预热 5 min、记录 10 min、重复 3 次）。
> 采样方式：`hilog` 抓取 `PERF:` 行，丢弃前 10% 后取中位数；3x 样本 36 条、1x 样本 162 条。
> 用途是**判断瓶颈方向**，不用于发布或与其它设备比较。2x 未测。
>
> **已知局限**
> - 场景为"开机后骑行"，非脚本化固定场景；两次采样的骑行片段不完全可比。
> - 1x 的 min=13.7 FPS 是过场/加载帧，非稳态值（median 才代表稳态）。
> - 内存 / 温度 / 功耗按本机能力**不可读**，未估算。
> - VU 恒为 0%：该列是 **VU1 独立线程**的 CPU 占用
>   （`PerformanceMetrics.cpp:358`：`THREAD_VU1 ? vu1Thread.GetThreadHandle().GetCPUTime() : 0`）。
>   本次采样的构建里 `THREAD_VU1` 未生效，故恒为 0，**该列无区分度**，
>   不能据此说"VU 不耗时"。
>
> ⚠️ **这两行数据不能用于判断性能瓶颈**
>
> 1x 与 3x 都跑满 50 FPS（PS2 PAL 上限）且 speed=100%，EE 最高仅 52%、
> GPU 仅 9–10% —— 即**该负载没有让模拟器受压**，各项占用都有大量余量。
>
> 因此"3x 时 EE 从 38% 升到 52%"只能说明提高倍率增加了 EE 的负担，
> **不能**推断重负载下瓶颈就在 EE。要定位真实瓶颈，必须用能让
> speed 掉到 100% 以下的更重负载（开放场景/高负载游戏）重测。
>
> 同理，"GPU 仅 9–10%"也不能作为"Vulkan 不重要"的依据 ——
> 它只说明这份负载的 GPU 压力很小。

内存、温度和功耗拿不到系统可靠读数时写“不可读”，不要估算。OpenGL 和未来 Vulkan 必须使用相同测试条件。Vulkan 未实现前没有 Vulkan 对比数据。

## JIT 写保护统计

运行期 `PERF:` 日志现在额外输出每秒 `BeginCodeWrite`、`EndCodeWrite`、`HostSys::MemProtect` 计数，以及累计 mprotect 次数、失败数、平均和最大耗时。OHOS/Linux 上 begin/end 是写代码窗口次数，不等于精确 JIT block 数。源码有 VU 持久化统计的 block compile count，但没有统一 EE/IOP/VU 运行期 block/sec 接口；本轮不改 recompiler 热路径去拼易误导的近似数字。需要精确且全域可比的 block/sec 时另做受控 profiling build。

基准结论需引用实际 `PERF:` 日志。若 mprotect 频率和累计耗时都低，不改 CodeCache；只有占比足以解释帧时间瓶颈时，才另开实验评估 memfd backend。memfd scratch PASS 仅说明该映射形态能工作，不证明核心 CodeCache 应切换。

## 现阶段验收状态

- Vulkan native instance/swapchain/clear：未实现、待独立可行性样例。
- OpenGL 默认路径：保持。
- 多游戏 x1/x2/x3 基准：模板已建，真机数据待采集。
- JIT protection 统计：代码已接入；数值待真机 PERF 日志。
