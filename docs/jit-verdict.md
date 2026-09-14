# JIT 能否使用？—— **真机验证结论**

**记录时间**：2026-09-14（第三版，**基于真机实测**）
**目标设备**：HUAWEI Pura X View（`VOL-AL00`）
**设备系统**：OpenHarmony-7.0.0.105 / API 26 / arm64-v8a / **HongMeng Kernel 1.13.0**
**本项目包名**：`com.hps2.jitprobe`（正式包名，已在 AGC 注册）
**签名**：华为 AGC 签发，**type=debug**、`apl=normal`

---

## 1. 直接回答

> ## ✅ **能。已在你的真机上验证通过。**
>
> `mmap(RW)` → 写入 AArch64 指令 → `mprotect(RX)` → 清指令缓存 → **执行，
> 返回 123**，与期望值一致。**连跑 3 次结果完全一致，零 AVC 拒绝。**
>
> ⚠️ **但有一个适用范围必须说明**（§4）：本次验证用的是 **debug 签名**。
> 正式发布签名的 JIT 可用性**尚未验证**，且证据显示两者可能不同。

---

## 2. 真机实测结果

证据文件：`docs/evidence/stage1-DEVICE-PASS.txt`

| # | 测试 | 真机结果 | 实测数据 |
|---|---|---|---|
| 1.1 | `mmap(RW)` | ✅ | addr=388336443392 |
| 1.2 | `mprotect(RW→RX)` + icache flush | ✅ | 提交成功 |
| **1.3** | **执行生成代码并校验返回值** | ✅ | **返回 123，期望 123** |
| 2.1 | 重复执行 10000 次 | ✅ | sum=770000 |
| 3.1 | 代码重建（RW→RX 往返 3 次） | ✅ | 11,222,3333 |
| 4.1 | 跨线程执行 | ✅ | 4 线程 × 5000 次，失败 0 次 |
| 5.1 | 释放后重建 | ✅ | 3 轮全部成功 |
| 6.1 | `mmap(RWX)` 直接申请 | ✅ | 内核**允许** W+X |
| 6.2 | `MAP_JIT`/FORT 标志探测 | ❌（**预期**） | **`EINVAL` 标志被拒绝** |

**运行环境**：

```
应用进程 SELinux 域 : o:r:debug_hap:s0:x53,x335,x512,x868,x1024
平台事实            : arch=arm64;pagesize=4096;ohos=1;ptrbits=64
AVC 拒绝            : 无（JIT 全程零 SELinux/XPM 拒绝）
确定性              : 连跑 3 次 → PASS=8 FAIL=1 | basicReturn=123（完全一致）
```

---

## 3. 关键结论

### 3.1 JIT 可用的路径已确认：路径 C（RW→RX 分步映射）

**不需要任何受限权限、不需要 AGC 的 JIT ACL 审批。**

核心事实：

1. **代码内存申请、写入、提交、执行、重建全部成功**；
2. **代码修补可行** —— RX→RW→改→RX 往返 3 次，结果正确
   （这是 JIT 块链接与失效逻辑的前提）；
3. **全程零 AVC 拒绝** —— SELinux 与 XPM 都没有拦截。

这与从策略源码得出的预测**精确吻合**：

```
hap_domain.te:58   allow hap_domain self:process execmem;
domain.te:297      neverallow { domain -appspawn -hap_domain ... } ... execmem;
```

→ 预测「`hap_domain` 被允许匿名可执行内存」，实测「`debug_hap` 域下成功」。
**策略解读通过了真机验证。**

### 3.2 JITFort 确认不可用（路径 A 关闭，但无影响）

真机上 `MAP_JIT`/FORT 标志返回 **`EINVAL`（内核明确拒绝）**；
而模拟器上是**被静默忽略**。

| | 模拟器 | 真机 |
|---|---|---|
| 传入 FORT 标志 | 静默忽略（映射仍成功） | **`EINVAL` 明确拒绝** |

真机内核**显式校验**该标志，与真机存在
`/proc/sys/kernel/jitfort/jitfort_mode`（root-only）一致。

**但这对我们无影响**：路径 C 用标准 `mmap` + `mprotect`，不依赖 JITFort。

### 3.3 判据纠正（先前的一处错误）

早期曾把「公开 NDK 无 JITFort 接口」当作「JIT 不可用」的证据 ——
**这混淆了两个独立问题**：

| 问题 | 答案 |
|---|---|
| 能否调用 JITFort？（ArkTS JS 引擎专用接口） | ❌ 三方无接口（已确认） |
| **能否用标准 mmap/mprotect 做自研 JIT？** | ✅ **能（真机已验证）** |

