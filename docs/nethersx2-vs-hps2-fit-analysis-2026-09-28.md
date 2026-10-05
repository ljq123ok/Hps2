# NetherSX2 与 Hps2 的项目适配性比较

日期：2026-09-28  
结论对象：**“把谁作为 HarmonyOS / OpenHarmony 原生 PS2 模拟器的继续开发基础”**，不是 Android 手机上的单纯使用体验比较。

## 结论

**NetherSX2 不比当前 Hps2 更适合作为 HarmonyOS 移植基础。**

- 若目标是“在 Android 手机上马上玩”：NetherSX2 的前端、逐游戏设置、手柄配置、GameDB 和 Vulkan 使用经验明显更成熟，当前 Hps2 不能与其同日而语。
- 若目标是“继续做原生 HarmonyOS HAP”：应保留 **Hps2 + ARMSX2/PCSX2 开源源码**路线。NetherSX2 官方项目本质上是对 AetherSX2 Android APK 的补丁和重打包体系，不是可直接改目标平台、重新交叉编译的完整模拟器源码。
- 最合理的用法是：把 NetherSX2 当作**产品功能、默认设置和兼容性策略的参考样本**，不要把其 APK、DEX 或 `libemucore.so` 当作 Hps2 的代码基础。

目前没有同一台设备上的 Hps2/NetherSX2 A/B 测试，因此本文**不宣称 NetherSX2 在具体 HarmonyOS 设备上必然更快**。

## 关键事实对照

| 项目 | NetherSX2 | 当前 Hps2 | 对选择的影响 |
|---|---|---|---|
| 交付物 | Android APK；官方 README 直接提供 APK 下载 | HarmonyOS/OpenHarmony HAP | 目标平台不同 |
| 核心可编译性 | 官方仓库没有完整 Aether/Nether 模拟器工程；脚本下载/解包 APK，再修改资源、DEX 和二进制 | 从 ARMSX2 源码交叉编译 `PCSX2_CORE_STATIC`，再链接进 OHOS native 库 | Hps2 才具备可维护的 HarmonyOS 源码链 |
| 前端 | Android Manifest、DEX/Smali、Android 存储和 Activity | ArkTS/ArkUI + N-API + `OHNativeWindow` | Nether 前端不能直接移到 HAP |
| CPU/JIT | 使用 AetherSX2 APK 中现成的 ARM64 重编译器；官方补丁直接改 `libemucore.so` 固定偏移 | 使用 ARMSX2 的 EE/IOP/VU ARM64 JIT 源码，并已有 OHOS JIT 门禁/运行链 | Hps2 可调试和继续移植，Nether 二进制不可维护 |
| GPU | 已有 Android Vulkan/OpenGL 使用路径和大量设置经验 | 当前只接通 OpenGL；Vulkan 未接入 | Nether 是性能/设置参考，不是可直接复用的 OHOS 后端 |
| 产品成熟度 | 有逐游戏设置、输入配置、触控布局、多个存档槽、GameDB/手柄库更新 | 已有 BIOS/游戏运行、触控、即时存档、手柄等，但性能优化、Vulkan、MTVU 仍待做 | Android 成品体验 Nether 更强 |
| 许可证 | 补丁仓库根许可证为 Unlicense；但随 APK 附带的声明把 Aether app/glue、ARM64 recompiler/VM 标为 CC BY-NC-ND 4.0，并把 `libemucore.so` 单列为 LGPLv3 | Hps2/ARMSX2/PCSX2 源码路线为 GPL-3.0+ | 不能把补丁仓库的 Unlicense 误当成完整 Aether/Nether 代码授权 |

## 为什么 NetherSX2 不是完整开源移植底座

