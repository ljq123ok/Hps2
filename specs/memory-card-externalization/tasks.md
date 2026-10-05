# Implementation Plan

- [x] 1. 固定记忆卡外置范围与验收边界
  - 仅处理 PS2 记忆卡，排除即时存档。
  - Requirement: 1-7
- [x] 2. 配置 HarmonyOS 共享目录
  - 已增加 `share_files.json` 和 entry 模块 `shareFiles` 配置；当前本机 DevEco 仅有 API 24，API 26 捐献字段待升级工具链后真机复验。
  - Requirement: 2, 6
- [x] 3. 增加 Native 记忆卡管理 API
  - 已实现列表、创建、删除和目录路径；重命名交由系统文件管理器完成，避免重复实现。
  - Requirement: 1, 4, 5
- [x] 4. 增加 ArkTS 记忆卡管理界面
  - 已实现设置内独立入口、按游戏分组筛选、当前游戏归类、刷新、导入、导出、创建、删除和状态提示；重命名交由系统文件管理器完成。
  - Requirement: 1, 3, 5, 7
- [ ] 5. 构建与真机验证
  - 已验证构建、安装、创建和列表；API 26 共享目录的文件管理器复制/移动/改名/删除仍需 API 26 工具链重打包后复验。
  - Requirement: 2, 6
