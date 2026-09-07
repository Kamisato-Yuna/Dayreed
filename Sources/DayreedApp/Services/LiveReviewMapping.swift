import DayreedCore
import Foundation

/// Maps persisted domain projections into UI values, retaining ordinary versions for conflict checks.
enum LiveReviewMapping {
    static func period(_ query: ReviewQuery) throws -> ReportPeriod {
        guard let kind = query.kind else { throw ReviewServiceError.failed }
        return try ReportPeriod(kind: kind == .daily ? .daily : .weekly, containing: query.date, timeZoneIdentifier: TimeZone.current.identifier)
    }

    static func snapshot(store: DayreedStore, query: ReviewQuery) throws -> ReviewSnapshot {
        let service = DayreedQueryService(store: store)
        var cursor: TimelineCursor?
        var events: [TimelineEvent] = []
        repeat {
            let page = try service.timeline(in: query.interval, after: cursor)
            events.append(contentsOf: page.events)
            cursor = page.nextCursor
        } while cursor != nil
        // Domain groups may include the two observations supporting a clipped midnight span.
        let interval = DateInterval(start: query.interval.start.addingTimeInterval(-5400), end: query.interval.end.addingTimeInterval(5400))
        let records = try records(store: store, interval: interval)
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var snapshot = ReviewSnapshot(events: events.map { event($0, records: byID) })
        if query.kind != nil {
            let period = try period(query)
            snapshot.report = try service.report(for: period).map { report($0, records: byID) }
            snapshot.candidates = try ReportService(store: store).candidates(for: period).map {
                ReviewReportCandidate(id: $0.id.uuidString, markdown: $0.markdown, createdAt: $0.createdAt)
            }
        }
        return snapshot
    }

    static func records(store: DayreedStore, interval: DateInterval) throws -> [CaptureRecordSummary] {
        var records: [CaptureRecordSummary] = []
        var cursor: CaptureRecordCursor?
        repeat {
            let page = try store.records(in: interval, after: cursor)
            records.append(contentsOf: page.records)
            cursor = page.nextCursor
        } while cursor != nil
        return records
    }

    static func evidence(_ records: [CaptureRecordSummary]) -> [ReviewEvidence] {
        records.flatMap { record in
            record.evidence.map { reference in
                let source: EvidenceSource = switch reference.kind {
                case .screenshot: .screenshot
                case .windowTitle: .windowTitle
                case .accessibilityText: .accessibility
                }
                return ReviewEvidence(id: reference.id.uuidString, source: source, capturedAt: record.capturedAt, label: source.title + " · 本机证据")
            }
        }
    }

    static func event(_ event: TimelineEvent, records: [UUID: CaptureRecordSummary]) -> ReviewEvent {
        let supporting = event.recordIDs.compactMap { records[$0] }
        let hasContent = supporting.contains { !$0.evidence.isEmpty || $0.applicationBundleIdentifier != nil }
        var result = ReviewEvent(id: event.id.uuidString, start: event.start, end: event.end,
            title: event.title ?? "待分析的采样记录",
            summary: event.summary ?? (hasContent ? "此记录尚无分析摘要。当前分析状态与操作见上方。" : "没有取得可分析内容，请检查权限与来源质量。"),
            application: Set(supporting.compactMap(\.applicationBundleIdentifier)).sorted().joined(separator: "、"),
            evidence: evidence(supporting))
        result.recordVersions = Dictionary(uniqueKeysWithValues: event.versions.map { ($0.key.uuidString, $0.value) })
        result.isCorrectable = event.state != .pending
        result.stateTitle = switch event.state {
        case .pending: "待分析 · 单条采样不推算持续时长"
        case .analyzed: "已分析 · 时段由相邻观测支持"
        case .corrected: "已人工纠正 · 重新分析会保留纠正"
        }
        return result
    }

    static func report(_ report: ReportDocument, records: [UUID: CaptureRecordSummary]) -> ReviewReport {
        ReviewReport(id: report.id.uuidString, markdown: report.markdown, updatedAt: report.updatedAt,
            sources: evidence(report.recordIDs.compactMap { records[$0] }), version: report.version,
            isEdited: report.isEdited, needsReview: report.needsReview)
    }

    static func error(_ error: Error) -> ReviewServiceError {
        switch error as? AnalysisError {
        case .conflict, .stale: .conflict
        case .notConfigured: .notConfigured
        case .noEvidence: .noEvidence
        case .paused: .paused
        case .sourcesDisabled: .sourcesDisabled
        case .unsupportedImages: .unsupportedImages
        case .credentials: .credentials
        case .cancelled: .cancelled
        case .invalidConfiguration: .invalidConfiguration
        case .invalidResponse: .invalidResponse
        default: .failed
        }
    }
}
