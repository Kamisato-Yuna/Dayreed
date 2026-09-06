import Foundation
import SQLite3

public struct ReportService: Sendable {
    private let store: DayreedStore
    public init(store: DayreedStore) { self.store = store }
    /// Creates a manual report even on a day without observations. Never overwrites an existing one.
    public func create(for period: ReportPeriod, markdown: String) throws -> ReportDocument {
        try store.createReport(for: period, markdown: markdown)
    }
    public func generateCandidate(for period: ReportPeriod) throws -> ReportCandidate {
        try store.generateReportCandidate(for: period)
    }
    public func candidates(for period: ReportPeriod) throws -> [ReportCandidate] { try store.reportCandidates(for: period) }
    /// Must be called for an explicit user replacement action. A concurrent edit returns conflict.
    public func acceptCandidate(id: UUID) throws -> ReportDocument { try store.acceptReportCandidate(id: id) }
    public func discardCandidate(id: UUID) throws { try store.discardReportCandidate(id: id) }
    public func edit(id: UUID, markdown: String, expectedVersion: Int64) throws -> ReportDocument {
        try store.editReport(id: id, markdown: markdown, expectedVersion: expectedVersion)
    }
}

private struct StoredCandidate: Codable {
    let candidate: ReportCandidate
    let sourceVersions: [UUID: Int64]
}

extension DayreedStore {
    public func createReport(for period: ReportPeriod, markdown: String) throws -> ReportDocument {
        try validateMarkdown(markdown)
        return try lock.withLock {
            try requireWrite()
            return try transaction {
                guard try readReport(for: period) == nil else { throw AnalysisError.conflict }
                let ids = Set(try readTimeline(in: period.interval).flatMap(\.recordIDs)).sorted { $0.uuidString < $1.uuidString }
                let report = ReportDocument(id: UUID(), period: period, markdown: markdown, version: 1,
                    isEdited: true, needsReview: false, updatedAt: Date(), recordIDs: ids)
                try writeReport(report)
                return report
            }
        }
    }

    public func report(for period: ReportPeriod) throws -> ReportDocument? {
        try lock.withLock { try readReport(for: period) }
    }
    func readReport(for period: ReportPeriod) throws -> ReportDocument? {
        try statement("SELECT value FROM reports WHERE kind=? AND start=? AND zone=?") {
            try bind(period, to: $0)
            return try stepRow($0) ? try decode(data($0, 0)) : nil
        }
    }

    public func reports(in interval: DateInterval, limit: Int = 100,
                        after cursor: TimelineCursor? = nil) throws -> ReportPage {
        try lock.withLock {
            try validate(interval)
            if let cursor, !cursor.start.timeIntervalSince1970.isFinite { throw AnalysisError.invalidConfiguration }
            let size = min(max(limit, 1), 10_000)
            let clause = cursor == nil ? "" : " AND (start>? OR (start=? AND id>?))"
            return try statement("SELECT value FROM reports WHERE end>? AND start<?\(clause) ORDER BY start,id LIMIT ?") {
                try bind(interval, to: $0)
                if let cursor {
                    try check(sqlite3_bind_double($0, 3, cursor.start.timeIntervalSince1970))
                    try check(sqlite3_bind_double($0, 4, cursor.start.timeIntervalSince1970))
                    try bind(cursor.id.uuidString, at: 5, to: $0)
                }
                try check(sqlite3_bind_int($0, cursor == nil ? 3 : 6, Int32(size + 1)))
                var values: [ReportDocument] = []
                while try stepRow($0) { values.append(try decode(data($0, 0))) }
                let more = values.count > size
                if more { values.removeLast() }
                return ReportPage(reports: values, nextCursor: more ? values.last.map {
                    TimelineCursor(start: $0.period.interval.start, id: $0.id)
                } : nil)
            }
        }
    }

