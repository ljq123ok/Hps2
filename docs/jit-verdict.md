# JIT 能否使用？—— 当前证据下的结论

**记录时间**：2026-09-14
**目标设备**：HUAWEI Pura X View（`VOL-AL00`）/ OpenHarmony-7.0.0.105 / API 26 / arm64-v8a
**状态**：真机验证**未完成**（阻塞于 HAP 签名信任根）

---

## 1. 直接回答

> **截至本记录：JIT 无法确认为可用。**
>
> 在"官方支持路径"上，证据**偏向否定**；
> 唯一有希望、且**不依赖官方审批**的路径（RW→RX 分步映射）
> **尚未在真机验证** —— 被签名问题阻塞，而非技术性失败。

这个回答是**分路径**的，四条候选路径的处境完全不同，不能一句"能"或"不能"概括。

---

## 2. 四条候选路径的逐条结论

| # | 路径 | 需受限权限？ | 模拟器实测 | 真机实测 | 结论 |
|---|---|---|---|---|---|
| **A** | **JITFort / `MAP_FORT`**（官方机制） | 需 `ALLOW_USE_JITFORT_INTERFACE` | 不可用 | 不可用 | ❌ **无接口可调** |
| **B** | **W+X 直接映射** | 需 `ALLOW_WRITABLE_CODE_MEMORY` | ✅ 允许 | 未验证 | ⚠️ 文档限定平板/2in1，本机是 `phone` |
| **C** | **RW→RX 分步映射**（W^X 合规） | **不需要任何受限权限** | ✅ **全部通过** | **未验证（被签名阻塞）** | 🟡 **唯一有希望的路径** |
| **D** | **JSVM 内置 JIT** | 需 AGC ACL | — | — | ❌ 语义不覆盖本项目 |

### 路径 A：JITFort / `MAP_FORT` —— ❌ 无接口可调

**证据（三重独立）**：

1. **公开 NDK 无该接口**：对 `sysroot/usr/include` 全文搜索 `jitfort` / `MAP_FORT`
   → **无结果**；对全部 NDK `.so` 的 `nm -D` 导出符号搜 `fort` → **无结果**。
2. **`MAP_FORT` 不是内核公开标志**：源码中它是 ArkTS 引擎私有常量
   `JitFort::MAP_JITFORT = 0x1000`，且 `0x1000` 已被 `MAP_EXECUTABLE` 占用（语义无关）。
   模拟器实测传入该标志被内核**静默忽略**（不报错、也不生效）。
3. **真机内核确实有该机制，但为 root-only**：

```
$ hdc shell ls -la /proc/sys/kernel/jitfort/
dr-xr-xr-x 2 root root 0 2026-09-13 20:46 .
-????????? ? ? ? ? jitfort_mode            ← 存在
$ hdc shell cat /proc/sys/kernel/jitfort/jitfort_mode
Permission denied                           ← 三方无法访问
```

**结论**：机制真实存在（不是纯用户态概念），但**只对系统 JS 引擎开放**，
三方应用**没有可调用的接口**。任务书已明确禁止绕过签名/提权/内核漏洞的方案，
本审计严格遵守，不尝试任何越权手段。

### 路径 B：W+X 直接映射 —— ⚠️ 形态受限

- 权限 `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`：
  `system_basic` + `system_grant`，官方文档明确"**当前仅平板、2in1 设备应用可申请**"。
- 真机 `const.product.devicetype = phone` → **预计不可申请**（未验证，因阻塞在签名）。
- 模拟器上 RWX **被允许**，但该结论**不可外推**，原因见 §3。

### 路径 C：RW→RX 分步映射 —— 🟡 最值得验证

**这是唯一不需要任何受限权限、也不需要 AGC 审批的路径**，
因为它全程**不出现 W+X 同时有效**（每次只 W 或只 X），符合 W^X 安全模型。

模拟器实测（OpenHarmony-6.1.1.125 / API 24）：

| 测试 | 结果 |
|---|---|
| `mmap(RW)` → 写入 → `mprotect(RX)` → 执行 | ✅ **返回 123** |
| 重复执行 10000 次 | ✅ |
| **代码修补**（RX→RW→改→RX，3 轮） | ✅ 11,222,3333 |
| 跨线程 4×5000 | ✅ |
| 释放后重建 3 轮 | ✅ |

**真机未测** —— 探针 HAP 因签名信任根问题无法安装（见 §4）。

**旁证（有利）**：ARMSX2 已有 `HostSys::BeginCodeWrite/EndCodeWrite` 平台抽象，
其 iOS `JitMode::Legacy` 用的**正是这套 mprotect 往返**，
说明该方案在真实 JIT 场景下可用（代价是性能，需阶段 5 实测）。

### 路径 D：JSVM 内置 JIT —— ❌ 不适用于本项目

