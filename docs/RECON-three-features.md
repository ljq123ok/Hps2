# 侦察记录：暂停菜单 / 数据外置 / 游戏识别 UI

**日期**：2026-09-24
**用途**：供 Codex 制定项目规划与技术方案时作为事实依据。
**原则**：只记录**已核实**的代码事实与实测结果，不含推测。

---

## 一、暂停菜单

### 现状
- UI 中**完全没有**暂停/恢复入口（已 grep 确认）。
- Native 侧已有暂停能力，且**已在本项目中被实际使用过**：
  - `VMManager::SetPaused(true/false)`（`napi_init.cpp:642` 已在启动后调 `SetPaused(false)`）
  - `VMManager::GetState()` 可查当前状态

### 已踩过的坑（必须复用既有机制，否则会重现）
本项目在修「返回按钮无效」与「读档卡死」时，已确认以下三条：

1. **`SetPaused(true)` 只改状态，不保证 VM 线程已停。**
   判断「是否真的停下」必须用 `Hps2VmSync::IsInExecute()`
   （VM 线程围绕 `VMManager::Execute()` 置位/清除），
   **不能轮询 `GetState() == Paused`** —— 那会立即返回（实测 0ms），形同虚设。

2. **需改 VM 状态时必须经 `Hps2VmSync::RunOnVmThread(fn, timeout)`**
   （本项目补的「等效 RunOnCPUThread」实现；上游的 `Host::RunOnCPUThread`
   在 `hps2_host.cpp:305` 是 `pxFailRel` 桩）。

3. **主循环在 Paused 状态下不应调用 `Execute()`**（已在 `napi_init.cpp` 修好）。

### 建议的实现要点（供 Codex 参考，非定论）
- 悬浮球展开面板中已有「返回/存档」等按钮，暂停按钮可置于同处。
- 暂停状态需要在 UI 上可见（否则用户不知道是否已暂停）。
- 暂停期间是否继续渲染 GS 画面、是否允许操作虚拟按键，需明确。

---

## 二、数据外置（⭐ 数据安全问题）

### 现状（已核实）
```
ArkTS: dataRoot() = getContext(this).filesDir
                 = /data/storage/el2/base/haps/entry/files/   （应用私有沙箱）

native: EmuFolders::AppRoot = EmuFolders::DataRoot = 上述路径
```

沙箱内实际存在的目录/文件（真机 `ls` 确认）：
```
bios/  games/  sstates/  cache/  cheats/  covers/
gamesettings/  inputprofiles/  memcards(按上游默认应有)
emulog.txt  game_selection.json
```

上游的路径推导（`Pcsx2Config.cpp:2535`）：
```cpp
MemoryCards = LoadPathFromSettings(si, DataRoot, "MemoryCards", "memcards");
```
⇒ **记忆卡（游戏内存档）也在沙箱里**。

### 为什么这是安全问题而非功能缺失
- **卸载应用即全部丢失** —— 包含玩家在游戏里积累的记忆卡存档。
- 用户在文件管理器中**看不到**，无法自行备份。
- 覆盖安装（`install -r`）通常保留沙箱，但卸载重装会清空。

### 技术前提（**已核实成立**）
```json
名称: ohos.permission.FILE_ACCESS_PERSIST
grantMode: system_grant      ← 系统自动授予，无需弹窗
availableLevel: normal       ← 非受限，无需 ACL
受限(restricted): False
```
来源：`$SDK/default/openharmony/toolchains/lib/PermissionDefinitions.json`
⇒ 把数据放到用户可见目录**不需要受限权限，不违反项目「不申请受限权限」的约定**。

当前 `module.json5` **未声明任何权限**（已确认）。

### 仍需实验验证的三点（**不能按「能」来设计**）
1. 应用能否**直接枚举** `Download/Hps2` 下的内容（而非逐个文件授权）？
2. 首次启动时该目录不存在，应用能否**自行创建**？
3. 用户手动往目录里丢文件后，应用能否**发现**？

### 迁移要求（必须纳入方案）
- 已有用户的沙箱数据要能**搬**到新位置，**不能丢**。
- 需考虑：迁移失败时的回退、部分迁移的恢复、以及「新旧位置并存」时的取舍。

---

## 三、游戏识别 UI

### 现状
- **底层已有**：`VMManager::GetDiscSerial()` / `VMManager::GetDiscCRC()`
  已在即时存档中实际使用（`hps2_savestate.cpp:327-328`、`393-394`），
  用于组合存档文件名 `<serial> (<crc>).NN.p2s`。
- **UI 未暴露**：首页不显示游戏名 / serial / CRC。

### 已有素材
- 沙箱内有 `covers/` 目录（封面缓存）与 `game_selection.json`（当前选择）。
- 上游有 `GameList::FillBootParametersForEntry()`（`GameList.cpp:234-241`），
  本项目启动时参考了它的参数填充方式（`napi_init.cpp:517`）。

### ✅ 关键约束已查证：serial/CRC 在启动前**不可用**

`s_disc_serial` / `s_disc_crc` 的赋值点（`VMManager.cpp`：
`UpdateDiscDetails()` 内的 1222/1235/1241 行）**全部位于 VM 启动流程内部**，
且由 `ClearDiscDetails()`（1347 行）清空。

⇒ **首页（VM 启动前）拿不到 serial / CRC**，只能拿到用户选择的**文件名**。

### 因此「游戏识别 UI」有两种可行形态（不冲突，可都做）

| 形态 | 位置 | 可用字段 | 是否需改 native |
|---|---|---|---|
| **A** | 首页 | **文件名**（用户已选，ArkTS 侧现成）| 否 |
| **B** | 游玩页 / 悬浮球 | **serial + CRC**（`GetDiscSerial/GetDiscCRC`）| 否（已有 API）|

若还想显示**游戏标题**（如「Final Fantasy XII」），需另查上游
`VMManager::GetTitle(bool prefer_en)`（`VMManager.cpp:383`）——
同样只在启动后可用，且依赖 GameDatabase 是否可用，**需实测确认**。

### 待 Codex 在方案中定义
- 首页 A 形态的展示样式（文件名可能很长，需截断策略）
- 是否要把 serial/CRC 显示给普通用户（对普通用户价值有限，
  但对反馈问题很有用 —— 可作为「一键复制诊断信息」的一部分）

---

## 四、给 Codex 的提醒

1. **暂停功能不要直接调 `SetPaused`** —— 本项目已有的三条坑必须遵守（见第一节）。
2. **数据外置的三点实验必须先做**，结果决定实现方式。
3. **`GetDiscSerial()` 在启动前是否可用必须实测**，否则「首页显示游戏名」无法实现。
4. 上游改动**无版本管理** —— 已建 `patches/` 归档，
   若方案需要改上游，务必同步更新 `patches/README.md` 所列的归档流程。
