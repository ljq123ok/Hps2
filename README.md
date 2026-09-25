# Hps2 — HarmonyOS 上的 PS2 模拟器

基于 [ARMSX2](https://github.com/ARMSX2/ARMSX2)（PCSX2 的原生 ARM64 JIT fork）
移植到 HarmonyOS / OpenHarmony。

> **当前测试版：v0.13**
>
> 开发测试设备：**HarmonyOS API 26 arm64 测试设备**。欢迎在 GitHub Issues 反馈测试结果。
> 本版本是开发测试包，不代表已经适配所有 HarmonyOS 设备。

> **本版本（GitHub 分发版）需要你自己签名。**
> 原因见下方「为什么必须自签名」—— 这是 HarmonyOS 的安全模型决定的，
> 不是我们的选择。

---

## 为什么必须自签名

HarmonyOS 用 **SELinux 域**隔离应用，而域由**签名类型**决定：

| 签名类型 | SELinux 域 | 能否执行 JIT 动态生成代码 |
|---|---|---|
| 调试签名（自签）| `debug_hap` | ✅ **可以** |
| 发布签名（商店）| `normal_hap` | ❌ **被系统拒绝** |

这是我们在真机上实测的结论，不是推测：

```
调试签名：SELinux 域 = o:r:debug_hap:s0   → JIT 自检「可用」
发布签名：SELinux 域 = o:r:normal_hap:s0  → JIT 自检「不可用」，errno=22 (EINVAL)
```

**PS2 模拟离开 JIT 就没有意义** —— 纯解释器的性能远低于可玩阈值。
因此本版本**不做降级**：若 JIT 不可用，应用会明确告知并拒绝启动，
而不是让你跑幻灯片。

---

## 构建与安装

### 前置条件

- DevEco Studio（含 HarmonyOS SDK 与 native 工具链）
- 一台 arm64 HarmonyOS 设备

### 步骤

```bash
# 1) 取出上游代码
git clone https://github.com/ARMSX2/ARMSX2.git upstream/ARMSX2
cd upstream/ARMSX2 && git checkout <本仓库记录的 fork 提交>

# 2) 交叉编译第三方依赖
#    详见 thirdparty-ohos/（脚本会产出 prefix/ 下的 arm64 库）

# 3) 配置并编译核心
cmake -S upstream/ARMSX2 -B build \
      -DCMAKE_TOOLCHAIN_FILE=upstream/ARMSX2/cmake/ohos.toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release -DDISABLE_ADVANCE_SIMD=ON \
      -DUSE_VULKAN=OFF -DUSE_OPENGL=ON \
      -DENABLE_QT_UI=OFF -DENABLE_QT_DEBUGGER=OFF \
      -DWAYLAND_API=OFF -DX11_API=OFF
cmake --build build --target PCSX2_CORE_STATIC --parallel

# 4) 编译 HAP
cd app-hps2
hvigorw --mode module -p module=entry@default assembleHap --no-daemon

# 5) **用你自己的证书签名**（关键步骤）
#    DevEco Studio：File → Project Structure → Signing Configs → 勾选 Automatically generate signature
#    或命令行：<SDK>/toolchains/lib/hap-sign-tool.jar sign-app ...
```

### 关于包名

`bundleName` 当前为 `com.hps2.jitprobe`。自签时你需要在**自己的 AGC 账号**
下创建对应应用（或使用 DevEco 的 AutoSign 自动创建），否则签名会因
bundleName 与 Profile 不匹配而失败。

---

## 使用

1. 应用启动后会**自动做一次 JIT 自检**，界面上显示「JIT 状态」
   - 显示「可用」→ 可以正常游玩
   - 显示「不可用」→ 见下方排查
2. 点「选择 BIOS 文件」，从文件管理器中选**你自己合法拥有的** PS2 BIOS（4MB）
3. 可选：点「选择游戏镜像」选择游戏（`.iso` / `.chd` / `.bin` / `.img`）
4. 点「启动游戏」
5. 游戏运行时，屏幕上会出现**虚拟手柄**（十字键 / 双摇杆 / △○×□ / 肩键 / 扳机）

### JIT 显示不可用怎么办

按界面提示依次尝试：

1. **重启手机**后重试 —— 我们在开发中观测到 JIT 可用性会随运行状态变化
   （详见 `docs/jit-regression.md`）
2. 确认应用是**调试签名**安装的（本版本的前提）
3. 若仍失败，请把界面上的**错误码**（如 `EINVAL`）反馈到 Issue

---

## 法律声明

**本应用不内置、不分发 BIOS，也不分发任何游戏镜像。**

- BIOS 是索尼的版权作品。你需要**自行准备合法拥有的** PS2 BIOS。
  应用只读取你通过系统文件管理器**主动选择**的文件。
- 游戏镜像同理，请使用你自己合法拥有的副本。
- 应用**未申请任何受限权限** —— 通过系统文件选择器访问文件不需要额外授权。

**许可证**：本项目基于 ARMSX2 / PCSX2，遵循 **GPL-3.0-or-later**
（见 `COPYING.GPLv3`）。因此本项目的源码同样以 GPL-3.0+ 开源。

---

## 项目状态

### v0.13 真实状态

- 已在 HarmonyOS API 26 arm64 测试设备上完成核心启动、BIOS/游戏运行、OpenGL 画面、横屏布局、虚拟按键、3 倍内部渲染倍率等阶段性验证。
- 本版新增即时存档（保存、读取、删除）、可拖动 FPS 悬浮球、日夜主题、错误分类、BIOS 规格检查、诊断日志导出和加载提示。
- 外接手柄输入已接入 HarmonyOS GameControllerKit；本版本使用**盖世小鸡 X5S 拉伸蓝牙手柄**完成测试，其他品牌和型号仍需单独验证。
- 旧版本创建的即时存档可能与当前构建不兼容；遇到读档异常时请删除旧档并重新保存。
- 发布前已重新构建未签名 HAP；最终签名安装和真机功能回归由用户手动验证。
- HAP 不包含 BIOS 或游戏镜像；用户必须使用自己的合法文件。
- HAP 未签名，用户必须用自己的开发者账号生成**调试签名**后安装；发布签名可能导致 JIT 不可用。
- 音频仍可能存在杂音，当前未纳入本版本修复范围。
- 如启动后提示 JIT 不可用，请优先确认使用的是调试签名，并反馈手机型号、签名方式、JIT 状态和日志。
- 本次发布不包含 HAP、签名证书/私钥、BIOS、游戏镜像、设备序列号或原始真机日志；发布包请在本地自行构建并签名。

| 阶段 | 内容 | 状态 |
|---|---|---|
| 0 | 可行性审计 | ✅ |
| 1 | 真机 JIT 验证 | ✅ 通过 |
| 2 | 核心接入（BIOS 启动）| ✅ 通过 |
| 3 | 真实游戏负载 | ✅ 通过 |
| 4 | 图形 + 输入 | ✅ OpenGL 出画面 + 虚拟手柄 |
| 5 | 性能优化 | ⬜ 待做 |

已知限制：

- **Vulkan 后端未接入**（需要 shaderc 交叉编译，源码已备好但未完成）
- **蓝牙手柄仍需扩大真机兼容性验证**
- **应用市场版降级路径尚未实现**（release/normal 签名下 JIT 不可用）
- 多核优化未做（MTVU 等当前关闭）

技术文档见 `docs/`。
