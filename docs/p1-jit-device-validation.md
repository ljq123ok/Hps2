# HPS2 v0.14 P1 真机验证记录

日期：2026-10-05（设备日志本地时间）  
构建：`0.14`，`versionCode=1000014`，HarmonyOS API 26 arm64 测试设备 debug 签名

## 已通过

- 最新 debug HAP 通过 `hap-sign-tool verify-app`，随后 HDC 覆盖安装成功并启动。
- 首页 JIT 诊断 JSON 正常解析并显示；设备日志未再出现 `checkJit failed`。
- 匿名 `RW → RX` scratch 执行通过：`available=1 stage=ok errno=0`。
- Harmony JIT `prctl` 返回 `0`，`accepted=1`；页大小为 4096，SELinux domain 为 `debug_hap`。
- memfd 双视图探针明确失败：RX 映射返回 `EACCES`（errno 13）。探针没有执行写入/循环阶段；核心策略仍为 `AnonRwMprotect`，符合“不让实验失败阻止启动”的设计。
- 启动 BIOS 后约 30 秒，设备日志出现 `JIT_WATCHDOG=alive interval_sec=30`，证明运行中的复检循环实际执行且通过。
- 从浮球暂停 BIOS 成功，native 日志记录 `setPaused(1) accepted`。
- BIOS 菜单 PERF 样本：约 59.9 FPS、100% speed；累计 `mprotect=592`、失败 0、平均 11.98 μs、最大 220.31 μs。该数值只代表 BIOS 菜单，不是 PS2 游戏性能基准。

## 尚未完成

- 暂停后的继续操作未验证：设备在暂停后从 HDC 目标列表消失，恢复控制连接后再测。
- 未选择游戏镜像；真实游戏启动、游戏场景性能、存档/读档、手柄和音频回归尚未完成。
- memfd errno 13 表明此设备/签名组合不允许该 RX 视图；没有据此改动 ARMSX2 CodeCache。
