# 阶段 0 结论：公共数据目录能力（真机实测）

**日期**：2026-09-25
**设备**：HarmonyOS 7.0.0 / API 26 测试设备（设备标识已脱敏）
**探针**：提交 `ff463dd` + 本轮修正（多候选 + 逐级祖先诊断 + 目录枚举）
**授权**：安装方式为 `install -r`（同 bundle 更新），沙箱数据全程完好

---

## 结论（先看这里）

**实时外置数据根在方案既有形态下不可行** —— 不是权限问题，而是
**应用进程的挂载命名空间里根本不存在公共存储挂载点**。

因此按规划决策表，落在「**暂时保留沙箱**」一档：不能宣称"卸载不丢档"，
也不应把核心数据根切到外部目录。

---

## 证据

### 1. 逐级祖先诊断：断点在 `/storage/media` 这一层

```
/storage              stat=true   f=true  x=true     ← 可见
/storage/media        stat=FALSE  errno=2  dir=false ← 断在这里
/storage/media/100    stat=false  errno=2
/storage/media/100/local/files/Docs/Download  stat=false errno=2
```

`errno=2` 是 **ENOENT**（不存在），**不是 EACCES(13)**（被拒绝）。
这个区别是决定性的：权限不足可以靠授权解决，**路径在命名空间中不存在
则无法靠应用侧任何权限修复**。

### 2. 目录枚举：`/` 与 `/storage` 存在但不可枚举，`/storage/media` 不存在

```
list_dir /               ok=false errno=13 (EACCES)  ← 存在，但无枚举权限
list_dir /storage        ok=false errno=13 (EACCES)  ← 存在，但无枚举权限
list_dir /storage/media  ok=false errno=2  (ENOENT)  ← 不存在
list_dir /sdcard         ok=false errno=2  (ENOENT)  ← 不存在
list_dir /mnt            ok=false errno=13 (EACCES)
list_dir /data           ok=false errno=13 (EACCES)
```

对照：`hdc shell`（uid=2000、SELinux `u:r:sh:s0`）能正常 `ls`
`/storage/media/100/local/files/Docs/Download` 并看到其中的 ISO。
**同一路径在应用视角与 shell 视角下表现不同** —— 二者处于不同的
挂载命名空间/SELinux 域。这正是"必须由应用进程自己实测"的原因。

### 3. `Environment.getUserDownloadDir()` 直接不可用

```
resolve_public_dir=FAIL  throw code=801 "The device doesn't support this api"
```

`801 = Capability not supported`，即该 API 依赖的 syscap
（`SystemCapability.FileManagement.File.Environment.FolderObtain`）本机未提供。
**注意这与权限无关**：该 API 自 API 12 起文档块已无 `@permission` 标注。

ArkTS 编译器其实**早先已给出警告**（构建日志第 7 条）：

```
The system capacity of this api 'getUserDownloadDir' is not supported on all devices
```

第一轮探针把这条警告当作可选提示处理，是判断失误 —— 它实际是决定性的。

### 4. Native POSIX 闸门：全项 FAIL

```
native_mkdir=FAIL errno=2
native_create=FAIL errno=2
native_stdio=FAIL errno=2
native_rename=FAIL errno=2
native_stat=FAIL errno=2
native_unlink=FAIL errno=2
native_rw_seek=FAIL
```

在候选路径下 `mkdir/open/fopen/rename/stat/unlink` 全部 `errno=2`，
与上述"挂载点不可见"一致 —— 不是核心的读写能力问题，
而是**目标路径对应用不存在**。

---

## 与第一轮结论的差异（自我纠正）

第一轮探针因设计缺陷**提前 return**：它在 `getUserDownloadDir()` 失败后
就中止，导致真正的闸门（第 4 项 Native POSIX）**根本没被执行**。
本轮修正了三点：

1. **不再提前中止**，失败也继续跑到 native 闸门；
2. 增加**多候选路径**回退（API 不可用 ≠ 目录不可达）；
3. 增加**逐级祖先诊断**与**目录枚举**，把"FAIL"精确定位到具体层级。

另修掉一个自身 bug：ArkTS 传 `probeDir` 给 `runDataProbe()`，而 native
会再追加一次子目录名，导致路径拼成 `.../Hps2Probe/Hps2Probe`。

---

## 对规划的影响

| 规划项 | 原设想 | 实测后 |
|---|---|---|
| 数据外置 | 实时外置到公共 Download | **不可行**（命名空间不可见） |
| 卸载不丢档 | 靠外置目录实现 | **不能宣称**（数据仍在沙箱） |
| 逐文件 URI 授权 | 未纳入 | **唯一可行方向**（见下） |
| 迁移设计（阶段 3） | 全量迁移 | **暂缓**，避免在假前提上投入 |

### 仍值得探索的方向

"应用看不到公共目录"不等于"应用无法长期访问用户文件"。项目**已经**
在用的机制是可行的：`DocumentViewPicker` + `fileshare.persistPermission()`
（见 `Index.ets` 的 `pickInPlace()`），它拿的是**逐文件/逐目录的 URI 授权**，
不依赖 POSIX 路径可见性。

若要继续推进"数据外置"，正确形态应是：

1. 让**用户在 picker 里选定** `Download/Hps2` 目录（而非应用自行拼接路径）；
2. `persistPermission()` 持久化该 URI 授权；
3. 数据 IO 走 **URI + fd**（ArkTS 侧已确认 `fs.openSync(uri)` 可用），
   而非 POSIX 路径；
4. 核心（PCSX2）只认 POSIX 路径 —— 这是**真正的阻塞点**，
   需评估"核心经 fd/代理层访问"的改造成本，或仅对**小文件**
   （记忆卡、即时存档、设置）做 URI 化外置，游戏镜像保持沙箱。

第 4 点建议先做**可行性评估再动手**，不要直接进入迁移实现。

---

## 用户数据安全

- 全程 `install -r` 更新安装，未卸载
- 实测沙箱完好：`games` 10 GB、`memcards` 17 MB、`sstates` 22 MB
- 探针只在目标路径尝试写入，失败即止；**未在沙箱留下任何垃圾**
  （已确认无 `Hps2Probe` 目录）
- 不可再生数据的预防性备份在 `.backup-probe-precaution/`（已 gitignore）

---

## 未做项

**第 5 项（卸载重装后目录是否存活）已无必要**：实时外置在可见性层面
即已不通，卸载存活与否不再改变结论。若将来改走 URI 授权路线，
该项需重新设计（URI 授权的持久性跨越卸载是另一个独立问题）。
