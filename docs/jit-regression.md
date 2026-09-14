# 真机 JIT 回归现象记录（2026-09-14）

**严重性**：🔴 高 —— 已通过的真机 JIT 验证在 2 小时后**自行失效**

---

## 1. 现象

**同一个 HAP 文件，先通过、后失败：**

| 时间 | 操作 | 结果 |
|---|---|---|
| 17:16 | 构建 `entry-default-manualsigned.hap` | — |
| 17:16 | 安装并运行 | ✅ **PASS=8 FAIL=1，返回 123** |
| 17:21 | 连跑 3 次复核 | ✅ 全部 PASS，结果一致 |
| 19:14 | 重新构建（仅改名 Hps2 + 换图标） | — |
| 19:14 | 安装并运行 | ❌ **PASS=1 FAIL=7** |
| 19:20 | **回装 17:16 的原始文件（未改名、未换图标）** | ❌ **PASS=1 FAIL=7** |
| 19:17–19:45 | 反复重启应用 7 次 | ❌ 全部 PASS=1 FAIL=7 |

### 1.1 失败模式完全一致

```
[OK]   1.1 mmap(RW) | addr=388336443392          ← mmap 成功
[FAIL] 1.3 mprotect(RX) 失败: Invalid argument (errno=22)
[FAIL] 2.1 mprotect 失败: Invalid argument (errno=22)
[FAIL] 3.1 三次重建结果=0,0,0
[FAIL] 4.1 mprotect 失败: Invalid argument (errno=22)
[FAIL] 5.1 第 0 轮 mprotect 失败: Invalid argument (errno=22)
[FAIL] 6.1 mmap(RWX) 直接申请 | 被拒绝: Invalid argument (errno=22)
[FAIL] 6.2 MAP_JIT/FORT 标志探测 | 标志被拒绝: Invalid argument (errno=22)
========== PASS=1 FAIL=7 | basicReturn=-1 | RWX=denied ==========
```

**规律**：`mmap` **成功**，但**任何带 `PROT_EXEC` 的请求**（`mprotect` 加执行位、
`mmap` 直接 RWX）**全部返回 `EINVAL`**。

---

## 2. 已排除的原因（逐项有证据）

| # | 怀疑项 | 排除依据 | 结论 |
|---|---|---|---|
| 1 | 签名流程出错 | **同一个 HAP 文件**先 PASS 后 FAIL | ❌ 排除 |
| 2 | 改名 Hps2 / 换图标 | 回装**未改名**的原始包，同样失败 | ❌ 排除 |
| 3 | SELinux 域变化 | 域字符串逐字符相同：`o:r:debug_hap:s0:x53,x335,x512,x868,x1024` | ❌ 排除 |
| 4 | 系统版本/补丁变化 | `OpenHarmony-7.0.0.105` / API 26 / 补丁 `2026/07/01` / `VOL-AL00 7.0.0.105(SP12C00E8R5P3)` 全部一致 | ❌ 排除 |
| 5 | appspawn 重启导致标志重载 | `appspawn` PID 592 自 **09:09:02** 起未变；PASS(17:21) 与 FAIL(19:14) 属同一进程 | ❌ 排除 |
| 6 | **坚盾守护模式**（全局禁 JIT） | 其它应用 ArkTS 引擎**仍启用 JIT**：<br>`com.tencent.wechat ... jit: 1`<br>`com.huawei.hmos.photos ... jit: 1` | ❌ 排除 |
| 7 | 本应用 ArkTS 引擎异常 | 本应用同样 `jit: 1`，与其它应用一致 | ❌ 排除 |
| 8 | 应用安装不完整 | `install bundle successfully`，`appProvisionType: debug`，`debug: true` | ❌ 排除 |

### 2.1 关键鉴别点

**本应用的 ArkTS 引擎（JSVM）正常启用 JIT，但原生 `mprotect` 被拒。**

这说明拦截**不是**系统级 JIT 禁用，而是针对**本进程的原生可执行内存**
—— 符合 **XPM**（HongMeng 专有执行控制层）的特征。

---

## 3. 当前最可能的变量（未证实）

PASS(17:21) 之后，设备侧唯一明显变化的量是**负载与内存压力**：

```
19:46  up 10:37,  load average: 12.75, 12.80, 13.10
MemFree:   1.1 GB / 11.6 GB
Swap used: 7.4 GB / 12.2 GB          ← 大量换页

CPU 占用 Top:
  com.huawei.hmos.clouddrive    55.1%
  devhost.elf                   44.8%
  cloud_backup_service          27.5%
```

**`cloud_backup_service` / `clouddrive` 正在运行**，设备已连续开机 10 小时 37 分。

> ⚠️ **这是相关性，不是因果。** 未经对照实验验证，不得作为结论。

### 3.1 一个待解释的反常点

`mprotect` 返回 **`EINVAL`** 而非 `EPERM`/`EACCES`。

通常权限拒绝是 `EPERM`。`EINVAL` 更像**参数或地址被策略层判为无效**
（XPM 干预的特征）。此推断**尚无直接证据**，标记为假设。

---

## 4. 待执行的对照实验

**方案（用户已确认）：重启设备 → 立即测试**

| 结果 | 含义 | 后续 |
|---|---|---|
| 重启后恢复 PASS | 运行期状态问题（XPM 区域耗尽 / 内存压力 / 长时运行），**可规避** | 定位具体触发条件，纳入运行时自检 |
| 重启后仍 FAIL | 设备策略在 PASS 之后发生了**持久变更** | 需查 AGC/官方渠道；并检查是否有系统更新或安全策略下发 |

**重启前基线（已记录）**：
```
时间      : 2026-09-14 19:46
uptime    : 10h37m
load      : 12.75 / 12.80 / 13.10
任务      : PASS=1 FAIL=7（确定性失败，非偶发）
```

---

## 5. 对项目结论的影响

**`docs/jit-verdict.md` 中"JIT 可用"的结论需要加限定条件。**

原结论（阶段 1 真机 PASS）本身**没有错** —— 它确实在 17:21 实测通过。
但这次回归表明：

> **JIT 可用性不是设备的静态属性，可能随运行期状态变化。**

这对阶段 2/3 有**直接影响**：

1. **必须在模拟器核心启动时做 JIT 能力自检**，而非假定可用；
2. **需要设计 JIT 不可用时的降级路径**（任务书虽不以解释器作最终兜底，
   但作为可用性兜底仍必需）；
3. 阶段 5 的性能测试必须**记录设备运行状态**，否则数据不可比。

### 5.1 诚实声明

在回归原因查清之前：

- **不宣称 JIT 稳定可用**；
- **不进入阶段 2 的核心移植**（任务书要求关口通过才进，而关口现在存疑）；
- 本现象**优先于 release 签名验证**处理。

---

## 6. 下一步

1. 用户重启设备；
2. 立即跑 `bash stage1-jitprobe/scripts/verify-on-device.sh`；
3. 按 §4 表格判定，并更新本文档与 `docs/jit-verdict.md`。
