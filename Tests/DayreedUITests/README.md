# 回顾界面验证

`script/test_review_ui.sh` 编译实际 UI store 与纯合成服务，验证失败保留草稿、错误脱敏、未保存导航保护、异步保存期间新编辑、过期响应抑制、未连接状态与默认隐私设置。不访问真实记录、Keychain、采集权限或网络。

`script/build_review_preview.sh` 生成 `build/ui-preview/DayreedReviewPreview.app`，仅包含合成数据，用于 UI 交互检查。以完整路径启动。该专用入口与合成服务不会编入正式 App，底栏始终标注合成验收。测试窗口支持独立浅/深色选择。真实服务接线后的验收应另行进行。

交互检查：⌘1/2/3 切换；⌘[/] 浏览日期；⇧⌘T 今天；活动选择、详情、纠正与来源；报告编辑/预览、⌘S 保存、未保存时切换日期和放弃/保留；重新生成确认；独立 Settings；窗口缩放与系统辅助功能设置。状态测试通过不代表这些项目均已经人工验证。

`Tests/DayreedUITests/test_live_services.sh` 编译并检查正式 App 的真实采集适配器。只使用独立 UserDefaults suite、临时数据库与注入的合成操作系统环境；覆盖初始隐私、来源映射、设置持久化、暂停晚到结果、完整分页、删除级联和日常启动恢复。不会请求实际系统权限、采集桌面或读取用户记录。

`Tests/DayreedUITests/build_live_preview.sh` 生成 `build/live-preview/DayreedLivePreview.app`，用于真实适配器的 GUI 验收。它生成专用截图、标题和 AX 合成证据，使用临时数据库与独立设置域；模拟权限按钮不会操作 TCC，采集操作不会读取真实桌面，退出时清理测试目录。脚本在临时目录显式编译真实 Core、Capture、Analysis 和 Update 模块，不依赖 SwiftPM automatic library 的产物布局。

Provider 检查注入内存凭据和合成 Provider，覆盖保存/选定、来源过滤、暂停与全关晚到结果、默认关闭的当天自动分析、配置失败、退出取消及表单验证。LivePreview 同样注入这些替身，不能调用真实 HTTP/CLI Provider。

`Tests/DayreedUITests/test_live_preview_samples.sh` 用真实 Core 校验 LivePreview 样本能够完成初始化：当天四条活动及证据、日报/周报与候选稿、昨天长文、明天空白，且采集保持关闭。此检查不替代实际 GUI 启动或截图验收。

LivePreview 底部可切换浅色/深色，仅作用于验收窗口。当天活动默认收起，点击卡片展开详情、纠正和依据；报告默认阅读，底部切换编辑，支持 ⌘S 保存。每次启动新建临时数据库，同次运行的保存、纠正、候选采用和刷新均经过真实适配器持久化，退出后清理。按 ⌘[ 浏览昨天长文，⌘] 浏览明天空白，⇧⌘T 返回今天。关键控件的辅助功能标识使用 `navigation.*`、`date.*`、`timeline.*`、`report.*`、`correction.*`、`evidence.open.*` 和 `candidate.*`。
