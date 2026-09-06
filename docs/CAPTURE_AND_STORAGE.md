# 本地采集与记录接口

`DayreedCore` 提供记录、证据和系统 SQLite 存储；`DayreedCapture` 提供 macOS 26+ 的采集协调器。模块不生成分析结果，不连接 Provider，不实现 Agent/MCP 端点。App 接入后仍需在真实系统权限和窗口环境中验收。

## 启用与状态

```swift
import DayreedCore
import DayreedCapture

// 以下代码在 MainActor 中由 App 持有实例。
let directory = try DayreedDataDirectory.defaultURL()
let store = try DayreedStore(directory: directory)
let coordinator = CaptureCoordinator(store: store) // 所有来源默认关闭
// App 负责保存、恢复用户设置；只有用户选择后才修改来源开关。
var settings = CaptureSettings()
settings.historyEnabled = true
settings.accessibilityTextEnabled = true
coordinator.updateSettings(settings)
coordinator.start()
```

初始化不查询权限、不弹窗、不注册监听、不采样。`start()` 注册系统事件并按已选择的设置工作；全部关闭时不采样。`stop()` 停止调度与监听；`pause()` / `resume()` 控制用户暂停。退出时调用 `stop()`。

`screenshotsEnabled` 与 `historyEnabled` 独立。历史开启后记录应用切换，并可通过 `windowTitlesEnabled`、`accessibilityTextEnabled` 分别启用窗口标题与 AX 文本。窗口标题使用 AX 获取，需辅助功能授权；应用切换本身不需要屏幕录制或辅助功能授权。禁用历史时不会把前台应用标识写入记录，但采集仍查询它来实施排除规则。

`refreshPermissions()` 只查询。系统未授权时用 `notGranted` 表示，不猜测“尚未询问”还是“已拒绝”。权限按钮分别调用 `requestScreenRecordingPermission()` 和 `requestAccessibilityPermission()`，这些方法不修改来源开关。屏幕录制权限不会阻止历史单源工作，AX 拒权不会阻止截图或应用切换记录。

`CaptureCoordinator` 使用 `@Observable`。`state` 提供：

- `mode`：stopped、paused、suspended、disabled、excluded、running。
- `permissions`：screenRecording 与 accessibility。
- `qualities`：screenshot、application、windowTitle 与 accessibilityText，每项区分 disabled、available、empty、truncated、permissionRequired、unavailable、failed。
- `lastRecordID`、`isCapturing`、`storageFailed`。存储错误仅给状态，不输出原始错误描述或正文。

运行模式表示调度是否允许工作；某项权限拒绝或内容不可用通过独立质量状态表示。空 AX 会保留 `.empty`，不生成虚构文本。权限不足、应用不支持 AX、内容为空是不同情况；部分 AX 内容可与 `.truncated` / `.unavailable` 同时保留，使用者应展示质量。

## 采样与排除

默认间隔 60 秒，允许 5...3600 秒。开启后立即采样，应用切换也触发一次采样；同时到达的请求合并为最多一次待处理请求。`captureNow(trigger:)` 可供显式本地采样使用。

截图通过 ScreenCaptureKit 截取主显示器，最长边不超过 2560 像素，保存 PNG，不采集音频或光标。`excludedBundleIdentifiers` 非空时，ScreenCaptureKit 仅包含当前已枚举且未被排除的应用，避免排除应用在枚举后新启动时漏入截图；此模式也省略桌面背景与 Dock。过滤作用于应用拥有的窗口，不能识别另一个应用转绘的内容。当前前台应用被排除时，所有来源都跳过。设置了排除列表但前台应用无法识别时也跳过，避免无法执行排除规则时误收集。

AX 在后台工作线程中只读属性，限定 120 个元素、10 层、正文 12000 个 UTF-16 单元、标题 512 个 UTF-16 单元；遍历时间预算 0.8 秒，每次 AX 消息超时 0.04 秒。单次正在执行的系统调用可能略超出总预算。读取 children 数组时也限制返回数量。安全文本控件及无法识别角色的控件跳过，不读取按键、剪贴板，不执行 AX action。AX API 仍可能先返回应用提供的完整单属性字符串，模块会立即截断后再累积/保存；不承诺控制外部应用的响应分配。

