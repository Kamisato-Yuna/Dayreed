# 回顾界面验证

`script/test_review_ui.sh` 编译实际 UI store 与纯合成服务，验证失败保留草稿、错误脱敏、未保存导航保护、异步保存期间新编辑、过期响应抑制、未连接状态与默认隐私设置。不访问真实记录、Keychain、采集权限或网络。

`script/build_review_preview.sh` 生成 `build/ui-preview/DayreedReviewPreview.app`，仅包含合成数据，用于 UI 交互检查。以完整路径启动。该专用入口与合成服务不会编入正式 App，底栏始终标注合成验收。测试窗口支持独立浅/深色选择。真实服务接线后的验收应另行进行。

交互检查：⌘1/2/3 切换；⌘[/] 浏览日期；⇧⌘T 今天；活动选择、详情、纠正与来源；报告编辑/预览、⌘S 保存、未保存时切换日期和放弃/保留；重新生成确认；独立 Settings；窗口缩放与系统辅助功能设置。状态测试通过不代表这些项目均已经人工验证。

`Tests/DayreedUITests/test_live_services.sh` 编译并检查正式 App 的真实采集适配器。只使用独立 UserDefaults suite、临时数据库与注入的合成操作系统环境；覆盖初始隐私、来源映射、设置持久化、暂停晚到结果、完整分页、删除级联和日常启动恢复。不会请求实际系统权限、采集桌面或读取用户记录。

`Tests/DayreedUITests/build_live_preview.sh` 生成 `build/live-preview/DayreedLivePreview.app`，用于真实适配器的 GUI 验收。它生成专用截图、标题和 AX 合成证据，使用临时数据库与独立设置域；模拟权限按钮不会操作 TCC，采集操作不会读取真实桌面，退出时清理测试目录。`DAYREED_TEST_BIN_DIR` 可指定刚编译的模块目录以跳过重复构建。
