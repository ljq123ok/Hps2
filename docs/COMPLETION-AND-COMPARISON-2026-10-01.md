# Hps2 完成度分析：对照安卓 PS2 模拟器

**日期**：2026-10-01
**版本**：v0.13（`versionCode` 1000013）
**方法**：全部数字来自对**本仓库代码**与**同源安卓前端源码**的实测统计，
不凭印象。对照对象优先选 **ARMSX2 自带 Android 前端**——因为它与 Hps2
**共用同一份核心**，是最干净的"同核不同壳"对照。

---

## 0. 一句话结论

**核心接入的完成度很高（阶段 0–4 真机通过），前端产品化完成度很低（约为
同源安卓前端的 8.5%）。当前是一个"能跑通全链路的技术验证产品"，不是"可日常使用的模拟器"。**

并且本轮发现一个**与功能无关但优先级更高的工程风险**：上游改动归档不完整，
**按 README 无法从零复现构建**（见 §5）。

---

## 1. 完成度总览

| 维度 | 状态 | 说明 |
|---|---|---|
| 核心移植（ARMSX2→OHOS）| ✅ 真机通过 | EE/IOP/VU0/VU1 四个重编译器全开，fastmem 开 |
| JIT 可执行内存 | ✅ 真机通过（**仅 debug 签名**）| `mmap(RW)→mprotect(RX)→执行` 往返成功 |
| 图形出画面 | 🟡 OpenGL 可用 | **Vulkan 未接入** |
| 音频 | 🟡 OHAudio 已接入 | 曾修爆音；用户仍报"音乐不正常" |
| 输入 | 🟡 虚拟按键 + 手柄已通 | 手柄仅 1 款（盖世小鸡 X5S）实测 |
| 存档 | ✅ 即时存档 8 槽 + 记忆卡管理 | 读档线程问题已根因修复 |
| **前端产品化（设置/库/自定义）** | ❌ **最大短板** | 见 §3 |
| 性能优化（阶段 5）| ⬜ 未开始 | 无真实渲染下的性能数据 |
| 商店分发（release 签名）| ❌ 未实现 | normal_hap 域下 JIT 不可用 |

**阶段关卡**：README 自评阶段 0–4 全通过、阶段 5 待做。这个自评与代码一致。

---

## 2. 代码量对照：同核不同壳

| 模块 | Hps2（ArkTS/ArkUI）| ARMSX2 Android（Kotlin/Compose）| 比值 |
|---|---|---|---|
| 前端 UI | **5,055 行** | **59,789 行** | **8.5%** |
| 平台胶水层 | 5,526 行（C++ N-API）| （含在上面）| — |
| 上游核心改动 | 1,057 行新增 / 23 文件 | — | — |

> Hps2 前端 16 个 `.ets` 文件；ARMSX2 Android 前端 160 个 `.kt` 文件。

**这个比值要谨慎解读**：Android 前端包含大量 Hps2 目标之外的东西
（皮肤商店、在线图标库、Discord 状态、好友、新闻、壁纸动画）。
但即便只看"设置 + 触控"两块，差距依然是量级性的：

| 模块 | Hps2 | ARMSX2 Android |
|---|---|---|
| 设置相关 | 0 行（内联在 `Index.ets`）| `ui/settings/` + `ui/settingshub/` ≈ 5,000 行 |
| 触控自定义 | 0 行（布局写死）| `ui/touch/` ≈ 4,150 行 |

---

## 3. 功能对照（重点）

### 3.1 设置项：这是最大的差距

| | Hps2 | ARMSX2 Android（同核）| NetherSX2 |
|---|---|---|---|
| 可配置项数量 | **约 6 项** | **267 个字段 / 201 个配置键** | 分类级设置树 |
| 设置分类 | 无分类（单面板）| **13 个分类** | 5+ 分类 |
| 设置搜索 | ❌ | ✅ 带索引与搜索浮层 | ? |
| 逐游戏设置 | ❌ **无** | ✅ | ✅ |
| GameDB 默认值 | ❌ | ✅ | ✅（补丁更新）|

**Hps2 现有的全部可配置项**（从 `Index.ets` 逐个点出，无遗漏）：

