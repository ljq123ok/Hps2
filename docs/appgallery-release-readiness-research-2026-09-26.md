# Hps2 华为应用市场上架可行性研究

日期：2026-09-26
范围：只评估当前仓库版本形成华为应用市场发布包的条件，不修改代码，不代表华为最终审核结论。

## 结论摘要

当前版本可以继续准备“邀请测试/内部验证”材料，但还不能把现有调试包直接作为正式公开上架版本。关键原因不是 UI 或记忆卡功能，而是当前版本把 PS2 原生重编译 JIT 作为启动硬条件；仓库已有真机记录表明调试签名可用，而普通发布签名下 JIT 不可用。发布包若不能在 `normal_hap`/正式 Profile 下启动游戏，就不满足可提交的产品闭环。

这不是“华为一定拒绝模拟器”的结论。公开官方材料中没有检索到针对“PS2 模拟器”这一类别的明确禁止条款；但也没有材料证明第三方原生 JIT 可以按当前方案获得发布 ACL。最终仍要以 AGC 对具体场景、权限和资质的审核为准。

## 官方发布要求与当前项目对照

### 1. 包和签名

华为官方说明：正式分发需要在 AppGallery Connect 完成应用信息配置并上传应用软件包；发布单元是 `.app`，其中包含 HAP/HSP 和 `pack.info`，而 HAP 是安装和运行的基本单元。