    public func generateReportCandidate(for period: ReportPeriod) throws -> ReportCandidate {
        try lock.withLock {
            try requireWrite()
            return try transaction {
                let timeline = try readTimeline(in: period.interval)
                guard !timeline.isEmpty else { throw AnalysisError.noEvidence }
                let previous = try readReport(for: period)
                let versions = timeline.reduce(into: [UUID: Int64]()) { $0.merge($1.versions) { _, new in new } }
                let candidate = ReportCandidate(id: UUID(), period: period,
                    markdown: ReportRenderer.markdown(period: period, events: timeline),
                    reportID: previous?.id, expectedReportVersion: previous?.version,
                    createdAt: Date(), recordIDs: versions.keys.sorted { $0.uuidString < $1.uuidString })
                let stored = StoredCandidate(candidate: candidate, sourceVersions: versions)
                try statement("INSERT INTO report_candidates VALUES (?,?,?,?,?)") {
                    try bind(candidate.id.uuidString, at: 1, to: $0)
                    try bind(period.kind.rawValue, at: 2, to: $0)
                    try check(sqlite3_bind_double($0, 3, period.interval.start.timeIntervalSince1970))
                    try bind(period.timeZoneIdentifier, at: 4, to: $0)
                    try bind(encode(stored), at: 5, to: $0); try stepDone($0)
                }
                for recordID in candidate.recordIDs {
                    try statement("INSERT INTO candidate_sources VALUES (?,?)") {
                        try bind(candidate.id.uuidString, at: 1, to: $0)
                        try bind(recordID.uuidString, at: 2, to: $0); try stepDone($0)
                    }
                }
                return candidate
            }
        }
    }

    public func reportCandidates(for period: ReportPeriod) throws -> [ReportCandidate] {
        try lock.withLock {
            try statement("SELECT value FROM report_candidates WHERE kind=? AND start=? AND zone=? ORDER BY id") {
                try bind(period, to: $0)
                var result: [ReportCandidate] = []
                while try stepRow($0) {
                    let stored: StoredCandidate = try decode(data($0, 0))
                    result.append(stored.candidate)
                }
                return result.sorted { $0.createdAt < $1.createdAt }
            }
        }
    }

    public func acceptReportCandidate(id: UUID) throws -> ReportDocument {
        try lock.withLock {
            try requireWrite()
            return try transaction {
                let stored: StoredCandidate = try statement("SELECT value FROM report_candidates WHERE id=?") {
                    try bind(id.uuidString, at: 1, to: $0)
                    guard try stepRow($0) else { throw AnalysisError.notFound }
                    return try decode(data($0, 0))
                }
                let candidate = stored.candidate
                let previous = try readReport(for: candidate.period)
                guard previous?.id == candidate.reportID,
                      previous?.version == candidate.expectedReportVersion else { throw AnalysisError.conflict }
                let currentVersions = try readTimeline(in: candidate.period.interval)
                    .reduce(into: [UUID: Int64]()) { $0.merge($1.versions) { _, new in new } }
                guard currentVersions == stored.sourceVersions else { throw AnalysisError.stale }
                let report = ReportDocument(id: previous?.id ?? UUID(), period: candidate.period,
                    markdown: candidate.markdown, version: (previous?.version ?? 0) + 1,
                    isEdited: false, needsReview: false, updatedAt: Date(), recordIDs: candidate.recordIDs)
                try writeReport(report)
                try deleteCandidate(id: id)
                return report
            }
        }
    }

    public func discardReportCandidate(id: UUID) throws {
        try lock.withLock { try requireWrite(); try deleteCandidate(id: id) }
    }
    private func deleteCandidate(id: UUID) throws {
        try statement("DELETE FROM report_candidates WHERE id=?") {
            try bind(id.uuidString, at: 1, to: $0); try stepDone($0)
        }
    }

    public func editReport(id: UUID, markdown: String, expectedVersion: Int64) throws -> ReportDocument {
        try validateMarkdown(markdown)
        return try lock.withLock {
            try requireWrite()
            return try transaction {
                let old: ReportDocument = try statement("SELECT value FROM reports WHERE id=?") {
                    try bind(id.uuidString, at: 1, to: $0)
                    guard try stepRow($0) else { throw AnalysisError.notFound }
                    return try decode(data($0, 0))
                }
                guard old.version == expectedVersion else { throw AnalysisError.conflict }
                let value = ReportDocument(id: id, period: old.period, markdown: markdown,
                    version: old.version + 1, isEdited: true, needsReview: old.needsReview,
                    updatedAt: Date(), recordIDs: old.recordIDs)
                try writeReport(value)
                return value
            }
        }
    }

    private func validateMarkdown(_ markdown: String) throws {
        guard markdown.utf8.count <= 2 * 1_024 * 1_024, !markdown.contains("\0") else { throw AnalysisError.inputTooLarge }
    }

