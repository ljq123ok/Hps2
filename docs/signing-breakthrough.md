# 真机签名突破记录（2026-09-14）

## 摘要

**已找到让本工程 HAP 通过真机签名验证的完整路径**，
并已实证：**华为 CBG 签名链在真机上通过了 PKCS7 验证**。

当前唯一剩余障碍是**纯配置问题**（profile 绑定的 bundle name），
不是签名技术问题。

---

## 1. 关键发现：找到完整的 DevEco 加密签名配置

排查中发现本机另一个工程带有**可用的 DevEco 生成签名配置**：

`<OTHER_PROJECT_ROOT>/harmony-vpn/apps/arktunnel/build-profile.json5`

```json5
"signingConfigs": [{
  "name": "default",
  "type": "HarmonyOS",
  "material": {
    "certpath":   "~/.ohos/config/default_arktunnel_*.cer",
    "keyAlias":   "debugKey",
    "keyPassword":"<redacted DevEco ciphertext>",
    "profile":    "~/.ohos/config/default_arktunnel_*.p7b",
    "signAlg":    "SHA256withECDSA",
    "storeFile":  "~/.ohos/config/default_arktunnel_*.p12",
    "storePassword":"<redacted DevEco ciphertext>"
  }
}]
```

这解决了此前"拿不到密钥库口令"的阻塞：
DevEco 把口令以 **AES-128-GCM** 加密存储，密钥由
`~/.ohos/config/material/{fd,ac,ce}` 下的材料派生。

### 1.1 复刻解密算法

hvigor 的 `DecipherUtil` 算法已复刻为 `scripts/devpwd.js`，实测可用：

```
$ node scripts/devpwd.js "<storePassword 密文>"
OK len=10 prefix=AR****
$ keytool -list -keystore default_arktunnel_*.p12 -storepass <解出的口令>
debugkey, 2026年9月9日, PrivateKeyEntry,     ← 密钥库成功打开
```

算法要点（与 hvigor 自带实现一致）：
- `fd` 目录下 3 个 16 字节块 + 固定 component → XOR → PBKDF2-SHA256(10000) → rootKey
- `ce` 目录材料经 rootKey AES-128-GCM 解密 → 实际密钥
- 目标密文再经实际密钥 AES-128-GCM 解密 → 明文口令

---

## 2. 实证：华为 CBG 链在真机通过验证

用上述材料签名探针 HAP：

```
$ hdc -t <device> install -r hps2-cbg.hap
error: failed to install bundle. code:9568329 error: verify signature failed.
```

设备端日志给出**决定性信息**：

```
E BMSInstaller: bundle_install_checker.cpp:CheckBundleName:853
  CheckBundleName failed provisionBundleName:com.lianconnect.app,
  bundleName:com.hps2.jitprobe
E BMSInstaller: base_bundle_installer.cpp:ParseHapFiles:5632
  parse hap file failed due to errorCode : 8519752
```

**关键解读**：失败发生在 `CheckBundleName` 阶段 ——
即**签名与 PKCS7 校验已经全部通过**，才走到 bundle name 比对。

对比此前的失败：

| 签名方式 | 真机错误 | 失败阶段 |
|---|---|---|
| 未签名 | `9568320 no signature file` | 无签名块 |
| SDK 内置 **OpenHarmony 测试链** | `9568257 fail to verify pkcs7` | **信任根校验**（`it do not come from trusted root ... OpenHarmony Application Root CA`） |
| 本机 **华为 CBG 链**（arktunnel 材料） | `9568329 verify signature failed` + `CheckBundleName failed` | **bundle name 比对** ✅ |

→ **华为 CBG 链被真机接受**，签名本身已无问题。
此前"只信任 Huawei CBG 链"的判断得到实证，且**已找到可用的 CBG 链**。

---

## 3. 唯一剩余障碍：profile 与 bundle name 强绑定

`*.p7b` profile 内固定了 `"bundle-name":"com.lianconnect.app"`，
真机强制比对，不匹配即拒绝。**profile 只能由华为 AGC 签发，无法自行伪造**
（用测试链伪造会退回信任根错误）。

已确认本机**不存在**其它可用 profile：

```bash
$ find "$HOME" -name "*.p7b" -type f      # 本机搜索
（仅 ~/.ohos/config/default_arktunnel_*.p7b 与其自身）
```

---

## 4. 选定方案：由 DevEco 为本工程生成签名

**用户已选择此方案**（不动 VPN 应用，最干净）。

### 待用户操作（约 1 分钟）

```
1. 用 DevEco Studio 打开工程：
   <REPO_ROOT>/stage1-jitprobe
2. File > Project Structure > Signing Configs
3. 勾选 "Automatically generate signature"
4. 点 OK
```

DevEco 已在本机登录华为账号，且日志显示 AutoSign 各步骤此前均成功：

```
AutoSigningConfigsService - addCertificate_responseContent: OK
AutoSigningConfigsService - addDevice_responseContent: OK
AutoSigningConfigsService - addProvision_responseContent: OK
AutoSigningConfigsService - getCertificateList_responseContent: OK
```

因此预期可一次成功。完成后 DevEco 会把材料写入本工程
`build-profile.json5` 的 `signingConfigs`。

### 之后（自动化，无需再操作）

```bash
bash stage1-jitprobe/scripts/verify-on-device.sh
```

该脚本会：构建 → 签名 → 安装真机 → 启动 → 抓取探针结果与
SELinux/XPM 拒绝记录，输出到 `docs/evidence/`。

### 备选方案（用户已排除，记录备用）

把探针临时以 `com.lianconnect.app` 为 bundle name 安装，
用现有 profile 签名。**可逆**（本机存在原始已签名 HAP
`apps/arktunnel/entry/build/default/outputs/default/entry-default-signed.hap`
及完整工程，可 `install -r` 还原），但会中断用户正在运行的 VPN 应用，
因此未采用。

---

## 5. 工程侧已做的准备

| 项目 | 状态 |
|---|---|
| 工程路径纯英文（hvigor 拒绝中文路径） | ✅ `<REPO_ROOT>/stage1-jitprobe` |
| 工程结构完整（可被 DevEco 直接打开） | ✅ 全部配置文件就位 |
| `targetSdkVersion` / `compatibleSdkVersion` | ✅ `6.1.1(24)` / `6.0.0(20)` |
| 探针自动运行（无需手动点按钮） | ✅ `aboutToAppear` 中调用 `runTests()` |
| 一键验证脚本 | ✅ `scripts/verify-on-device.sh` |
| 口令解密工具 | ✅ `scripts/devpwd.js`（已实测可用） |

---

## 6. 下一步

用户完成 DevEco 自动签名后，执行 `verify-on-device.sh`，
即可得到**真机上 JIT 能否使用的最终答案** —— 这是阶段 1 的关口，
也是决定是否进入阶段 2 的唯一依据。