1. 画面比例 —— 4 个选项（自动 / 保持 4:3 / 铺满 / 宽屏 16:9）
2. 内部渲染分辨率 —— 1x / 2x / 3x（native 侧硬夹在 1.0–4.0）
3. MTVU（VU1 独立线程）—— 开关，**默认关闭**（上游默认开启）
4. 显示虚拟按键 —— 开关
5. BIOS 更换
6. 蓝牙手柄映射（选设备 → 映射到 1P）

对照 ARMSX2 Android 的 13 个分类：General / Info / Performance / Graphics /
Audio / Controls / Hotkeys / Network / OnScreen / Skins / Advanced / Patches / About。

**缺失的高价值设置**（均为对照项已有）：

- 渲染后端选择（GL / Vulkan / 软件）
- 去隔行模式、宽高比微调、画面裁剪、整数缩放
- 纹理过滤、各项异性、混合精度、CRC 修正、GS 硬件修正
- 音频后端 / 缓冲 / 延迟 / 时基拉伸 / 音量
- EE 循环率 / 循环跳帧、VU 钳位与舍入、快速 CDVD、INTC 自旋
- 帧率上限 / 跳帧 / 快进
- 纹理缓存与 shader 相关选项

> 注意：**"上游有"不等于"Hps2 能直接给"**。多数选项需要先在
> GLES/OHOS 路径上验证真的生效（本项目已有"注释写了但没设置"的前车之鉴，
> 见 `docs/STATUS.md` §4.3 问题 5）。所以这不是"接线"工作量，而是"验证 × N"。

### 3.2 触控自定义：设计稿有，功能没有

`docs/frontend-design/` 下有 3 张设计稿：

| 设计稿 | 状态 |
|---|---|
| `01-gameplay-landscape.jpg` | ✅ 已实现（代码注释明确引用"设计稿 01"）|
| `02-home-portrait.jpg` | ✅ 已实现（引用"设计稿 02"）|
| `03-edit-layout.jpg` | ❌ **未实现**（代码中无任何引用，无对应组件）|

第 3 张是**触控布局编辑器**的参考稿，界面包含：

- 拖拽定位各按键（带虚线选择框）
- **Button opacity 滑杆（60%）**
- **Auto-hide after 滑杆（5s）**
- **Touch gliding 开关**、**Auto-center analog stick 开关**
- **Button style 配色选择**（7 色）
- **Reset / Save 按钮**

Hps2 现状：`VirtualPad.ets` 的坐标**全部由公式算出、写死在代码里**
（`btn()` / `stickR()` / `controlLeftX()` 等），尺寸与位置**用户完全无法调整**，
无透明度、无自动隐藏、无配色、无自定义布局持久化。

> 本项目 `docs/user-wishlist-assessment.md` 已自行把"屏幕按键设置"列为
> 用户期待项并标注 ❌。此设计稿说明当时已明确要做，只是没做。

### 3.3 完整功能矩阵

| 功能 | Hps2 | ARMSX2 | NetherSX2 | 说明 |
|---|---|---|---|---|
| 游戏库 / 封面艺术 | ❌ | ✅ | ✅ | **Hps2 只能持有 1 个游戏**（`gamePath`/`gameName` 单变量）|
| 最近游戏 / 搜索 | ❌ | ✅ | ? | |
| 逐游戏设置 | ❌ | ✅ | ✅ | |
| 设置搜索 | ❌ | ✅ | ? | |
| 即时存档 | ✅ 8 槽 | ✅ | ✅ 10+1 槽 | Hps2 无缩略图 |
| 记忆卡管理 | ✅ 导入/创建/导出/删除/按游戏归类 | ✅ | ✅ | **Hps2 这块明显强于其他项，是亮点** |
| 金手指（pnach）| ❌ | ✅ | ✅ | 上游有 `cheats/` 目录，Hps2 未接 UI |
| 宽屏 / 去隔行补丁 | ❌ | ✅ | ✅ | |
| RetroAchievements | ❌ | ✅ | ✅ | 上游已带 `rcheevos` 静态库 |
| 纹理包 | ❌ | ✅ | 🟡 部分失效 | |
| 快进 / 慢放 | ❌ | ✅ | ✅ | |
| 倒带 | ❌ | ❌ | ? | Android 侧也普遍没有 |
| 截图 | ❌ | ✅ | ? | |
| 多人联机 | ❌ | ✅ Local Link | ✅ | |
| 多语言 | ❌ 仅中文 | ✅ 1,619 条 UI 文案 | ✅ | Hps2 字符串硬编码在 `.ets` 里 |
| 皮肤 / 主题 | 🟡 仅日夜色 | ✅ | ✅ | |

