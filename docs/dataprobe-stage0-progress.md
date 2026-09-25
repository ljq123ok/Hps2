# 阶段 0：数据外置探针（进行中）

> ⚠️ **本文档已被 `docs/dataprobe-stage0-conclusion.md` 取代（2026-09-25）**。
> 真机判读已完成，结论是**实时外置数据根不可行**（应用命名空间看不到
> `/storage/media`）。下面第 6 节的"待办"与第 2.2 节的权限推断已过时，
> 保留仅为记录排查过程。请以结论文档为准。

**状态**：代码完成、构建通过、已装机；**五项结果待真机判读**
**提交**：`ff463dd`（前一个：`0da7e0a`）
**日期**：2026-09-24

---

## 1. 目的

回答一个问题：**应用能否把数据根放在公共 Download 目录**。

这是阶段 3（数据外置 + 无损迁移）的**前置闸门**。若不先验证就动手做迁移，
一旦前提不成立，整套迁移逻辑作废。方案见 `docs/RECON-three-features.md`。

---

## 2. 规划中的两个前提是错的（已实测修正）

### 2.1 路径不能硬编码

规划写的目标是 `/storage/Users/currentUser/Download/Hps2`。真机实测：

```
/storage/Users/currentUser/Download   → No such file or directory   ✗
/storage/media/100/local/files/Docs/Download → 存在，uid=20001006   ✓
```

设备为 HarmonyOS 7.0.0（API 26）测试设备。故探针改为运行时经
`Environment.getUserDownloadDir()` 解析，不拼接字面量。

### 2.2 权限模型用错了

| 权限 | grantMode | level | 实际作用 |
|---|---|---|---|
| `FILE_ACCESS_PERSIST` | system_grant | normal | **picker URI 持久化**，不是公共目录访问 |
| `READ_WRITE_DOWNLOAD_DIRECTORY` | **user_grant** | normal | 需弹窗 |
| `READ_WRITE_USER_FILE` | system_grant | **system_basic** | 受限级，不应使用 |

关键：`@ohos.file.environment.d.ts` 中 `getUserDownloadDir()` 有**两个文档块** ——
API 11 标注 `@permission READ_WRITE_DOWNLOAD_DIRECTORY`，**API 12 起不再标注**。

⇒ 本机 API 26，预期**零权限**即可调用。探针据此设计，
**未修改 `module.json5`**（符合项目"不申请受限权限"的约定）。

---

## 3. 为什么必须做成 App 内代码

### 3.1 不能用 hdc 脚本替代

shell 的 `uid=2000(shell)`、SELinux 上下文 `u:r:sh:s0`，与应用
`u:r:app:s0` 是两套策略。实测 shell 对 `/storage/media` 报
`Permission denied`，**但这不能推断应用也失败**。必须由应用进程自己实测。

### 3.2 ArkTS 与 Native 必须分别测

两条通路不同：

- ArkTS 的 `fs` → OpenHarmony 文件管理框架（可能经 hmdfs/fuse、URI 授权）
- Native 的 `openat(2)` → 原始系统调用，**PCSX2 核心只用这条**

⇒ ArkTS 能访问**不等于**核心能用。**第 4 项（Native POSIX）才是真正的闸门**：
若它 FAIL 而 ArkTS 全 PASS，则数据外置对模拟器无意义。

---

## 4. 实现

| 文件 | 作用 |
|---|---|
| `app-hps2/entry/src/main/cpp/hps2_dataprobe.h/.cpp` | 第 4 项：纯 POSIX 往返（不依赖任何上游类型） |
| `app-hps2/entry/src/main/ets/common/DataProbe.ets` | 第 1–3 项：ArkTS 侧探测与结构化日志 |
| `napi_init.cpp` | 新增 `runDataProbe(root)` / `statDataPath(path)` |
| `pages/Index.ets` | `aboutToAppear` 中自动运行（冷启动判据需要每次启动都跑） |

Native 往返顺序对齐核心实际用法：
`mkdir → open → write → fsync → lseek → pread/read 回读比对 → stdio → close → rename → stat → unlink`

**安全**：只写自建 `<公共目录>/Hps2Probe/`，不触碰 `games/`、`memcards/`。

---

## 5. 已验证

- 核心与 HAP 构建通过
- `strings` 确认 `DATA_PROBE` / `runDataProbe` / `statDataPath` 已进入 `libhps2core.so`
- 签名成功（复用 `stage1-jitprobe/scripts/sign-app-hps2.sh`）
- **已用 `install -r` 更新安装**（同 bundle = 更新），沙箱保留：
  10 GB 游戏（战神 8.5 GB + 暴走山地车 2.2 GB）、2 个记忆卡、3 个即时存档

### 构建环境坑（值得记录）

hvigor 的 `PackageHap` 步骤会调用**裸 `java`**。未把 DevEco 的 JBR 放进 PATH 时，
报 `00308018 Unknown Error` + `Unable to locate a Java Runtime`，而错误信息
完全不提 Java。正确做法：

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export PATH="$JAVA_HOME/bin:/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
```

---

## 6. 待办（阻塞中）

真机**锁屏**导致启动被拒：

```
Error Code:10106102  The device screen is locked during the application launch,
unlock screen failed. The current mode is developer mode, and the screen cannot
be unlocked automatically
```

**解锁手机后**执行：

```bash
H=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$H shell aa force-stop com.hps2.jitprobe
$H shell aa start -b com.hps2.jitprobe -a EntryAbility
sleep 12
$H shell "hilog -x" | grep DATA_PROBE
```

（HAP 已签名并安装；如需重装：`/tmp/hps2-dataprobe.hap`，
或用 `sign-app-hps2.sh` 重新签名。注意 `/tmp` 可能被清理。）

### 判读标准

```
DATA_PROBE resolve_public_dir=PASS
DATA_PROBE mkdir=PASS
DATA_PROBE mkdir_subdirs=PASS
DATA_PROBE enumerate=PASS
DATA_PROBE persist_marker=PASS
DATA_PROBE native_rw_seek=PASS      ← 真正的闸门
```

第 5 项（卸载重装后数据是否仍在）**尚未做** —— 需用户单独确认，
因为它会清空沙箱。探针的 `persist_marker` 已为它铺路（记录上次启动时间）。

### 决策表（探针结果 → 方案）

| 结果 | 采用方案 |
|---|---|
| 全通过 | 启用实时外置数据根 |
| 只能访问用户预建目录 | 暂不自动切换；增加引导 + 保留沙箱回退 |
| ArkTS 可访问但 Native POSIX 失败 | 核心数据仍放沙箱，只做手动备份/恢复 |
| 卸载重装后无法重新访问 | 判定实时外置不可用，不得宣称解决卸载丢档 |

---

## 7. 预防性备份

探针前已取出**不可再生数据**至 `.backup-probe-precaution/`（39 MB，已加入
`.gitignore`，不入库）：

- `memcards/Mcd001.ps2`、`Mcd002.ps2`（⚠️ 两者 sha256 相同
  `47ebe237…`，可能未实际分开写入，值得留意）
- `sstates/` 3 个
- `video-settings.json`、`game_selection.json`、`emulog.txt`

游戏 ISO 在 `/storage/media/100/local/files/Docs/ps2/` 已有完整副本（9.0 GB），
v0.12 可由本仓库重新签名恢复。