1. 官方 README 的目标是去广告残留、更新 GameDB/手柄数据库/宽屏补丁、暴露设置并重新签 APK；下载区交付的也是 APK。  
   来源：[NetherSX2 README（固定提交）](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/README.md#L5-L17)、[下载与版本说明](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/README.md#L30-L52)。

2. 官方旧构建脚本会下载 `15210-v1.5-4248.apk`，用 xdelta 生成补丁版，再用 `aapt` 替换 APK 内资源并重新签名；这不是从模拟器 C/C++ 与 Android 前端源码编译。  
   来源：[patch-apk.sh](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/old/scripts/patch-apk.sh#L17-L51)、[资源替换](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/old/scripts/patch-apk.sh#L53-L117)。

3. 当前仓库的反编译流程使用 apktool；核心修改是按固定字节偏移修改 `lib/arm64-v8a/libemucore.so`，并按固定偏移修改 `classes.dex`。  
   来源：[Extract.bat](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/decomp/Extract.bat)、[Hackify.bat](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/decomp/Hackify.bat#L24-L40)、[Pack.bat](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/decomp/Pack.bat)。

因此，仓库中“有补丁源码”不等于“有 AetherSX2/NetherSX2 完整源码”。没有可重新编译的 Android glue、VM/JIT 全部源代码与平台抽象，就不能把目标从 Android 改成 OHOS。

## 许可证与分发边界

NetherSX2 补丁仓库自己的 `LICENSE` 是 Unlicense；但该仓库随应用提供的 Third Party Notices 明确区分了不同部分：

- AetherSX2/NetherSX2 app 与 Android glue、ARM64 recompiler/VM management：CC BY-NC-ND 4.0，包含“非商业”和“不得分发演绎版本”的限制；
- `libemucore.so`：单列 LGPLv3，并给出 LGPL 源码入口。

来源：[仓库 Unlicense](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/LICENSE)、[NetherSX2 FAQ 许可声明](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/assets/faq.html#L12-L20)、[Third Party Notices](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/assets/3rdparty.html#L4-L24)。

这意味着：**不能因为补丁脚本是 Unlicense，就推导出 Aether/Nether 整个 APK 可以作为新的 HarmonyOS 产品源码自由移植和分发。** 若要发布基于其 app/glue 或闭源二进制改造的 HAP，至少存在明显的 NoDerivatives、NonCommercial 和源代码可得性风险。本段是工程许可风险判断，不是法律意见；正式商业分发仍应由专业法律人员确认。

相比之下，Hps2 明确采用 ARMSX2/PCSX2 的 GPL-3.0+ 源码路线（本地 `README.md:103-113`）；ARMSX2 官方仓库公开 ARM64 JIT 源码，并说明 EE、IOP、VU 和 vtlb fast memory 的状态。  
来源：[ARMSX2 README](https://github.com/ARMSX2/ARMSX2/blob/75e095e82b048080b76901af816aae75bfd713bf/README.md#L1-L25)、[ARMSX2 COPYING.GPLv3](https://github.com/ARMSX2/ARMSX2/blob/75e095e82b048080b76901af816aae75bfd713bf/COPYING.GPLv3)。

## 技术上为什么不能“直接移植”

NetherSX2 的可执行内容面向 Android：`AndroidManifest.xml`、Activity、DEX/Smali、`/storage/emulated/0`、`arm64-v8a/libemucore.so` 和 APK 签名流程。Hps2 面向 OHOS：

- 本地 `app-hps2/entry/src/main/cpp/CMakeLists.txt:82-97` 定义 `__OHOS__` / musl 环境；
- 同文件 `102-114` 构建 Hps2 N-API native 层，`123-153` 链接 ARMSX2/PCSX2 静态核心；
- 同文件 `155-185` 链接 OHOS 的 `libace_napi`、`native_window`、EGL、GLESv3 和音频/HTTP 系统库；
- 本地 `app-hps2/entry/src/main/cpp/napi_init.cpp:1408-1462` 把 ArkUI XComponent 转换为 `OHNativeWindow`；
- ArkTS 前端位于 `app-hps2/entry/src/main/ets/`，不是 Android Activity/Compose/XML 前端。

即使两者都是 ARM64，Android 的 ABI、系统库、窗口、音频、输入、存储、生命周期和包格式也不等于 OHOS。抽取 NetherSX2 的 Android `.so` 无法替代这些平台适配，更无法解决 Hps2 当前的 HarmonyOS debug/release 签名 JIT 差异。

## 性能、GPU 与前端成熟度

NetherSX2 在 Android 上更成熟是有一手资料支撑的：其 FAQ 提供 Vulkan/OpenGL、Mali/Adreno、Threaded Presentation、MTVU/affinity、GS readback 等调优建议，也提供触控布局、手柄映射、逐游戏设置和输入 Profile。  
来源：[NetherSX2 性能 FAQ](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/assets/faq.html#L22-L60)、[控制与逐游戏设置](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/assets/faq.html#L63-L105)。

但官方 FAQ 对“是否更快”的回答本身也是 **It depends**：项目优先稳定性和兼容性，GameDB 改动可能提高也可能降低特定游戏性能。它不能替代 Hps2 在同机、同游戏、同分辨率下的基准。  
来源：[NetherSX2 FAQ：Does NetherSX2 run faster](https://github.com/Trixarian/NetherSX2-patch/blob/f5f89b3b76e89a8f684da91cf5ad6e542825c0cb/assets/faq.html#L22-L27)。

Hps2 的本地 README 记录了目前的真实差距：已验证 OpenGL、触控与游戏运行，但性能优化未做，Vulkan 未接入、MTVU 等多核优化关闭（`README.md:117-146`）。所以目前可合理说：

- **Android 成品体验/兼容性：NetherSX2 更成熟。**
- **HarmonyOS 原生可维护性：Hps2/ARMSX2 明显更合适。**
- **纯性能高低：无同机真机数据，暂不能下最终结论。**

## 建议路线

1. 不更换 Hps2 的核心基础，继续使用 ARMSX2/PCSX2 源码。
2. 从 NetherSX2 提炼“要实现什么”：逐游戏设置、GameDB 更新、输入 Profile、Vulkan 默认策略、Mali/Adreno 分档、GS readback 选项、存档/导入体验。
3. 具体代码实现优先参考**当前 ARMSX2 官方开源 Android 前端和 PCSX2 上游**，因为它们有可编译源码和 GPL 许可链。ARMSX2 官方已提供 Android APK 构建说明与完整 Android 工程，可作为行为和架构参考，但仍需重写为 ArkTS/OHOS 平台层。  
   来源：[ARMSX2 Android README](https://github.com/ARMSX2/ARMSX2/blob/75e095e82b048080b76901af816aae75bfd713bf/platforms/android/README.md#L1-L28)、[ARMSX2 Android source tree](https://github.com/ARMSX2/ARMSX2/tree/75e095e82b048080b76901af816aae75bfd713bf/platforms/android/app/src/main)。
4. 在没有真机期间，只完成可由构建、主机测试或模拟器证明的工作；JIT、Vulkan 驱动差异、温控和真实 FPS 继续标记为 `pending_device`。

一句话决策：**想做 Android 成品就用 NetherSX2；想把你的项目做成原生 HarmonyOS 模拟器，就继续 Hps2/ARMSX2，并把 NetherSX2 当参照物，不要当移植底座。**
