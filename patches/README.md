# 上游改动归档（upstream/ARMSX2）

`upstream/` 在根 `.gitignore` 中被忽略（外部源码树，体积大）。
但我们对上游做了**必要修改**，若不归档，**换环境重新克隆就会丢失**。

## 目录说明

| 路径 | 内容 |
|---|---|
| `upstream/0001-hps2-ohos-bringup-complete.patch` | **完整补丁**：上游基线 → 当前全部改动（含新增文件）。`git diff` 格式 |
| `upstream/superseded/` | 历史补丁，仅留痕，**不要使用** |
| `new-files/` | 已废弃（内容已并入完整补丁）。保留作参考 |

## 应用方式

```bash
cd upstream/ARMSX2
git checkout d7e8d01678107f066d6ec988ca178d80089bd9f5   # 上游基线
git apply ../../patches/upstream/0001-hps2-ohos-bringup-complete.patch
```

补丁以**上游基线**为基准，一次性覆盖全部改动，**不需要按顺序应用多个补丁**。

## 当前归档的改动（29 个文件）

`d7e8d0167..HEAD` 的 8 个提交 + 工作区未提交改动，合计 **29 个文件**。

### OHOS 平台接入（新增）

| 文件 | 说明 |
|---|---|
| `cmake/ohos.toolchain.cmake` | **OHOS 交叉编译工具链** —— README 构建步骤直接引用 |
| `common/HTTPDownloaderOHOS.cpp` | OHOS 原生 HTTP，替代 libcurl |
| `common/HarmonyOS/ohos_libcxx_compat.h` | libc++ 兼容层 |
| `pcsx2/CDVD/HarmonyOS/IOCtlSrcOHOS.cpp` | 光盘读取 |
| `pcsx2/GS/Renderers/OpenGL/GLContextEGLOHOS.{cpp,h}` | **OHOS EGL 上下文** —— 出画面的关键；`ResizeSurface` 重建 EGLSurface 修旋转后黑屏 |
| `pcsx2/Host/OHAudioStream.cpp` | **HarmonyOS OHAudio 音频后端**，含爆音修复（按系统回调帧数自适应抬高 `buffer_ms`）|

### 已有文件的修改（节选）

| 文件 | 改动 |
|---|---|
| `pcsx2/Config.h` | OHOS 平台默认音频后端 = OHAudio |
| `pcsx2/Host/AudioStream.{cpp,h}`、`AudioStreamTypes.h` | OHAudio 后端枚举与接入 |
| `pcsx2/Memory.{cpp,h}` | 解释器模式策略（见下方 ⚠️）|
| `pcsx2/GS/Renderers/OpenGL/GLContext{,.EGL}.cpp`、`GSDeviceOGL.cpp` | OHOS EGL / 视口适配 |
| `common/Linux/LnxHostSys.cpp`、`LnxMisc.cpp` | JIT 内存映射与平台杂项 |
| `cmake/Pcsx2Utils.cmake`、`SearchForStuff.cmake` | 构建系统 OHOS 分支 |
| `pcsx2/CMakeLists.txt` | 注册 OHOS 源文件 |
| 其余见补丁 | |

> ⚠️ **已知问题（2026-10-01 发现，未修）**：
> `pcsx2/Memory.cpp` 的解释器降级开关已失效。
> 上游基线版读环境变量 `HPS2_FORCE_INTERP`；当前版本改用
> `SysMemory::s_interpreter_only`，但 **`SetInterpreterOnly()` 全仓库无任何调用方**，
> 而 app 侧（`napi_init.cpp:331`）仍在设那个环境变量 → **降级路径断开**。
> 需补上调用（在 `ReserveMemory()`/`Allocate()` 之前）。

## 注意

- 生成补丁时排除了**被删除的 563 个图片**（`platforms/ios` 400 个、
  `platforms/android` 161 个，另有 `bin/`、`pcsx2-qt/` 下若干）——
  那是清理仓库体积时移除的移动端资源，**与功能无关、不影响构建**。
- 补丁以 `d7e8d0167` 为基准。若上游更新，重新 `git apply` 可能需手工解决冲突。

## 维护约定

**每次修改 `upstream/` 下的文件后，必须重新生成归档**：

```bash
cd upstream/ARMSX2

# 关键：未跟踪的新增文件必须先 add -N，否则不会进 diff
git add -N <新增文件路径>

git diff d7e8d01678107f066d6ec988ca178d80089bd9f5 --diff-filter=d \
    -- . ':(exclude)platforms' ':(exclude)*.png' ':(exclude)*.jpg' \
    > ../../patches/upstream/0001-hps2-ohos-bringup-complete.patch
```

### 校验（必做）

```bash
bash tools/check-upstream-archive.sh
```

该脚本对比"实际改动文件"与"补丁覆盖文件"，**漏档会报错并返回退出码 1**。

> **为什么需要校验脚本**：2026-10-01 发现实际改动 29 个文件、
> 归档只有 6 个，漏了 23 个。根因是旧文档教的重生成命令
> `git diff -- '*.cpp' '*.h' '*.txt'` **只抓工作区未提交改动**，
> 抓不到已提交到本地分支的部分，且**未跟踪的新文件完全不进 diff**。
> 现在改为以 `d7e8d0167`（上游基线）为基准做 diff，并配自动校验。

### ✅ 已完成的更彻底方案（2026-10-01）

`patches/` 只是**二级备份**。分支已推送到远端 —— **已完成**：

```
https://github.com/ljq123ok/ARMSX2    分支：hps2-harmonyos
```

克隆方式（推荐，比补丁更可靠）：

```bash
git clone https://github.com/ljq123ok/ARMSX2.git upstream/ARMSX2
cd upstream/ARMSX2 && git checkout hps2-harmonyos
```

该分支覆盖全部 29 个改动文件（含新增文件），**无需再应用补丁**。
补丁的价值在于：离线可复原，且便于与上游更新做 rebase 对照。

> 注：本地 remote `hps2fork` 已指向该 fork，可直接 `git push hps2fork hps2-harmonyos`。
