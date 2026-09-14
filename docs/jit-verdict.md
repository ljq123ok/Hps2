# JIT 能否使用？—— 聚焦本项目的结论（基于 SELinux 策略源码）

**记录时间**：2026-09-14（第二版）
**回答对象**：**本项目的 HAP**（`com.hps2.jitprobe`）能否在真机启用 JIT
**证据来源**：`openharmony/security_selinux_adapter` 源码（clone 于 `upstream/sepolicy`）

> **本版修正上一版。** 上一版从"公开 NDK 无 JITFort 接口"推出"JIT 大概率不可用"，
> **不完整** —— 它只查了**用户态 API 层**，没查**内核/SELinux 授权层**。
> 补查后，结论需要修正为「**有明确的正面证据 + 一个明确的未知风险点**」。

---

## 0. 命题澄清

正确的命题是：**我们这一个 app 能不能启用 JIT。**

判据不是"别人有没有 JIT 权限"，而是**我们的 app 所在的 SELinux 域被授予了什么**。
本项目 HAP 属于 `hap_domain`（详见 §2），所以下面的策略结论
**直接适用于本项目**，与设备上其它应用无关。

---

## 1. 直接回答

| 层 | 结论 | 性质 |
|---|---|---|
| **SELinux `execmem`** | ✅ **明确允许**（含我们的域） | **确凿策略证据** |
| **XPM `exec_anon_mem`**（HongMeng 专有） | ⚠️ **是否存在拦截、是否放行，无法从开源策略确定** | **未知风险点** |

> **净结论：仍待真机实测，但已从上一版的"偏向否定"变为"有正面证据、存一未知闸门"。**

---

## 2. 正面证据：SELinux 明确授予 HAP `execmem`

策略源码两条规则：

```
sepolicy/base/public/hap_domain.te:58
    allow hap_domain self:process execmem;

sepolicy/base/public/domain.te:297
    neverallow { domain -appspawn -hap_domain -isolated_render
                -rgm_violator_execmem -vpn_isolate_hap } self:process execmem;
```

**为什么这直接适用于本项目** —— `hap_domain` 是应用域超集属性，
我们 app 无论哪种签名都在其中：

```
sepolicy/base/public/hap_domain.te:16-19, 28, 35
    type normal_hap, domain;                 ← 正式签名应用 → 属于 hap_domain
    type debug_hap,  domain, hap_domain;     ← 调试签名应用 → 属于 hap_domain
    typeattribute normal_hap hap_domain;
    typeattribute system_core_hap  hap_domain;
    typeattribute system_basic_hap hap_domain;
```

**语义**：SELinux 的 `process:execmem` 管的正是
**匿名可执行内存的创建与 `PROT_EXEC` 授予**（即 `mmap` + `mprotect` 让内存可执行）。

- 第 58 行是**正向 allow** → 我们的域**被授予** JIT 所需的 LSM 权限；
- 第 297 行是全局禁令，但 `-hap_domain` 把**我们整个应用域显式排除**在外。

**结论**：**SELinux 层不阻止本项目做 JIT。**
这与"公开 NDK 无 JITFort 接口"不矛盾 —— 那是 **API 层**缺封装，
这里是 **LSM 层**允许，两者是不同层次。

**这同时解释了模拟器为何跑通**：模拟器是标准 Linux，
只有 SELinux 这一层，而这一层**放行**，所以 `mmap(RW)→`写→`mprotect(RX)`
全流程成功、执行返回 `123`。

---

## 3. 未知风险点：XPM（HongMeng 专有第二道闸门）

真机存在 `/proc/sys/kernel/xpm/xpm_mode`（**模拟器完全没有此节点**）。
策略中两条与代码执行直接相关的禁令：

