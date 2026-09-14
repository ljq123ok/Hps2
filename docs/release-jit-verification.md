# Release 签名 JIT 验证 —— 准备就绪，待 AGC 材料

**状态**：🟡 本机侧全部就绪，**等待用户在 AGC 获取发布证书与发布 Profile**

---

## 1. 为什么必须做这一步

阶段 1 真机验证**通过**，但用的是 **debug 签名**。而 SELinux 域由签名类型决定 ——
这是**真机实测的对照证据**，不是推测：

| 应用 | 签名来源 | 真机 SELinux 域 |
|---|---|---|
| 我们的探针 | debug 签名 | `o:r:debug_hap:s0` |
| 支付宝（AppGallery 正式发布） | release 签名 | `o:r:normal_hap:s0` |

而策略中 `xpm:exec_anon_mem` 的豁免名单**只含 `debug_hap`**，不含 `normal_hap`：

```
domain.te:355  neverallow { domain developer_only(`-debug_hap_attr -input_debug_hap')
                 debug_only(`-su') -isolated_render } self:xpm { exec_anon_mem };
                 ← normal_hap 不在豁免名单中
```

### 1.1 更直接的证据：appspawn 源码中的实际代码分叉

在 `startup_appspawn` 源码（`modules/common/appspawn_common.c` 的
`SetXpmConfig()`）中，debug 与 release 在 **XPM 初始化时就走不同分支**：

```c
char *provisionType = GetProvisionType(property, &len);
int jitfortEnable = IsJitFortModeOn(property) ? 1 : 0;
int idType = PROCESS_OWNERID_APP;

if (xpmIdType != NULL && len == sizeof(uint32_t)) {
    idType = (int)*xpmIdType;
} else if (strcmp(provisionType, PROVISION_TYPE_DEBUG) == 0) {
    idType = PROCESS_OWNERID_DEBUG;              // ← debug 签名走这条
} else if (ownerInfo == NULL) {
    idType = PROCESS_OWNERID_COMPAT;
} else if (CheckAppMsgFlagsSet(property, APP_FLAGS_TEMP_JIT)) {
    idType = PROCESS_OWNERID_APP_TEMP_ALLOW;     // ← 存在"临时放行"机制
}

struct XpmInitParam xpmInitParam = XPM_INIT_PARAM_DEFAULT;
xpmInitParam.enableJitFort = jitfortEnable;
xpmInitParam.idType = (uint32_t)idType;
...
InitXpmWithParam(&xpmInitParam);
```

另有一条全局开关（同文件 `SpawnLoadConfig`）：

```c
content->flags |= CheckEnabled("persist.security.jitfort.disabled", "true")
                    ? 0 : APP_JITFORT_MODE;
```

**含义**：
- `provisionType` 直接决定 `idType` —— debug 与 release **代码路径不同**，
  所以必须实测，不能由 debug 结果外推；
- 还有 `APP_FLAGS_TEMP_JIT`（`PROCESS_OWNERID_APP_TEMP_ALLOW`）
  这种"临时放行"机制，说明 XPM 确实按应用逐个管控；
- 存在 `persist.security.jitfort.disabled` 全局开关。

**这些都不改变结论的必要性，反而加强它：release 必须单独测。**

### 1.2 反面证据（应偏乐观）

`hap_domain.te:58` 的 `allow hap_domain self:process execmem` **同时覆盖
`normal_hap` 与 `debug_hap`**；且本次实测 `mmap(RWX)` 在真机被允许、零 AVC。
所以 `normal_hap` 下**很可能**也通过 —— 但"很可能"不是结论，必须实测。

---

## 2. 本机侧已完成（无需用户参与）

| 项目 | 状态 | 位置 |
|---|---|---|
| release 密钥对（ECC P-384） | ✅ 已生成并验证 | `.release-signing/hps2-release.p12` |
| CSR（提交给 AGC） | ✅ 已生成并自校验通过 | `.release-signing/hps2-release.csr` |
| release 签名脚本 | ✅ 已就绪，语法检查通过 | `stage1-jitprobe/scripts/sign-release.sh` |
| 私钥入库防护 | ✅ 已加入 `.gitignore` 并验证生效 | `.gitignore` |

密钥参数与 debug 证书对齐：
```
签名算法 : SHA384withECDSA
公钥算法 : id-ecPublicKey (384 bit), secp384r1 / NIST P-384
CSR 主体 : C=CN, O=HPS2, OU=PS2Emulator, CN=HPS2 Release
```

**密钥库口令**：本次为便于自动化固定为 `Hps2Rel2026`
（仅用于本地真机验证；如需更严可自行更改并同步脚本调用）。

> ⚠️ 私钥 `hps2-release.p12` 已在 `.gitignore` 中排除，**不会进入版本库**。

---

## 3. 需要用户在 AGC 完成的操作

包名 `com.hps2.jitprobe` **已在 AGC 注册**（阶段 1 已确认）。

### 步骤 1：上传 CSR，申请**发布证书**

```
AGC 控制台 → 我的应用 → com.hps2.jitprobe
  → 左侧「证书、APP ID 和 Profile」
  → 「证书」标签 → 「新增证书」
  → 证书类型：发布证书
  → 上传 CSR：.release-signing/hps2-release.csr
  → 提交后下载签发的 .cer，命名为 hps2-release.cer 放入 .release-signing/
```

CSR 文件路径：
```
<USER_HOME>/Documents/deepseek/Hps2/.release-signing/hps2-release.csr
```

### 步骤 2：申请**发布 Profile**

```
同一页面 → 「Profile」标签 → 「新增 Profile」
  → Profile 类型：发布（Release）
  → 选择上一步的发布证书
  → 提交后下载 .p7b，命名为 hps2-release.p7b 放入 .release-signing/
```

### 步骤 3：告诉我一声

拿到两个文件后我立即执行：

```bash
HPS2_REL_PWD=Hps2Rel2026 bash stage1-jitprobe/scripts/sign-release.sh
```

然后安装真机、抓 `normal_hap` 域下的探针结果与 AVC 记录。

---

## 4. 预期结果与应对

| 结果 | 含义 | 应对 |
|---|---|---|
| ✅ `normal_hap` 域下返回 123 | **产品形态可行** | 直接进阶段 2，JIT 风险归零 |
| ❌ 被拒（AVC/XPM 拒绝） | 产品形态受阻 | 立即走 AGC 渠道澄清 `ALLOW_EXECUTABLE_FORT_MEMORY` 能否覆盖非 JSVM 原生 JIT；**开发可继续**（debug 签名可用），但上架前必须解决 |
| ⚠️ 结果不稳定/偶发 | 需进一步定位 | 抓完整 AVC 与 XPM 日志，可能需要 `APP_FLAGS_TEMP_JIT` 类机制 |

**注意**：发布 Profile 通常**不绑定设备白名单**，理论上任何设备可装；
但正式发布形态还需经 AppGallery 审核。本步骤仅为**验证 JIT 可用性**，
不涉及上架流程。

---

## 5. 与阶段 2 的关系

**用户已决定：先补 release 验证，再正式进入阶段 2。**

这个顺序是对的 —— 理由：

1. **release 是产品硬性要求**，早暴露比移植完成后才发现好；
2. 若 release 被拒，阶段 2 的技术选型（是否必须依赖 mprotect 往返、
   是否需要申请 ACL）会**根本性改变**；
3. 验证成本低（材料已备好，只需用户两步 AGC 操作）。

**阶段 2 的准备工作可在等待期间并行推进**（不依赖 JIT 权限的部分）：
构建系统接入、平台层骨架、文件访问、线程、计时等。