    /// Report bodies also need date deletion when they were manually created without source rows.
    func eraseReports(in interval: DateInterval) throws {
        try statement("DELETE FROM reports WHERE end>? AND start<?") {
            try bind(interval, to: $0); try stepDone($0)
        }
        let ids: [UUID] = try statement("SELECT value FROM report_candidates WHERE start<?") {
            try check(sqlite3_bind_double($0, 1, interval.end.timeIntervalSince1970))
            var ids: [UUID] = []
            while try stepRow($0) {
                let stored: StoredCandidate = try decode(data($0, 0))
                if stored.candidate.period.interval.end > interval.start { ids.append(stored.candidate.id) }
            }
            return ids
        }
        for id in ids { try deleteCandidate(id: id) }
    }

    func eraseReports(before cutoff: Date) throws {
        try statement("DELETE FROM reports WHERE start<?") {
            try check(sqlite3_bind_double($0, 1, cutoff.timeIntervalSince1970)); try stepDone($0)
        }
        try statement("DELETE FROM report_candidates WHERE start<?") {
            try check(sqlite3_bind_double($0, 1, cutoff.timeIntervalSince1970)); try stepDone($0)
        }
    }

    func markReportsForReview(recordID: UUID) throws {
        let affected: [ReportDocument] = try statement("SELECT value FROM reports WHERE id IN (SELECT report_id FROM report_sources WHERE record_id=?)") {
            try bind(recordID.uuidString, at: 1, to: $0)
            var values: [ReportDocument] = []
            while try stepRow($0) { values.append(try decode(data($0, 0))) }
            return values
        }
        for old in affected where !old.needsReview {
            let updated = ReportDocument(id: old.id, period: old.period, markdown: old.markdown,
                version: old.version + 1, isEdited: old.isEdited, needsReview: true,
                updatedAt: old.updatedAt, recordIDs: old.recordIDs)
            try writeReport(updated)
        }
    }

    private func writeReport(_ value: ReportDocument) throws {
        try statement("INSERT INTO reports VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value") {
            try bind(value.id.uuidString, at: 1, to: $0)
            try bind(value.period.kind.rawValue, at: 2, to: $0)
            try check(sqlite3_bind_double($0, 3, value.period.interval.start.timeIntervalSince1970))
            try check(sqlite3_bind_double($0, 4, value.period.interval.end.timeIntervalSince1970))
            try bind(value.period.timeZoneIdentifier, at: 5, to: $0)
            try bind(encode(value), at: 6, to: $0); try stepDone($0)
        }
        try statement("DELETE FROM report_sources WHERE report_id=?") {
            try bind(value.id.uuidString, at: 1, to: $0); try stepDone($0)
        }
        for recordID in value.recordIDs {
            try statement("INSERT INTO report_sources VALUES (?,?)") {
                try bind(value.id.uuidString, at: 1, to: $0)
                try bind(recordID.uuidString, at: 2, to: $0); try stepDone($0)
            }
        }
    }

    private func bind(_ period: ReportPeriod, to statement: OpaquePointer) throws {
        try bind(period.kind.rawValue, at: 1, to: statement)
        try check(sqlite3_bind_double(statement, 2, period.interval.start.timeIntervalSince1970))
        try bind(period.timeZoneIdentifier, at: 3, to: statement)
    }
}

public enum ReportRenderer {
    /// Derived titles and summaries only. Raw content is never loaded during report generation.
    public static func markdown(period: ReportPeriod, events: [TimelineEvent]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: period.timeZoneIdentifier)
        formatter.dateFormat = "yyyy-MM-dd"
        let title = period.kind == .daily ? "日报" : "周报"
        var lines = ["# \(title) · \(formatter.string(from: period.interval.start))", "",
                     "时区：\(period.timeZoneIdentifier)", "",
                     "相邻观测支持的时长：\(Int(events.reduce(0) { $0 + $1.observedSeconds })) 秒。单条观测记为观测点，缺样区间不计时。", ""]
        formatter.dateFormat = "MM-dd HH:mm:ss ZZZZZ"
        for event in events {
            let time = formatter.string(from: event.start)
            let extent = event.observedSeconds == 0 ? "观测点" : "至 \(formatter.string(from: event.end))"
            lines.append("## \(time) · \(extent) · \(escape(event.title ?? "待分析"))")
            lines.append("")
            if let summary = event.summary { lines.append(escape(summary)); lines.append("") }
            lines.append("来源：\(event.sources.map(\.rawValue).sorted().joined(separator: ", "))；状态：\(event.state.rawValue)")
            lines.append("记录：\(event.recordIDs.map(\.uuidString).joined(separator: ", "))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        // Provider text cannot introduce active Markdown links, images or HTML in generated reports.
        var result = value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for character in ["\\", "`", "*", "_", "[", "]", "#", "!"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }
}
