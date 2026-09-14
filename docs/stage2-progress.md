# 阶段 2 进度：HarmonyOS 平台接入

**日期**：2026-09-14
**上游基线**：`d7e8d01678107f066d6ec988ca178d80089bd9f5`
**我们的提交**：`2cf5c3dd7`（分支 `hps2-harmonyos`）

---

## 1. 已完成

### 1.1 第三方依赖：12 个库交叉编译完成 ✅

全部**独立验证**为真正的 aarch64（解包成员用 `file` 判定，
而非"看起来成功了"）：

| 库 | 大小 | 提供者 |
|---|---|---|
| libzstd.a | 714 KB | 主代理 |
| liblz4.a | 162 KB | 子代理 |
| libpng18.a (+libpng.a 软链) | 330 KB | 子代理（+主代理修复后重建）|
| libjpeg.a / libturbojpeg.a | 701/1231 KB | 子代理 |
| libwebp*.a (5 个) | 688/357/14/51/28 KB | 子代理 |
| libfreetype.a | 974 KB | 子代理 |

统一安装于 `thirdparty-ohos/prefix`。

**验证脚本**：`thirdparty-ohos/scripts/verify-arch.sh`（12/12 通过）

### 1.2 ARMSX2 配置推进：7/8 依赖已解析 ✅

```
Found ZLIB     sysroot libz.so
Found PNG      prefix/lib/libpng.a (1.8.0)
Found JPEG     prefix/lib/libjpeg.a (62)
Found Zstd     prefix/lib/libzstd.a
Found LZ4      prefix/lib/liblz4.a
Found WebP     prefix/include
Found Freetype prefix/lib/libfreetype.a (2.14.3)
✗ SDL3         仍在交叉编译
```

### 1.3 三个关键修复（均由实测暴露，非猜测）

#### 修复 1：OHOS 平台分支

`cmake/Pcsx2Utils.cmake` 新增 OHOS 分支。原因：OHOS 定义
`__OHOS__`+`__linux__` 但**不定义** `__ANDROID__`，不单独分支会落到 LINUX
并拉入 D-Bus/X11/libcurl/udev。上游 Android 分支的注释已预见同类问题。

#### 修复 2：`--target` 必须进 `CMAKE_C_FLAGS_INIT`

libpng 构建期用宿主机代码生成器预处理 `pnglibconf.c`，它读
`${CMAKE_C_FLAGS}` 而非目标级属性。若缺 `--target`，clang 不会加入
架构专属 include 目录，报：

```
fatal error: 'bits/alltypes.h' file not found
```

OHOS 的 `bits/` 按架构分目录（`aarch64-linux-ohos/bits/`），
因此 `--target` 对 OHOS 是必需的。

#### 修复 3：架构专属库目录 + 前缀可见性

两个独立问题，表现相同（`Could NOT find XXX`）：

- **架构子目录**：OHOS 库在 `usr/lib/aarch64-linux-ohos/`，
  CMake 默认只搜 `<root>/usr/lib` → 设 `CMAKE_LIBRARY_ARCHITECTURE`
- **前缀不可见**：`MODE_*=ONLY` + `ROOT_PATH=sysroot` 会把
  `CMAKE_PREFIX_PATH` re-root 到 sysroot 下 → 改为追加前缀 + `MODE_*=BOTH`

> 这两个问题由 libjpeg / freetype / libpng 三个子代理**独立踩到并报告**，
> 交叉印证。其中 libjpeg 子代理发现我 toolchain 的 bug 后，
> **正确地没有擅自修改公用文件**，而是报告给我修 —— 这是对的做法。

### 1.4 平台层：musl 适配 ✅

`common/Linux/LnxHostSys.cpp` 的 `GetRuntimeCacheLineSize()`：

OHOS musl **无** `_SC_LEVEL1_{D,I}CACHE_LINESIZE`。

**刻意不硬编码缓存行大小** —— ARM64 常见 64 字节，但硬编码会在
缓存行不同的设备上**静默破坏对缓存行敏感的 JIT 逻辑**（如代码失效、
icache 同步范围）。改为：跳过 `sysconf`，仅用
`/sys/devices/system/cpu/cpu0/cache/*/coherency_line_size` 读取；
两者都失败返回 **0 表示"未知"**，由调用方处理。

顺带修正原代码把 `fread` 结果当 C 字符串用的隐患（读取长度检查 + 缓冲清零）。

已验证：编译通过并产出 aarch64 目标文件。

---

## 2. 未完成

| 项目 | 状态 |
|---|---|
| SDL3 交叉编译 | 🔄 进行中（仍在 feature detection） |
| 核心整体编译（PCSX2 目标） | ⬜ 未开始 |
| 链接为可加载库 + HAP 内初始化 | ⬜ 未开始 |
| BIOS 启动可观察验证 | ⬜ 未开始 |

### 2.1 关于 SDL3

定位：仅 `pcsx2-sdl` 前端与 `pcsx2/CMakeLists.txt:1542` 一行链接使用，
**非核心必需**。我们的设备输出计划走 OHNativeWindow + Vulkan / OHAudio，
不走 SDL。

若 SDL3 构建失败，可考虑：
1. 用最小配置构建（关闭绝大多数子系统）
2. 提供 stub 满足 CMake 依赖（记录为技术债）

---

## 3. 工程实践说明

### 3.1 版本控制

- `upstream/` 在**外层仓库**被 gitignore（避免把 45MB 上游历史纳入）
- ARMSX2 的改动提交在**其自身 fork 分支** `hps2-harmonyos` 上
  （提交 `2cf5c3dd7`），与上游基线 `d7e8d0167` 可 diff
- **注意**：早期一度出现"改了但没提交"的状态，已修正

### 3.2 子代理并行

7 个库并行构建。质量观察：

- 多个子代理做了**端到端消费测试**（真实 `find_package` + link 出可执行文件），
  而非仅仅编译通过 —— 这正是发现 toolchain bug 的原因
- 一个子代理报告 `libpng18.a` 仅 10 字节疑似损坏。经核实那是
  **符号链接的大小**（`libpng.a -> libpng18.a`），实际文件 330KB 正常。
  该警告为**误报**，但提出怀疑本身是对的

---

## 4. 复现方式

```bash
# 1) 交叉编译第三方依赖
cd thirdparty-ohos
bash scripts/build-lib.sh <lib> <source-dir> [cmake args...]
bash scripts/verify-arch.sh          # 验证架构（必做）

# 2) 配置 ARMSX2
cmake -S upstream/ARMSX2 -B /tmp/build \
  -DCMAKE_TOOLCHAIN_FILE=upstream/ARMSX2/cmake/ohos.toolchain.cmake \
  -DCMAKE_BUILD_TYPE=Release
```
