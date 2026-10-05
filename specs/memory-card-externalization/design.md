# 技术设计

## 目录与共享

核心仍使用 `EmuFolders::MemoryCards = <DataRoot>/memcards`。entry 模块声明 `shareFiles`，profile 将 `/base/files/memcards` 以 `r+w` 配置为 HarmonyOS 7/API 26 的捐献目录。当前工程只能用 API 24 工具链构建，因此现阶段以 DocumentPicker 导入/导出作为可靠通道；API 26 工具链就绪后可直接复验同一目录的文件管理器操作。

## Native API

在 N-API 层增加只读列表、创建、重命名、删除和目录路径查询。所有管理操作要求 VM 未运行；Native 复用 PCSX2 的 `FileMcd_*` 校验和文件类型识别，避免 ArkTS 复制一套格式判断。

## ArkTS UI

设置中提供独立的“存档管理”入口，首页不再放置记忆卡操作。管理页调用 Native API 刷新列表，并按当前选择的游戏提供分组筛选；新建或导入的记忆卡默认归入当前游戏，没有当前游戏时归入“未分类”，也可在卡片行上将其归类到当前游戏。分组关系保存在应用数据目录的 `memory-card-groups.json`，不改变记忆卡文件格式。

导入使用 `DocumentViewPicker` 复制到 `memcards/`；导出使用 `DocumentSavePicker` 写出原始文件。应用目录路径显示为说明信息，导出的 `.ps2` 文件可在系统文件管理器中自由管理。

## 安全与一致性

- 文件名只允许普通文件名，拒绝路径分隔符和 `..`。
- 只接受 PCSX2 支持的 `.ps2/.mcr/.mcd/.bin/.mc2` 文件及合法容量。
- VM 运行时禁用破坏性操作。
- 列表刷新后重新校验文件，防止文件管理器移动/删除造成陈旧状态。

## 验证

- ArkTS 类型检查和 HAP 构建。
- Native 管理 API 的无 VM 测试。
- 真机已验证 API 24 包构建、安装、创建和列表；API 26 共享目录在文件管理器中的可见性及直接复制/移动/改名/删除待升级工具链后复验。
