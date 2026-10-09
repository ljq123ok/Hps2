# JIT 签名环境验收记录

> ## 📌 本项目已确定签名方式（2026-10-09）：自签（debug 域）
>
> **下表不再作为待办项。** 项目决定以自签分发，JIT 已在该配置下实测可用
> （`JIT_CHECK_EXPLICIT available=1 stage=ok errno=0`，
> SELinux domain = `debug_hap`）。
>
> 上架路径（`normal_hap`）已实测**不可行**：`mprotect-rx` 返回 `EINVAL`，
> 系统策略 `neverallow ... self:xpm { exec_anon_mem }` 不豁免 `normal_hap`。
> 详见 [`release-jit-conclusion.md`](release-jit-conclusion.md)。
>
> 下表保留作方法论与历史记录：若将来要换设备/系统版本，仍可按同样的
> 格子逐项复核。**其"待测"字样不代表存在阻塞项目的未验证项。**

HPS2 的 JIT 能力由运行时机器码探针判定。签名名称、构建模式或 `prctl` 返回值
都不能单独作为“实际 JIT 可用”的证据。每个格子须由真实设备上的对应 HAP 填写；
空白表示尚未验证。

| 构建/签名组合 | 安装 | prctl ret/errno | 匿名 RW→RX 执行 | memfd RW/RX | BIOS/游戏实跑 | 设备/系统/日期 |
|---|---|---|---|---|---|---|
| Debug + AutoSign | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 |
| Debug + 手动签名 | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 |
| Release + normal_hap 签名 | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 |
| Release + 可申请 ACL | 待测 | 待测 | 待测 | 待测 | 待测 | 待测 |

每次记录还应保存诊断页中的 stage、errno、page size、build mode、SELinux
domain，以及不含个人路径/设备标识的 `JIT_*` 日志。安装成功与执行动态代码
成功是两项独立结果。不要把 `prctl=0` 或 memfd scratch 探针通过写成核心
CodeCache 已切换或整款游戏 JIT 已验证。

## 设备验收步骤

1. 对每个签名组合分别构建并安装 HAP，记录安装结果和设备/系统版本。
2. 在首页点“重新检测”，记录 prctl、匿名 RW→RX、memfd 双视图、运行期复检、
   page size、build mode 和 SELinux domain。
3. 启动 BIOS，再启动一款自有游戏镜像，确认实际核心运行；另记 OpenGL 画面、
   暂停/继续和即时存档读写结果。
4. 导出对应日志，并将结果填入上表。失败项保留 errno，不用重启后的结果覆盖。
