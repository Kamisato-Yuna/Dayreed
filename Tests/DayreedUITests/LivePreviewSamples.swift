import DayreedCore
import Foundation

/// Test-only samples persisted through the same Core and adapter used by the app.
@MainActor enum LivePreviewSamples {
    static func seed(service: LiveReviewService, image: Data) async throws {
        let database = try await service.prepare()
        let provider = ProviderConfiguration(name: "合成样本", kind: .openAICompatible, model: "synthetic",
            endpoint: URL(string: "http://127.0.0.1/v1/chat/completions"))
        try database.saveProviderConfiguration(provider)
        try database.selectProvider(id: provider.id)
        try database.updateAnalysisContext(settings: CaptureSettings(screenshotsEnabled: true, historyEnabled: true, windowTitlesEnabled: true, accessibilityTextEnabled: true), paused: false)
        let today = Calendar.current.startOfDay(for: .now)
        let samples = [
            (9.5, "梳理产品思路", "梳理需求与用户反馈，明确本周迭代方向与优先级。把待验证的假设整理成可以继续推进的小任务。", "合成 · 文稿", 0),
            (10.75, "专注构建", "实现核心功能模块，优化交互细节与性能表现。保留原生键盘操作，让内容在窄窗口中也能够完整阅读。", "合成 · 编辑器", 1),
            (14.0, "整理与回顾", "整理今日工作成果，记录问题与收获，规划明日计划。回顾中保留记录依据，方便之后追溯。", "合成 · 笔记", 2),
            (16.0, "验证长标题在窄窗口中的换行与活动摘要的完整阅读体验", "这是一条专门用于验收长内容的活动。\n\n" + String(repeating: "逐项复核日期导航、纠正保存和依据查看，确保修改后仍可追溯。", count: 8), "合成 · 验收工具", 1)
        ]
        for dayOffset in [0, -1, -7] {
            let day = Calendar.current.date(byAdding: .day, value: dayOffset, to: today)!
            for (hour, title, summary, application, evidenceType) in samples {
                for minute in [0.0, 20.0] {
                    let evidence: [EvidenceInput] = switch evidenceType {
                    case 0: [EvidenceInput(kind: .screenshot, mediaType: "image/png", data: image)]
                    case 1: [.text("合成辅助功能文本 · \(title)\n仅验收数据，无个人内容。", kind: .accessibilityText)]
                    default: [.text("合成窗口标题 · \(title)", kind: .windowTitle)]
                    }
                    let record = try database.append(CaptureRecordInput(
                        capturedAt: day.addingTimeInterval(hour * 3600 + minute * 60), trigger: .manual,
                        applicationBundleIdentifier: application,
                        qualities: SourceQualities(screenshot: evidenceType == 0 ? .available : .disabled,
                            application: .available, windowTitle: evidenceType == 2 ? .available : .disabled,
                            accessibilityText: evidenceType == 1 ? .available : .disabled), evidence: evidence))
                    try database.saveAnalysis([ActivityClassification(recordID: record.id, title: title, summary: summary)],
                        providerID: provider.id, providerVersion: 1, sources: [record.id: Set(record.evidence.map { $0.kind.analysisSource }).union([.application])],
                        evidenceIDs: [record.id: record.evidence.map(\.id)],
                        expectedRevision: database.analysisContext().revision, continuitySeconds: 1800)
                }
            }
        }
        for (offset, kind) in [(0, ReportKind.daily), (-1, .daily), (0, .weekly), (-7, .weekly)] {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            let query = ReviewQuery(date: date, kind: kind)
            let generated = try await service.regenerate(query)
            let accepted = try await service.accept(candidate: generated.candidates[0], query: query)
            let title = kind == .daily ? "让今天的进展清晰可见" : "把一周的积累连成线"
            var markdown = """
            # \(title)

            \(kind == .daily ? "今天从产品思路开始，把精力放在构建、验证和整理上。几个细小的改进，让回顾更容易阅读，也让下一步更明确。" : "这一周围绕原生回顾体验持续推进。从零散活动中找出共同的方向，保留值得继续投入的事情。")

            ## 完成的事情
            - 梳理需求与反馈，明确迭代方向和优先级。
            - 完成时间线卡片与报告阅读视图，保留原生交互。
            - 复核活动依据和人工纠正，整理可以追溯的进展。

            ## 问题与收获
            清晰的回顾来自完整的上下文。内容先读得懂，再让编辑、保存和来源入口各就其位。

            ## 下一步
            继续验证浅色、深色与窄窗口，记录真实使用中的发现。
            """
            if offset == -1 {
                markdown += (1...12).map { "\n\n## 延伸回顾 \($0)\n" + String(repeating: "这段长文用于检查滚动、段落层级和保存后的阅读体验。", count: 8) }.joined()
            }
            _ = try await service.save(markdown: markdown, report: accepted.report, query: query)
        }
        // Keep one reviewable candidate for today's daily report.
        _ = try await service.regenerate(ReviewQuery(date: today, kind: .daily))
        // Synthetic content is ready; collection remains off and no real Provider runs.
        try database.updateAnalysisContext(settings: CaptureSettings(), paused: true)
    }
}