```
sepolicy/base/public/domain.te:353-355
neverallow { domain developer_only(`-debug_hap_attr -normal_hap -input_hap -input_debug_hap')
            debug_only(`-su') -rgm_violator_exec_no_sign } self:xpm { exec_no_sign };
neverallow { domain developer_only(`-debug_hap_attr -input_debug_hap')
            debug_only(`-su') -isolated_render } self:xpm { exec_anon_mem };
```

`developer_only()` 宏（`glb_te_def.spt:65`）：

```
define(`developer_only', ifelse(build_with_developer, `enable', $1, ))
```
**这是编译期开关** —— 仅当固件以"开发者模式"构建时，括号内内容才生效。

**这带来一个必须诚实说明的推论**：

| 固件构建类型 | `exec_anon_mem` 禁令的豁免范围 |
|---|---|
| `build_with_developer = enable` | 除 `su`/`isolated_render` 外，**额外**豁免 `debug_hap_attr`、`input_debug_hap` |
| `build_with_developer ≠ enable`（**商用固件大概率如此**） | 仅豁免 `su`、`isolated_render`；**任何 hap 域都不被豁免** |

即：**"调试签名 app 有优势"这一说法，只在开发者模式构建的固件上成立**。
华为商用固件很可能不是该构建，届时该豁免不适用。

**但更关键的一点必须说清**：

> **公开策略中 `xpm:exec_anon_mem` 的显式 `allow` 只有两处** ——
> `su` 与 `isolated_render`。**没有任何一条给 hap 的 allow。**
>
> 而 `neverallow` 的作用是**禁止策略作者写出 allow**。
> 所以在开源这部分策略里，**不存在**授予 hap `exec_anon_mem` 的规则。

**然而这仍不足以断定"真机会拒绝"，原因有三**：

1. **不确定 XPM 是否真的拦截 `mmap`/`mprotect` 的匿名可执行内存**。
   `xpm` 权限族（`exec_no_sign`、`exec_in_jitfort`、`exec_allow_ownerid`
   等）看起来更像是**代码来源认证**机制（管"执行哪来的代码"），
   未必等同于拦截匿名映射。**这一点无法从公开源码判定。**
2. **华为厂商策略未开源**，可能在其私有部分另有规则。
3. `su` 被授予 `exec_anon_mem` 说明该能力在设备上**确实可用**，
   只是授权范围未知。

**因此这是一个"存在闸门、走向未知"的局面 —— 必须真机实测，不能靠源码推断。**

---

## 4. 三套机制分工（此前混淆的根源）

| 机制 | 作用域 | 模拟器 | 真机 | 对本项目的意义 |
|---|---|---|---|---|
| **SELinux `execmem`** | 标准 LSM | ✅ 有 | ✅ 有 | ✅ **允许**我们（§2） |
| **XPM `exec_anon_mem`** | HongMeng 专有 | ❌ **无** | ✅ 有 | ⚠️ **第二道闸门，走向未知**（§3） |
| **JITFort (`jitfort_mode`)** | ArkTS JS 引擎专用 | ❌ 无 | ✅ 有 | ❌ 三方无接口可调（结论不变） |

**这解释了全部观测**：

- 模拟器跑通 → 只有 SELinux 层，且放行；
- 真机未知 → **多一道 XPM**，无法外推；
- NDK 无 JITFort API → 那是**给 JS 引擎的专用通道**，与"能否用 mmap 做 JIT"
  是**两个独立问题**。

上一版把第三个问题的答案错当成了对整题的答案。

---

## 5. 决定性问题（唯一）

**在真机 `debug_hap` 域下：**

```
mmap(PROT_READ|PROT_WRITE)  → 写入 AArch64 指令
  → mprotect(PROT_READ|PROT_EXEC)  → __builtin___clear_cache + dsb ish; isb
  → 执行并校验返回 123
```
**是否成功？**

- **成功** → JIT 可用（至少开发形态），可进阶段 2；
- **失败** → 抓 AVC/XPM 拒绝记录，精确定位被哪一层拦下，
  据此决定是否走 AGC 渠道。

阶段 1 探针已覆盖该问题所需全部测试面（首次/重复/重建/跨线程/释放重建/
候选路径对照），**只需在真机上跑一次**。

**另需分别测两种签名**：
1. **调试签名** → 开发期能否用 JIT；
2. **正式签名**（需 AGC 发布证书）→ **产品能否用 JIT**。

产品最终要上架，第 2 项是硬性前置；两者结论**可能不同**，不能只测其一。

---

## 6. 阻塞：签名信任根（唯一待办）

| 签名方式 | 真机结果 |
|---|---|
| 未签名 | `9568320 no signature file` |
| SDK 内置 OpenHarmony 测试链（`verify-app` 自校验通过） | `9568257 fail to verify pkcs7 file` |

```
E HapVerify: it do not come from trusted root,
  issuer: C=CN, O=OpenHarmony, ..., CN=OpenHarmony Application Root CA
```

真机只信任 **Huawei CBG** 签发链。**排除实验已证明签名流程无误** ——
同一 HAP 装到模拟器成功，探针 `PASS=8 / FAIL=1`、返回 `123`。

**需要**：为 `com.hps2.jitprobe` 签发华为 Profile（DevEco 自动签名最省事），
并重新连接真机 USB（取证末尾已物理断开）。

---

## 7. 证据附录（可复核）

```bash
# 我们所属的域被授予 execmem
upstream/sepolicy/sepolicy/base/public/hap_domain.te:58
    allow hap_domain self:process execmem;

# 我们整个域被排除在 execmem 禁令之外
upstream/sepolicy/sepolicy/base/public/domain.te:297
    neverallow { domain -appspawn -hap_domain ... } self:process execmem;

# 我们属于 hap_domain（两种签名都算）
upstream/sepolicy/sepolicy/base/public/hap_domain.te:16-19
    type normal_hap, domain;
    type debug_hap,  domain, hap_domain;
    typeattribute normal_hap hap_domain;

# XPM 两道闸门（无 hap 的 allow，只有 neverallow 及其豁免）
upstream/sepolicy/sepolicy/base/public/domain.te:353-355

# developer_only 是编译期宏
upstream/sepolicy/sepolicy/base/public/glb_te_def.spt:65
```

复现：
```bash
git clone --depth 1 https://github.com/openharmony/security_selinux_adapter.git
grep -rn "execmem" --include="*.te" sepolicy/
grep -rn "exec_anon_mem" --include="*.te" sepolicy/
```

---

## 8. 策略解读的独立交叉验证

我对策略的解读**被一次独立观测所证实**：

- **预测**：按 `hap_domain.te:58`（`allow hap_domain self:process execmem`），
  `debug_hap` 域应被允许创建并执行匿名可执行内存。
- **独立观测**：模拟器（OpenHarmony-6.1.1.125，同为
  `security_selinux_adapter` 策略）上，探针应用运行于
  `o:r:debug_hap:s0` 域（`SELinux = Enforcing`），且
  **`mmap(RW)`→写→`mprotect(RX)`→执行 全流程成功，返回 123**。

即：**策略文本预测的行为与实测行为一致**。这显著提高了
"该条策略确实管匿名可执行内存"这一解读的可信度，
而不是我对方便的字符串做的过度解读。

**但仍须注意边界**：模拟器 **没有 XPM 节点**，
所以该验证**只覆盖了 SELinux 这一层**，
无法验证 XPM 层的行为 —— 那仍需真机实测。