- 官方流程：[提交 HarmonyOS 应用](https://developer.huawei.com/consumer/cn/app/submit/)
- 包格式说明：[应用程序包术语](https://developer.huawei.com/consumer/cn/doc/doccenter-getting-started/application-package-glossary)
- 签名说明：[自动签名/配置调试签名](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/ide-signing-auto)

官方签名文档明确指出：涉及受限 ACL 的应用，上架时 AGC 会按使用场景审核；不符合使用场景的上架申请会被驳回，而且当前只有少量特殊场景的应用可在审批后使用受限权限。

当前仓库情况：

- `app-hps2/build-profile.json5` 的工程版本为 `targetSdkVersion: 6.1.1(24)`、`compatibleSdkVersion: 6.0.0(20)`。
- `app-hps2/AppScope/app.json5` 当前版本是 `0.13`、`versionCode` 为 `1000013`。
- 签名材料不入库；仓库脚本当前用于本地调试签名，不等于 AGC 发布证书/Profile。
- `app-hps2/entry/src/main/module.json5` 当前没有声明受限权限。

### 2. JIT 是正式上架的首要技术门槛

OpenHarmony 官方 JIT 指导说明：JSVM 的 JIT 默认关闭；需要 JIT 时必须向 AGC 申请 `ohos.permission.kernel.ALLOW_EXECUTABLE_FORT_MEMORY` ACL，并说明在 JSVM 上使用 JIT 的理由。未取得权限证书却在配置中声明该权限会导致安装失败；“坚盾守护模式”还会对所有应用全局关闭 JIT。

- 官方指导（OpenHarmony 官方仓库）：[JSVM-API 申请 JIT 权限指导](https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/napi/jsvm-apply-jit-profile.md)
- 官方运行时说明：[ArkTS 运行时概述](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-runtime-overview)
- 项目已有证据：[docs/feasibility.md](feasibility.md)、[README.md](../README.md)

需要特别区分：官方文档描述的是 JSVM/ArkTS 引擎的 JIT 权限；Hps2 使用的是 ARMSX2/PCSX2 的原生 C++ EE/IOP/VU 重编译器。现有公开材料没有给出把 JSVM JIT ACL 扩展给任意原生 JIT 的路径。因此，当前“调试签名可运行、发布签名不可运行”的事实，不能通过在 `module.json5` 中自行添加 JIT 权限来解决。

发布前至少必须完成以下二选一：

1. 获得华为/AGC 对该原生 JIT 场景和所需权限的明确支持，并用正式发布 Profile 真机验证；或
2. 实现不依赖发布环境原生 JIT 的性能可接受降级路径，并用正式发布签名验证完整游戏启动。

在上述条件没有满足前，不能把当前包标为“可正式上架版”。

### 3. API/target SDK

华为 6.0.1 版本说明建议已升级应用适配对应 API 后，将 `targetSdkVersion` 配置为该版本；华为 7/API 26 升级指南则要求升级后评估 API 行为变化，并在旧、新设备上做兼容性测试后再发布。

- [HarmonyOS 6.0.1 版本说明与工程版本配置建议](https://developer.huawei.com/consumer/cn/doc/doccenter-release-notes/overview-601)
- [升级到 API 26.0.0 的应用升级与适配指南](https://developer.huawei.com/consumer/en/doc/harmonyos-releases/upgrade-adaptation)

官方公开材料未给出一个适用于所有 HarmonyOS 应用的统一“最低 targetSdkVersion 才能上架”数字。因此当前 API 24 本身不是已证实的硬性拒绝理由；但本项目的 `shareFiles`/文件管理器目录捐献能力是在更高 API/工具链上引入的，必须用与目标发布设备一致的 SDK、正式签名和真机重新验证，不能用 API 24 调试包代替发布证明。

### 4. 审核、测试和产品材料

华为发布页要求上架前进行漏洞、隐私、兼容性、稳定性和性能测试；提交前要准备应用名称、分类、图标、截图、视频、隐私声明链接等产品信息。应用（包含游戏）还需提供适用法律法规要求的资质文件。

- [提交 HarmonyOS 应用与上架准备](https://developer.huawei.com/consumer/cn/app/submit/)
- [华为应用市场](https://developer.huawei.com/consumer/cn/appgallery)
- [应用审核指南](https://developer.huawei.com/consumer/cn/doc/app/50104)
- [应用资质审核要求](https://developer.huawei.com/consumer/cn/doc/app/80301)
- [应用审核 FAQ](https://developer.huawei.com/consumer/cn/doc/app/50106)

华为应用市场页面还要求应用/游戏提供符合适用法律法规的资质文件；如果产品被按游戏业务处理，华为游戏中心公开流程还写明鸿蒙游戏正式提审前需要先通过线下验收，并准备版号、备案等材料。Hps2 是模拟器而不是被分发的 PS2 游戏，是否进入游戏分类、是否触发相应游戏资质，不能自行假定，应在 AGC 创建应用和提交前向华为确认。

- [华为游戏中心：游戏上架](https://developer.huawei.com/consumer/cn/game-center/)

## 版权和内容边界

仓库 README 已声明：HAP 不内置、不分发 BIOS 或游戏镜像，用户需要自行准备自己合法拥有的文件；项目源码基于 ARMSX2/PCSX2，并声明 GPL-3.0-or-later。这个方向是必要的，但不能替代上架所需的版权材料和开源履约。

发布前应形成可审计材料：

- Hps2 自有代码、图标、截图、宣传视频和名称的权利证明；
- ARMSX2/PCSX2 及所有随包第三方库的许可证、NOTICE、源码提供方式和修改说明；
- 明确不随包提供 Sony PS2 BIOS、商业游戏 ISO/CHD/BIN、破解补丁或下载链接；
- 应用内/详情页说明用户只能导入自己合法拥有或获授权的 BIOS、游戏镜像和存档；
- 若应用名称、图标、截图或示例画面出现第三方游戏标题/素材，准备授权或替换为自有/许可素材。

华为公开资料强调应用需遵守审核指南、法律法规并提交适用资质；未检索到“模拟器可以无条件免除版权/游戏资质”的官方例外。因此不能把“模拟器本身不分发游戏”理解为自动通过。

## 隐私、权限和文件管理

华为隐私标准要求：应用提供可访问的隐私政策；说明处理个人信息的目的、方式、范围和存储期限；列出个人信息和第三方共享清单；配置文件中逐项声明实际需要的权限。华为还说明第三方 SDK 的收集目的、方式和范围应在隐私政策中逐一明示。

- [HarmonyOS 标准隐私政策](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/standard-privacy-policy)
- [上架申请中的隐私说明](https://developer.huawei.com/consumer/cn/doc/system-Guides/app-release-0000001051075006)
- [权限与受限权限相关官方说明](https://developer.huawei.com/consumer/cn/doc/doccenter-tools-faq/faqs-compiling-and-building-232)

当前项目没有声明受限权限，并通过系统文件选择器导入 BIOS/镜像；这是较低风险的路线。仍需在发布包上验证：

- 首次启动、选择 BIOS、选择游戏、导入/导出存档时的告知和隐私政策入口可正常打开；
- 文件选择器拒绝、取消、超大文件、无效 BIOS/镜像时不会崩溃；
- 记忆卡目录对用户可复制/移动的承诺在正式签名、目标 API 和真实文件管理器上成立；
- 不采集账号、位置、设备标识、游戏镜像内容或存档内容；如未来增加 WebDev 同步/云存储，必须重新补充隐私政策、数据流、删除机制和第三方服务披露。

## 当前版本的上架判断

| 项目 | 当前判断 | 说明 |
|---|---|---|
| 本地调试/真机演示 | 可以 | 已有 API 26 arm64 真机验证记录，但属于调试签名边界。 |
| 邀请测试/内部测试 | 有条件 | 需要先生成与 AGC 应用绑定的测试签名包，并向测试审核如实说明限制。 |
| 正式公开上架 | 暂不可确认，当前不建议提交 | 正式签名下原生 JIT 启动链路未闭环；还缺正式 Profile、发布包、合规材料和完整兼容性/稳定性报告。 |
| 模拟器类别本身 | 未发现官方明文禁止 | 不能据此推断一定通过；BIOS、商业游戏内容、商标/截图、权限和发布 JIT 仍会被审核。 |

## 正式提交前的验收门槛

1. 使用 AGC 创建的正式应用、正式证书和 Release Profile，构建 `.app`，不再使用 debug HAP 作为发布证明。
2. 在至少一台目标 API 26 arm64 真机上，安装正式签名包，完成 BIOS 选择、游戏启动、画面、声音、输入、即时存档和 PS2 记忆卡读写全流程。
3. 若仍依赖原生 JIT，取得华为对权限/场景的书面或工单确认；否则完成可玩性能的无 JIT 降级路径。
4. 运行华为漏洞、隐私、兼容性、稳定性、性能测试，留存报告和崩溃日志。
5. 完成软件著作权/开发者资质/应用备案等 AGC 适用材料；对第三方开源组件完成许可证和源码履约。
6. 清理调试探针、测试存档和开发文案，确认发布包不包含 BIOS、商业游戏镜像或未授权素材。
7. 以最终详情页、隐私政策、权限声明和安装包一起提交邀请测试；根据审核意见再决定公开发布。

## 研究边界

本文件只使用华为开发者联盟、AppGallery Connect 相关官方页面，以及 OpenHarmony 官方文档说明 JIT 权限机制。应用市场审核具有个案性，网页规则可能更新；“能否最终上架”必须以 AGC 实际检测、资质审核和人工审核结果为准。
