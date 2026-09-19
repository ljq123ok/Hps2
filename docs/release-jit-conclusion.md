# release 签名下 JIT 可用性 —— 实测结论

**日期**：2026-09-19
**方法**：AGC 申请发布证书 + 发布 Profile → 签名 → 真机安装 → 实测
**结论**：🔴 **release 签名（`normal_hap` 域）下 JIT 不可用**

---

## 1. 实测证据（决定性）

```
SELinux 域 : o:r:normal_hap:s0:x68,x335,x512,x868,x1024
JIT 状态   : 不可用
诊断       : 阶段=mprotect-rx  errno=22 (EINVAL)
```

UI 原文：

> 系统拒绝将内存标记为可执行（JIT 被拦截）
> 系统当前拒绝把内存标记为可执行。请重启手机后重试；若重启失败，
> 请反馈此错误码（EINVAL）。

**与 debug 签名（阶段 1）的对照**：

| 签名 | SELinux 域 | JIT |
|---|---|---|
| debug（DevEco AutoSign）| `o:r:debug_hap:s0` | ✅ 可用（PASS=8 FAIL=1）|
| **release（AGC 发布证书）** | **`o:r:normal_hap:s0`** | ❌ **不可用（EINVAL）** |

这把阶段 1 基于 SELinux 策略的**预测**变成了**实测事实**：

```
domain.te:297  neverallow { domain -appspawn -hap_domain ... } self:process execmem;
domain.te:355  neverallow { domain developer_only(`-debug_hap_attr -input_debug_hap')
                 debug_only(`-su') -isolated_render } self:xpm { exec_anon_mem };
                 ← normal_hap 不在豁免名单中
```

## 2. 过程中的关键技术发现：Profile 的分发类型决定能否侧载

这是本次最有价值的**可复用**经验。

### 2.1 首次尝试失败：`app_gallery` 不允许侧载

用标准「发布 Profile」签名后安装，被系统拒绝：

```
HapVerify: untrusted source app with release profile distributionType: 1
HapVerify: APP source is not trusted
```

安装错误码：`9568322 signature verification failed due to not trusted app source`

**根因**：该 Profile 的字段为

```json
"app-distribution-type": "app_gallery"
```

**应用市场分发类型禁止侧载** —— 只能从 AppGallery 下载安装。
这不是证书或签名错误，是华为的分发管控设计。

### 2.2 解决方案：「指定设备发布」Profile

在 AGC 创建 Profile 时，类型选**「指定设备发布」**，并绑定设备 UDID。
产出的 Profile：

```json
"app-distribution-type": "internaltesting"
"type": "release"
"bundle-name": "com.hps2.jitprobe"
"device-ids": ["<redacted-device-id>"]
```

**`internaltesting` 允许侧载安装** —— 实测 `install bundle successfully`。

### 2.3 三种 Profile 类型对照（实测）

| AGC 里的类型 | `app-distribution-type` | 能否 hdc 侧载 | JIT（release）|
|---|---|---|---|
| 发布 | `app_gallery` | ❌ 否 | —（装不上）|
| 调试 | `debug` | ✅ 是 | ✅ 可用 |
| **指定设备发布** | **`internaltesting`** | ✅ **是** | ❌ **不可用** |

> **「指定设备发布」是唯一能"侧载 + 走 release 分发链路"的方式**，
> 因此它是验证 release 行为的正确手段。

## 3. 对本项目产品形态的影响

**结论：双渠道包不是可选项，而是必需品。**

| 渠道 | 签名 | 域 | JIT | 可行性 |
|---|---|---|---|---|
| **GitHub 自签包** | 用户自行签名（debug 型）| `debug_hap` | ✅ | 完整体验 |
| **商店包** | 我们的 release 证书 | `normal_hap` | ❌ | **必须降级到解释器** |

用户早前提出的"GitHub 包自签跑 JIT / 商店包降级"策略
（`docs/distribution-strategy.md`）**被本次实测完全证实**。

## 4. 后续工作（依据本结论确定）

1. **商店包降级路径**：必须先补非 Apple 平台的解释器逃生门
   （见 `docs/distribution-strategy.md` §7.1 —— 当前 code memory 失败会
   直接 `return false`，上游的降级逻辑走不到）
2. **商店包必须显式告知用户**已降级（不能像上游那样静默切一行 Warning）
3. **解释器模式性能需实测** —— 若低到不可玩，商店包定位要重新考虑
4. **上架流程**：真实上架用 `app_gallery` Profile，与本验证用的
   `internaltesting` 不同，需另行准备