**Hps2 强于对照项的地方**（应当保留并作为卖点）：

- **PS2 记忆卡管理**做了按游戏序列号自动归类、跨模拟器兼容的标准 `.ps2` 文件
  导入导出 —— 这一点比 NetherSX2 的"整卡导入、无法单档导入"更好用。
- **JIT 门禁的诚实提示**：明确告知"不可用则拒绝启动"并给出诊断与处置建议，
  不假装能跑。对照项里没人这么做。

### 3.4 UI 形态对照

| | 形态 |
|---|---|
| Hps2 | 首页（BIOS/游戏/启动）+ 全屏游玩页 + 设置弹层 + 存档弹层 + 悬浮球 |
| ARMSX2 | 导航抽屉 + 封面网格/列表库 + 游戏内覆盖层 + 13 分类设置 + 独立管理页（BIOS/记忆卡/存档/手柄/补丁/纹理/成就/语言/关于）|
| NetherSX2 | Material 抽屉 + 游戏列表 + 游戏内覆盖层；设置疑似 **ImGui 渲染** |

Hps2 用的是 ArkUI 原生组件、语义色资源限定符（`base/` + `dark/`）自动跟随
系统日夜模式——**这个主题方案本身是干净的**，问题不在实现质量，而在**覆盖的功能面**。

---

## 4. 与安卓阵营的功能/性能基准差距

用户从安卓 PS2 模拟器带来的预期（按重要性），Hps2 的现状：

| # | 安卓侧预期 | Hps2 现状 |
|---|---|---|
| 1 | 能启动并运行真实游戏 + BIOS 导入向导 | 🟡 能运行，无向导 |
| 2 | 旗舰机 2024+ 原生分辨率满速 | ❓ **无真实渲染下的性能数据**（阶段 5 未做）|
| 3 | Vulkan 优先、OpenGL 回退、软件渲染 | ❌ 仅 OpenGL |
| 4 | 逐游戏设置 + 可搜索设置树 | ❌ 全无 |
| 5 | 即时存档 + 记忆卡管理 | ✅ **已达成** |
| 6 | 深度触控自定义（可拖动、皮肤、宏、陀螺仪）| ❌ 全无 |
| 7 | 外接手柄自动映射（SDL 手柄库）| 🟡 已通，但仅 1 款实测 |
| 8 | 1x–8x 分辨率缩放 | 🟡 仅 1x–3x |
| 9 | 金手指（pnach + 在线库）| ❌ |
| 10 | 封面库 + 元数据 | ❌ |
| 11 | RetroAchievements | ❌ |
| 12 | 快进 + 快速覆盖菜单 | 🟡 覆盖菜单有，快进无 |

**行业基准参考**：ARMSX2 Android 最低 8.0/arm64-v8a、建议 6GB+ RAM、
Vulkan + 新驱动、**建议主动散热**；AetherSX2 作者建议骁龙 845 或更好、
四大核（Cortex-A75+）。EtherSX2 类产品普遍把"原生分辨率起步"作为调优建议。

---

## 5. 🔴 本轮新发现的工程风险：上游改动无法复现

**这一条与功能完成度无关，但优先级应当最高——它威胁的是"项目能否重建"。**

### 5.1 事实

Hps2 的核心来自 `upstream/ARMSX2`（在根 `.gitignore` 中被忽略，不纳入外层仓库）。
对该核心的改动分散在三处：

| 位置 | 文件数 | 是否可复现 |
|---|---|---|
| ARMSX2 本地分支 `hps2-harmonyos` 的**已提交**改动 | **23 个** | ❌ **分支仅存在本地，未推送到任何远端** |
| 工作区**未提交**改动 | **9 个** | ❌ 未提交 |
| `patches/` 归档 | **6 个** | ✅ 已归档 |

**实测命令与结果**：

```
$ cd upstream/ARMSX2
$ git diff --name-only d7e8d01678 HEAD | wc -l        # 基线 → 本地提交
23
$ git status --short | grep -vE '^ D' | wc -l          # 未提交
9
$ # 归档覆盖
$ grep -E '^\+\+\+ ' ../../patches/upstream/0001-*.patch | wc -l
6
```