正确判据是**本 app 所在 SELinux 域的授权**，与其它应用、
与 JITFort 是否存在**都无关**。

---

## 4. ⚠️ 适用范围：本次验证的是 **debug 签名**

**必须明确说明**，因为这直接影响产品形态：

```
profile type         : debug
真机 appProvisionType: debug
真机 debug 标志       : true
apl                  : normal
```

### 4.1 为什么正式签名可能不同

SELinux 策略中两处 neverallow 的豁免名单**不一致**：

```
domain.te:354  neverallow { domain developer_only(`-debug_hap_attr -normal_hap ...') ... }
                 self:xpm { exec_no_sign };
                 ← normal_hap 被豁免

domain.te:355  neverallow { domain developer_only(`-debug_hap_attr -input_debug_hap')
                 debug_only(`-su') -isolated_render } self:xpm { exec_anon_mem };
                 ← normal_hap 未在豁免名单中
```

即 `xpm:exec_anon_mem` 这一项，**`debug_hap` 被豁免而 `normal_hap` 没有**。

### 4.2 但也有反面证据（应偏乐观）

- `hap_domain.te:58` 的 `allow hap_domain self:process execmem` **同时覆盖
  `normal_hap` 与 `debug_hap`**（`normal_hap` 通过 typeattribute 属于 `hap_domain`）；
- 本次实测 `mmap(RWX)` 在 debug_hap 下**被允许**，且零 AVC ——
  说明该设备的 XPM **并未**普遍拦截匿名可执行内存。

### 4.3 结论：需单独验证正式签名

| 签名形态 | 状态 |
|---|---|
| **debug 签名** | ✅ **已实测通过** |
| **release 签名**（AGC 发布证书 + 发布 Profile） | ⚠️ **未验证，需单独测** |

**这是阶段 2 之前必须补的一项** —— 产品最终要上架，release 签名是硬性要求。
若 release 被拒，需立即走 AGC 渠道澄清，而不是等移植完成才发现。

---

## 5. 阶段关口判定

| 关口 | 条件 | 判定 |
|---|---|---|
| 阶段 0 → 1 | 找到三方 HAP 可用的 JIT 路径，否则停止大规模移植 | 原判据（无 JITFort 接口）已被**路径 C 的可用性**推翻 |
| **阶段 1 → 2** | **真机上受支持的 JIT 路径成功执行生成代码** | ✅ **通过**（返回 123） |

→ **可以进入阶段 2。**

**建议并行前置**：开工移植的同时，尽快验证 release 签名下的 JIT（§4.3），
以免产品形态被卡。

---

## 6. 对阶段 3 的直接输入

真机已确认的能力，阶段 3 实现 HarmonyOS 后端时可直接依赖：

| 能力 | 状态 | 备注 |
|---|---|---|
| `mmap` 匿名 RW | ✅ | 标准接口 |
| `mprotect` RW→RX | ✅ | **W^X 合规路径** |
| `mprotect` RX→RW（回写） | ✅ | 代码修补必需 |
| `__builtin___clear_cache` + `dsb ish; isb` | ✅ | 指令缓存同步有效 |
| 跨线程执行 | ✅ | 4 线程并发无问题 |
| `munmap` 后重建 | ✅ | 代码缓存释放/重建可行 |
| `MAP_JIT`/FORT 标志 | ❌ | `EINVAL`，**不要用** |

**与 ARMSX2 现有抽象的对应**：
ARMSX2 已有 `HostSys::BeginCodeWrite/EndCodeWrite` 平台接口，
其 iOS `JitMode::Legacy` 用的**正是 mprotect 往返** ——
与本次真机实测**通过的路径完全同构**。

→ 阶段 3 实现 HarmonyOS 后端时，可**照 iOS Legacy 模式实现**，
而非发明新机制。**但注意**：mprotect 往返有性能代价，
阶段 5 必须实测其对 PS2 模拟的影响（这是路径 C 的主要代价）。

---

## 7. 复现方法

```bash
# 前提：DevEco 已为本工程生成签名材料（File > Project Structure > Signing Configs）
bash stage1-jitprobe/scripts/verify-on-device.sh
```

脚本自动完成：构建 → 签名 → 安装真机 → 启动 → 抓取结果与 AVC 记录。

**签名材料**（由 DevEco AutoSign 生成，绑定 `com.hps2.jitprobe`）：

```
~/.ohos/config/default_stage1-jitprobe_*.p12 / .cer / .p7b
```

DevEco 口令解密工具：`stage1-jitprobe/scripts/devpwd.js`（已实测可用）。