用户暂停、设置变更、应用切换、权限变化、锁屏、睡眠、会话退出会使在途结果失效。锁屏、屏幕熄灭、系统睡眠和用户暂停分别保持状态，解除一种不会解除其他原因。超过 15 秒的结果也丢弃。ScreenCaptureKit 的单次请求不可保证立即取消，模块在等待期间不再启动另一条采集链，返回后重新检查状态才写入。

## 存储、分页与证据

默认目录为 `~/Library/Application Support/YunaBuild.Dayreed/`，模块不访问旧应用目录。`records.sqlite3` 同时存记录摘要、原始 PNG、窗口标题与 AX 文本，不散落图片文件。目录权限 0700、数据库 0600；这是本地明文存储，文件系统访问权限并非数据库加密。凭据不属于该数据库。

`DayreedStore` 的同步方法用连接锁串行执行。每次记录及其证据在同一 SQLite 事务中写入，证据使用普通 UUID 主键和 `record_id` 外键关联。查询大量页面或删除可放后台；协调器的最后状态检查及单次写入在 MainActor 中顺序执行，防止暂停与提交交错。

默认查询不包含标题、AX 或图片原文：

```swift
var cursor: CaptureRecordCursor?
repeat {
    let page = try store.records(in: interval, limit: 500, after: cursor)
    // 消费 page.records；每条包含时间、触发来源、应用 bundle ID、质量、证据 ID/类型/大小。
    cursor = page.nextCursor
} while cursor != nil
```

日期范围采用 `[start, end)`，每页 1...10000 条，默认 500。按时间和 UUID 排序，`nextCursor == nil` 明确表示查询结束；不能把单页当作完整日报/周报。固定同一时间区间继续分页。查询反映实时数据库，分页期间发生的删除或回填可能改变结果，需要后续分析按实际编辑行为重生成。

`rawEvidence(id:)` 是显式本地原文接口，返回类型、mediaType、Data 和关联 recordID，仅应由本人查看或用户选定的 Provider 调用。原文对象的字符串/debug 描述被隐藏。Agent 的默认实现应使用摘要查询，以及 `DayreedStore(directory:access: .readOnly)`；此只读模式通过 SQLite 禁止写入。它不提供进程之间的权限隔离，原始证据仍需要由 App/CLI 的能力范围控制。

## 保留和删除

`retentionDays` 默认 30，范围 1...3650。`start()`、设置变化及成功采样后安排后台保留清理；同一协调器最多执行一个清理任务，期间的重复请求合并为最新参数。采集等待清理结束后重新检查 generation、暂停和来源设置，再读取系统来源；异步来源返回后也等待清理并重新检查，最后同步校验与 append 之间不挂起。`captureNow()` 正常完成时也已等待本次写入后的清理。暂停/停止不会打断已开始的 SQLite 事务，停止会丢弃尚未执行的清理请求。保留策略保留当前日历日及之前 days-1 天。`applyRetention(days:now:calendar:)` 支持明确时区，按日历计算，包含夏令时日期边界。关闭来源不会立即删除此前记录，已有内容依然遵循保留设置。

`deleteRecords(in:)` 按半开时间区间删除，`deleteAll()` 删除全部记录；返回删除记录数。原始证据通过外键在同一事务中级联删除。App 的“删除记录”操作应先暂停采集，使在途结果失效，再执行删除；恢复由用户选择。当前没有派生报告表，后续分析实现需要把报告及其证据关系纳入删除语义。

SQLite 使用 DELETE journal 与 secure_delete，删除时清除数据库空闲页中的内容；不承诺清除系统快照、备份或 SSD 历史物理块。无原始正文、截图或凭据进入模块日志。

## 验证范围

测试仅使用临时目录、合成图像字节/文本和可注入的 `CaptureEnvironment`，不查询真实权限或读取个人记录。覆盖来源与权限组合、开关、暂停/恢复、排除、锁屏/睡眠、过期结果、AX 上限、分页、事务回滚、证据删除及日期边界。

真实屏幕录制/辅助功能授权、主屏截图与排除窗口效果、系统锁屏通知、真实应用 AX 支持程度，由 App 集成后统一验收。构建及合成测试通过不表示这些真实系统行为已验收。