**未被归档的关键文件**（节选，均为 OHOS 移植的核心）：

```
cmake/ohos.toolchain.cmake              ← README 构建步骤直接引用它
common/HTTPDownloaderOHOS.cpp           ← 替代 libcurl
common/HarmonyOS/ohos_libcxx_compat.h
pcsx2/CDVD/HarmonyOS/IOCtlSrcOHOS.cpp   ← 光盘读取
pcsx2/GS/Renderers/OpenGL/GLContextEGLOHOS.{cpp,h}
pcsx2/Memory.{cpp,h}                    ← 解释器降级策略
pcsx2/Host/OHAudioStream.cpp            ← 音频后端（在 patches/new-files/ 里，但依赖未归档的改动）
... 共 23 个
```

### 5.2 后果

1. **README 的构建步骤无法执行**：它让用户
   `git clone ARMSX2` 后 `git checkout <本仓库记录的 fork 提交>`，
   再用 `-DCMAKE_TOOLCHAIN_FILE=upstream/ARMSX2/cmake/ohos.toolchain.cmake`。
   但**记录的提交 `d7e8d0167` 是上游 master，本身不含任何 OHOS 支持**，
   而 `cmake/ohos.toolchain.cmake` **在上游仓库中不存在** —— 该文件是本项目新增的。
   照 README 走必然在第一步失败。

2. **`patches/README.md` 记载的再生成命令也补不全**：
   ```bash
   git diff -- '*.cpp' '*.h' '*.txt' > ../../patches/upstream/....patch
   ```
   该命令只抓**未提交的** 8 个文件，**完全抓不到已提交的 23 个**。
   即按文档操作，归档仍然缺 23 个文件。

3. **`patches/README.md` 自称"当前归档的改动 = 6 个文件"**，
   与实际的 29 个差异文件不符 —— 文档与事实已经脱节。

**关键判据**：`d7e8d0167` 之后的 5 个本地提交（`2cf5c3dd7` → `13a8af3a0`）
承载了全部 OHOS 移植工作，而它们**只存在于这台机器上**。
`docs/stage2-progress.md` §3.1 曾写"早期一度出现『改了但没提交』的状态，已修正"
—— 现在已经提交了，但**没有推送**，风险性质相同。

### 5.3 建议（按性价比）

1. **把 `hps2-harmonyos` 分支推到某个远端**（自己的 fork 即可），
   或把这 5 个提交导出为 patch 放进 `patches/`。**这是最彻底的一条。**
2. 重新生成 `patches/`，**以 `origin/master` 为基准**（而非只抓工作区），
   覆盖全部 29 个文件；新增文件同步进 `patches/new-files/`。
3. 修正 README 的构建步骤：明确"需先应用 `patches/`"，并写入真实可用的提交号。
4. 把 `patches/README.md` 的文件数说明改为与实际一致，并在流程里加一步
   **校验脚本**（对比 `git diff --name-only origin/master HEAD` 与归档清单）。

> 顺带：`upstream/` git status 还显示 563 个被删除的图片。`patches/README.md`
> 已说明这是清体积所致、与功能无关 —— 此处确认该判断成立，不影响构建。

---

## 6. 完成度打分（主观，但依据上文事实）

| 维度 | 完成度 | 依据 |
|---|---|---|
| 核心移植与 JIT | **85%** | 四重编译器真机全开；缺 Vulkan、缺 MTGS 异步 |
| 图形 | **45%** | OpenGL 出画面、比例与倍率可调；无 Vulkan、无后处理、无 shader 选项 |
| 音频 | **50%** | OHAudio 后端已接入并修过爆音；用户仍反馈异常，无任何音频设置 |
| 输入 | **55%** | 虚拟按键 + 手柄双通路；但布局不可自定义、仅 1 款手柄验证 |
| 存档 | **80%** | 即时存档 + 记忆卡管理完整，是项目最强项 |
| **前端 / 设置 / 产品化** | **15%** | ~6 个设置项 vs 对照 267 项；无库、无逐游戏设置、无触控编辑 |
| 分发 | **25%** | debug 签名可用；商店降级路径未实现 |
| 性能优化 | **5%** | 阶段 5 未开始，无真实渲染数据 |
| **工程可复现性** | **25%** | 归档覆盖 6/29，README 构建路径不可执行 |

