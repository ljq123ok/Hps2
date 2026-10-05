# v0.14 P0 实施与验收记录

## P0-1：上游可复现

- `patches/upstream.json` 固定 ARMSX2 仓库和基线 SHA；`scripts/setup-upstream.sh` 在空目录恢复固定基线并应用补丁，重复运行时先用临时 Git index 纳入未跟踪文件进行完整性比较，不改动真实 index。
- `scripts/verify-upstream.sh` 比较补丁全文；`tools/check-upstream-archive.sh` 检查归档覆盖和内容一致性。
- 在空目录通过本机 bare mirror 实际执行了首次恢复、验补丁、重复恢复和再次验补丁，全部通过，最终 HEAD 为 `d7e8d01678107f066d6ec988ca178d80089bd9f5`，补丁覆盖 29 个文件。
- 直接从 GitHub 做同一验证时，`git clone` 返回 HTTP/2 framing error；因此远端全量 clone 尚未通过。其余构建目前在工作副本完整通过，但没有声称已在全新 Hps2 checkout 完成端到端构建。
- `thirdparty-ohos/sources.lock.json` 锁定依赖版本；DevEco SDK 路径由 `DEVECO_HOME` 提供。`scripts/build-debug-hap.sh` 串接源码恢复、依赖、ARMSX2 和 HAP 构建。

## P0-2：权限范围

没有从 HX360E 复制 `system_basic` 或 JIT ACL 权限。现有 debug 调试 Profile 已足够安装和进行本轮真机探针；应用继续走原有 RW→RX 自检路线。

## P0-3：HarmonyOS prctl 兼容尝试

开发版在首次 JIT scratch 自检前仅尝试一次 `prctl(0x6a6974, 0, 0, 0, 0)`。调用失败不会阻止应用启动；最终 JIT 判据仍是 RW 映射、写指令、mprotect RX、同步指令缓存、执行并校验结果。非 OHOS 与商店构建不调用此接口。

## P0-4：自检与诊断

保留 `RunStartupCheck()` 和 `RevalidateAlive()`。自检结果现同时记录 prctl 是否尝试/接受及返回值、errno、页大小、`AnonRwMprotect` 策略名和进程 SELinux 域；打不开域信息时留空，不影响判定。探针页相关检查、复检、文件映射实验和手动按钮共用递归互斥锁。

## P0-5：真机 A/B 实验

2026-10-04 在 HarmonyOS API 26 arm64 测试设备上，用已安装的 debug HAP 运行了启动 prctl 集成前的对照实验。首页返回：

```text
A=PASS(ok/0) prctl=0/0 B=PASS(ok/0)
```

A 是未调用 prctl 的新 scratch 页；B 是 prctl 后重新申请的新 scratch 页。结果说明在本次设备状态下，prctl 被接受，但普通 scratch RW→RX 在调用前后都成功；这没有复现“调用前失败、调用后成功”，不能据此认定它修复了旧回归，也不证明模拟器核心 JIT arena 或 VM 线程状态。

## 构建及最后设备状态

- `bash scripts/build-debug-hap.sh` 在本工作副本成功完成第三方库构建、ARMSX2 `PCSX2_CORE_STATIC` 和 Hvigor `assembleHap`。本机开发包通过签名校验工具验证。
- 基线版设备 A/B 实验和首页 JIT 自检通过。加入启动 prctl 初始化的当前版本已构建，但该版本的最新设备日志、自检和核心实际运行结果尚未完成真机验收。
- 集成启动调用后，首页实验按钮会注明“启动时已调用 prctl；A 不是无 prctl 基线”，避免未来把同一进程内的二次调用误读为干净 A/B。
- 最新 HAP 安装时 HDC 目标掉线；重启 HDC 服务后仍无目标。因此最新启动初始化的真机日志/自检还未验收，核心实际 backend 与游戏运行结果也未在本轮确认。

结论：P0 的代码和本地构建工作已落地，基线版本上的设备 A/B 也已实测；P0 的远端干净 clone→构建以及最新初始化版本的设备复验仍未关闭。不得把这些未完成项记为通过。