官方唯一指明的 JIT 授权通道（`jsvm-apply-jit-profile.md`）要求：
通过 ACL 申请 `ALLOW_EXECUTABLE_FORT_MEMORY`，**向 AGC 说明在 JSVM 上使用 JIT 的理由**。
其语义是"允许**系统 JS 引擎**申请 FORT 内存"。

PS2 模拟器的 EE/IOP/VU 重编译器是**纯原生 C++**，不经过 JSVM，
**该权限不覆盖本场景**。且申请到的 ACL 仅限调试、不可上架。

---

## 3. 为什么模拟器结果不能外推（方法学关键）

真机与模拟器**内核根本不同**，这是实测确认的：

| | 模拟器 | 真机 |
|---|---|---|
| 内核 | **Linux 5.10.210**（标准 Linux） | **HongMeng Kernel 1.13.0** |
| `jitfort` 节点 | **不存在**（`No such file or directory`） | **存在**（root-only） |
| `xpm` 节点 | 不存在 | 存在（root-only） |
| 应用 SELinux 域 | `o:r:debug_hap:s0`（调试域） | 未知（调试安装被签名阻挡） |

因此：

- 模拟器上"W+X 被允许"**不能推断真机也允许** ——
  真机内核有 JITFort 这一模拟器没有的机制，说明两者代码内存策略本就不同；
- 模拟器跑在**调试域**，华为商业版真机对代码内存的策略明显更严
  （这正是 `system_basic` 系列权限存在的原因）。

**任务书也明确：模拟器成功不计作真机成功。** 本审计严格遵守这一条。

---

## 4. 当前阻塞：不是"JIT 不行"，而是"装不上"

探针已构建、已签名、在模拟器可运行，但**真机拒绝安装**：

| 签名方式 | 真机结果 |
|---|---|
| 未签名 | `9568320 no signature file` |
| SDK 内置 **OpenHarmony 测试链**（自校验 `verify-app` 通过） | `9568257 fail to verify pkcs7 file` |

设备端原因明确：

```
E HapVerify: it do not come from trusted root,
  issuer: C=CN, O=OpenHarmony, ..., CN=OpenHarmony Application Root CA
```

**真机只信任 Huawei CBG 签发链。** 排除实验证明签名流程本身没错：
同一个已签名 HAP **装到模拟器成功**，且探针 `PASS=8 / FAIL=1`、返回 `123`。

→ 因此**路径 C 的真机结论目前是"未知"，而非"失败"**。
这两者有本质区别，不应混为一谈。

---

## 5. 决定性问题

**一句话**：路径 C（`mmap(RW)` → 写 → `mprotect(RX)` → `__builtin___clear_cache`）
在真机上是否被允许？

- **若允许** → JIT **可用**，且不需要任何受限权限、不需要 AGC 审批；
  后续阶段 5 需实测 mprotect 往返的性能代价（参考 iOS Legacy 模式的已知开销）。
- **若拒绝** → 公开路径**全部关闭**，必须走官方渠道
  （向 AGC 澄清 `ALLOW_EXECUTABLE_FORT_MEMORY` 能否覆盖非 JSVM 原生 JIT），
  在此之前不展开大规模移植。

阶段 1 探针已覆盖这个问题所需的全部测试面，只需**在真机上跑一次**。

---

## 6. 修正记录：一个我自己犯的方法学错误

本轮尝试"扫描真机 244 个已安装应用是否持有 JIT 类权限"时，
脚本输出了"**0 个应用持有**"。

**该结果无效。** 复查发现：循环执行期间**真机掉线**，
`bm dump` 对每个应用只返回 **46 字节**的错误信息（`Device not found or connected`），
而脚本把"grep 没匹配到"误判为"没有该权限"——**典型的假阴性**。

已用对照验证方法本身可行：对 `com.aobai.cyclingcomputer` 完整 dump 时
确实会输出 `ohos.permission.*` 条目（该应用有 `ACCESS_BLUETOOTH`）。

**教训（与阶段 0 的 `rg` 事件同类）**：批量循环中必须校验每次调用的**有效性**
（如输出长度/错误标记），不能只看 grep 结果。**该扫描需在设备稳定后重做**，
目前不将其作为证据。

同理，此前对 5 个特定应用的权限查询也**标注为待复核**。

---

## 7. 需要什么才能给出最终答案

**只需一件事**：为 `com.hps2.jitprobe` 提供华为签发的 Profile（见 `STATUS.md` §6.1 ②）。

拿到后我会立即：
1. 安装探针到真机；
2. 抓取 8 项测试的真机结果（明确区分"允许/拒绝/errno"）；
3. 把本文件的"未验证"改写为实测结论；
4. 据此判定是否进入阶段 2。

> 备注：真机 USB 连接在本轮取证末尾**已物理断开**
> （`hdc list targets` 中 USB 设备消失，`system_profiler` 也无该设备），
> 需要重新连接并授权 USB 调试后才能继续。