**综合**：作为**技术可行性验证**，完成度很高（该证的都证了，且证据链扎实）。
作为**可交给普通用户的产品**，完成度很低——主要瓶颈**不在核心，在前端**。

---

## 7. 建议的下一步（按性价比排序）

| 优先级 | 事项 | 理由 |
|---|---|---|
| 🔴 P0 | 修复上游改动归档（§5）| 唯一可能造成**不可逆损失**的问题 |
| 🥇 P1 | **触控布局编辑器** | 设计稿已成，用户明确期待，是"可玩性"的直接瓶颈 |
| 🥈 P2 | **游戏库 + 封面 + 逐游戏设置** | 与安卓阵营差距最大的一项；也是设置项爆炸后的必要容器 |
| 🥉 P3 | 图形设置扩展（先去隔行、整数缩放、后端选择）| 每项都需先验证在 GLES/OHOS 下真的生效 |
| P4 | Vulkan 后端 | 性能上限的关键，但工作量大（需 shaderc 交叉编译）|
| P5 | 阶段 5 性能基准 | 目前**没有任何真实渲染下的性能数据**，无法判断是否"可玩" |
| P6 | 音频问题定性 | 用户反馈"音乐不正常"但现象未澄清，需先要具体描述 |

---

## 附：本报告使用的实测命令

```bash
# 代码量
find app-hps2/entry/src/main/ets -name '*.ets' | xargs wc -l | tail -1
find upstream/ARMSX2/platforms/android/app/src/main/java/com/armsx2 \
     -name '*.kt' | xargs wc -l | tail -1

# 设置项数量
grep -cE '^\s+(var|val) ' \
  upstream/ARMSX2/platforms/android/app/src/main/java/com/armsx2/config/Settings.kt

# 设置分类
grep -A 15 'enum class SettingsCategory' \
  upstream/ARMSX2/platforms/android/app/src/main/java/com/armsx2/navigation/AppRoute.kt

# 归档覆盖缺口
cd upstream/ARMSX2
{ git diff --name-only d7e8d01678 HEAD; \
  git status --short | grep -vE '^ D' | awk '{print $2}'; } | sort -u > /tmp/all.txt
grep -E '^\+\+\+ ' ../../patches/upstream/0001-*.patch \
  | sed 's|^+++ [ab]/||' | sort > /tmp/arch.txt
comm -23 /tmp/all.txt /tmp/arch.txt      # 23 个未归档
```

---

## 参考来源（外部）

- [ARMSX2 README](https://github.com/ARMSX2/ARMSX2) —— ARM64 JIT fork 的定位与状态
- [ARMSX2 系统需求](https://armsx2.net/docs/system-requirements) —— 最低 8.0/arm64-v8a，建议 6GB+、主动散热
- [NetherSX2-patch](https://github.com/Trixarian/NetherSX2-patch) —— 补丁仓库（非完整源码）
- [NetherSX2 FAQ](https://github.com/Trixarian/NetherSX2-patch/blob/main/assets/faq.html) —— 10+1 存档槽、整卡导入、触控按钮清单
- [NetherSX2 GameDB Options](https://github.com/Trixarian/NetherSX2-patch/blob/main/docs/GameDB%20Options.txt) —— 逐游戏键位
- [PCSX2 系统需求](https://pcsx2.net/docs/setup/requirements/) —— 上游仅 x86-64（无原生 ARM64 JIT）
- [Play!](https://github.com/jpd002/Play-) / [libretro Play! 文档](https://docs.libretro.com/library/play/) —— 免 BIOS 的 HLE 路线
- [PCSX2 关于 DamonPS2 的声明](https://pcsx2.net/blog/2018/the-pcsx2-teams-statement-regarding-the-damonps2-emulator/) —— 闭源/GPL 争议
- [AetherSX2 停更报道](https://www.androidauthority.com/aethersx2-ps2-emulator-android-end-3262749/) —— 2023-01 停止开发
- [ARMSX2 Material You 报道](https://www.androidauthority.com/armsx2-ps2-emulator-android-material-you-3689494/) —— 安卓前端 UI 形态
