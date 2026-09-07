import Foundation

@MainActor final class SyntheticReviewService: ReviewService {
    var capabilities = ReviewCapabilities(read: true, saveReport: true, regenerate: true, correctEvent: true, openEvidence: true, configure: true, checkUpdates: true)
    var unavailableReason: String? { nil }
    var shouldFail = false
    var pendingLoads: [CheckedContinuation<ReviewSnapshot, any Error>] = []
    var deferLoads = false
    var pendingSave: CheckedContinuation<ReviewReport, any Error>?
    var deferSave = false
    var opened: [String] = []
    let date = Date(timeIntervalSince1970: 1_789_027_200)
    var sample: ReviewSnapshot {
        let evidence = ReviewEvidence(id: "synthetic-evidence", source: .application, capturedAt: date, label: "合成应用记录")
        return ReviewSnapshot(events: [ReviewEvent(id: "synthetic-event", start: date, end: date.addingTimeInterval(1800), title: "整理设计笔记", summary: "合成样本：梳理回顾界面的内容层次与键盘路径。", application: "合成编辑器", evidence: [evidence])], report: ReviewReport(id: "synthetic-report", markdown: "# 今日回顾\n\n- 整理了设计笔记\n- 完成界面检查\n\n## 下一步\n继续完善个人记录体验。", updatedAt: date, sources: [evidence]))
    }
    func load(_ query: ReviewQuery) async throws -> ReviewSnapshot {
        if deferLoads { return try await withCheckedThrowingContinuation { pendingLoads.append($0) } }
        if shouldFail { throw ReviewServiceError.failed }
        return sample
    }
    func save(markdown: String, report: ReviewReport?, query: ReviewQuery) async throws -> ReviewReport {
        if deferSave { return try await withCheckedThrowingContinuation { pendingSave = $0 } }
        if shouldFail { throw NSError(domain: "SECRET_RAW_CONTENT", code: 1) }
        return ReviewReport(id: report?.id ?? "synthetic-new", markdown: markdown, updatedAt: date, sources: sample.report!.sources)
    }
    func regenerate(_ query: ReviewQuery) async throws -> ReviewSnapshot {
        if shouldFail { throw ReviewServiceError.failed }; return sample
    }
    func correct(event: ReviewEvent, title: String, summary: String) async throws -> ReviewEvent {
        if shouldFail { throw ReviewServiceError.failed }
        var changed = event; changed.title = title; changed.summary = summary; return changed
    }
    func open(evidence: ReviewEvidence) async throws { opened.append(evidence.id) }
    func preferences() async throws -> ReviewPreferences { ReviewPreferences() }
    func save(preferences: ReviewPreferences) async throws -> ReviewPreferences {
        if shouldFail { throw ReviewServiceError.failed }; return preferences
    }
    func checkUpdates() async throws -> String { "合成检查完成，无网络访问" }
}
