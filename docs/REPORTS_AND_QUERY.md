# 时间线与可编辑报告

`DayreedCore` 的 `DayreedQueryService` 是 App 与只读 CLI/MCP 共用的查询入口。它只返回派生标题、摘要、来源 ID、观测时间与状态，不返回截图、窗口标题或 AX 原文，也不提供文件路径、SQL 或命令入口。

```swift
import DayreedCore

let query = DayreedQueryService(store: store)
let period = try ReportPeriod(kind: .daily, containing: date,
                              timeZoneIdentifier: "Asia/Shanghai")
let page = try query.timeline(in: period.interval, limit: 100)
// 用同一个 interval，持续传入 page.nextCursor，直到 nil，才能覆盖全部数据。
let existing = try query.report(for: period)
let status = try query.analysisStatus()
```

时间范围为半开 `[start, end)`，周报从当地周一开始。日历计算处理夏令时、跨日、跨年周。`reports(in:limit:after:)` 返回与区间相交的报告，支持同样的普通分页。

采集记录是瞬时观测。时间线只连接时间间隔足够小、同应用且同类的相邻已分析观测；未分析样本、采集重启/恢复标记和缺样空档断开连接。两个来源共同解释一份观测，时长只计一次。最后一个独立样本保留为 `start == end` 的观测点。`observedSeconds` 表示相邻观测支持的时长，不证明用户持续专注。跨日的连续区间按边界裁切，邻近来源仍可追溯。

纠正以原始记录为单位，先从事件的 `recordIDs` 和 `versions` 确认对应标注：

```swift
try store.correctActivity(recordID: recordID, title: "整理资料",
                          summary: "用户纠正后的摘要", expectedVersion: version)
```

纠正后重分析保留用户修改。明确调用 `clearActivityCorrection(recordID:expectedVersion:)` 才重新允许 Provider 更新该记录；此调用本身不发起分析。

合并事件应调用 `store.correctActivities(recordIDs:expectedVersions:title:summary:)`，传入事件的 `recordIDs` 和 `versions`。全部记录在同一事务核对后写入；任何版本冲突都不会部分修改。没有标注的 pending 记录返回 `notFound`，界面应先禁用纠正操作。

报告是 SQLite 中持久化的 Markdown，不是 App 临时展示文本。生成不调用 Provider、不读 raw，只使用时间线派生内容。

```swift
let reports = ReportService(store: store)
let draft = try reports.generateCandidate(for: period)
// 展示 draft.markdown 给用户；在用户选择保存/替换之后：
let saved = try reports.acceptCandidate(id: draft.id)
let edited = try reports.edit(id: saved.id, markdown: editedMarkdown,
                              expectedVersion: saved.version)
```

没有记录时也可以直接手写：`reports.create(for: period, markdown: text)`。单事务创建、唯一约束防止并发重复，已存在报告返回 `conflict`，不会覆盖它。无需通过候选稿绕行。

每次生成都保存独立候选稿，原报告保持不变。接受候选时，事务同时核对报告版本和来源标注版本；并发手改返回 `AnalysisError.conflict`，新观测或来源变化返回 `stale`。`candidates(for:)` 可恢复未处理稿，`discardCandidate(id:)` 删除不再需要的候选。修改时间线后已有报告保留正文并标为 `needsReview`。

删除记录、全部删除和按日保留清理沿用 `DayreedStore` 的 API。schema 2 使用普通主键、事务和级联关联，并在删除记录的同一事务删除涉及它的报告全文、候选全文及标注；仅删除外键关联会遗留正文，因此不能只依赖关联表的级联。没有来源行的手工报告也会按日期删除：区间删除清除与区间相交的整份报告，保留清理删除开始时间早于保留日的整份报告（含跨日周报），全部删除清除所有报告。此行为不承诺清除文件系统快照或外部备份。

只读 Agent 使用 `DayreedStore(directory:access: .readOnly)`；首次 schema 升级应由 App 的可写 Store 完成。只读服务不能接受候选、修改报告或发起 Provider 分析。
