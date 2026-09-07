import Foundation
import SQLite3

/// The App and read-only CLI/MCP can depend on Core alone. This service has no raw access,
/// provider, arbitrary SQL, path, or command execution interface.
public struct DayreedQueryService: Sendable {
    private let store: DayreedStore
    public init(store: DayreedStore) { self.store = store }

    public func timeline(in interval: DateInterval, limit: Int = 100,
                         after cursor: TimelineCursor? = nil) throws -> TimelinePage {
        try store.timeline(in: interval, limit: limit, after: cursor)
    }
    public func report(for period: ReportPeriod) throws -> ReportDocument? { try store.report(for: period) }
    public func analysisStatus() throws -> AnalysisRunStatus { try store.analysisRunStatus() }
    public func reports(in interval: DateInterval, limit: Int = 100,
                        after cursor: TimelineCursor? = nil) throws -> ReportPage {
        try store.reports(in: interval, limit: limit, after: cursor)
    }
}

extension DayreedStore {
    public func timeline(in interval: DateInterval, limit: Int = 100,
                         after cursor: TimelineCursor? = nil) throws -> TimelinePage {
        try lock.withLock {
            try validate(interval)
            if let cursor, !cursor.start.timeIntervalSince1970.isFinite { throw AnalysisError.invalidConfiguration }
            return try readTransaction {
                let all = try readTimeline(in: interval).filter { event in
                    guard let cursor else { return true }
                    return event.start > cursor.start || (event.start == cursor.start && event.id.uuidString > cursor.id.uuidString)
                }
                let size = min(max(limit, 1), 10_000)
                let events = Array(all.prefix(size))
                let next = all.count > size ? events.last.map { TimelineCursor(start: $0.start, id: $0.id) } : nil
                return TimelinePage(events: events, nextCursor: next)
            }
        }
    }

    func readTimeline(in interval: DateInterval) throws -> [TimelineEvent] {
        // Include neighboring observations so daily totals split a cross-midnight span correctly.
        // 5400 is the largest supported adjacency interval, not an extrapolated activity window.
        let expanded = DateInterval(start: interval.start.addingTimeInterval(-5_400),
                                    end: interval.end.addingTimeInterval(5_400))
        return TimelineComposer.compose(try readObservations(in: expanded), clippingTo: interval)
    }

    func readObservations(in interval: DateInterval) throws -> [ActivityObservation] {
        try statement("""
            SELECT r.id,r.captured_at,r.trigger,r.bundle_id,r.qualities,a.value
            FROM records r LEFT JOIN activity_annotations a ON a.record_id=r.id
            WHERE r.captured_at>=? AND r.captured_at<? ORDER BY r.captured_at,r.id
            """) { statement in
            try bind(interval, to: statement)
            var result: [ActivityObservation] = []
            while try stepRow(statement) {
                guard let id = string(statement, 0).flatMap(UUID.init(uuidString:)),
                      let trigger = string(statement, 2).flatMap(CaptureTrigger.init(rawValue:)) else {
                    throw DayreedStoreError.invalidRecord
                }
                let record = CaptureRecordSummary(id: id,
                    capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                    trigger: trigger, applicationBundleIdentifier: string(statement, 3),
                    qualities: try decode(data(statement, 4)), evidence: try evidenceReferences(recordID: id))
                let annotation: ActivityAnnotation? = sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil : try decode(data(statement, 5))
                result.append(ActivityObservation(record: record, annotation: annotation))
            }
            return result
        }
    }

    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

public enum TimelineComposer {
    /// A point observation survives without a following sample. No evidence means no duration.
    /// Both sources classify the same record, so their support contributes once to this union.
    public static func compose(_ observations: [ActivityObservation], clippingTo interval: DateInterval) -> [TimelineEvent] {
        guard interval.duration > 0 else { return [] }
        let sorted = observations.sorted {
            $0.record.capturedAt == $1.record.capturedAt
                ? $0.record.id.uuidString < $1.record.id.uuidString : $0.record.capturedAt < $1.record.capturedAt
        }
        var groups: [[ActivityObservation]] = []
        for current in sorted {
            if let previous = groups.last?.last, canConnect(previous, current) {
                groups[groups.count - 1].append(current)
            } else {
                groups.append([current])
            }
        }
        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let start = max(first.record.capturedAt, interval.start)
            let end = min(last.record.capturedAt, interval.end)
            // Half-open point semantics; a span ending at start contributes no event to this day.
            guard start < interval.end, end >= start,
                  last.record.capturedAt > interval.start || first.record.capturedAt >= interval.start else { return nil }
            let annotations = group.compactMap(\.annotation)
            let summaries = annotations.map(\.classification.summary).reduce(into: [String]()) {
                if !$1.isEmpty && !$0.contains($1) { $0.append($1) }
            }
            return TimelineEvent(id: first.record.id, start: start, end: end,
                title: first.annotation?.classification.title, summary: summaries.isEmpty ? nil : summaries.joined(separator: "\n"),
                state: annotations.isEmpty ? .pending : (annotations.contains(where: \.isCorrected) ? .corrected : .analyzed),
                sources: annotations.reduce(into: Set<AnalysisSource>()) { $0.formUnion($1.sources) },
                recordIDs: group.map(\.record.id), evidenceIDs: Array(Set(annotations.flatMap(\.evidenceIDs))).sorted { $0.uuidString < $1.uuidString },
                versions: Dictionary(uniqueKeysWithValues: group.map { ($0.record.id, $0.annotation?.version ?? 0) }))
        }.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }

    private static func canConnect(_ previous: ActivityObservation, _ current: ActivityObservation) -> Bool {
        guard let a = previous.annotation, let b = current.annotation,
              a.classification.title == b.classification.title,
              previous.record.applicationBundleIdentifier == current.record.applicationBundleIdentifier,
              current.record.trigger != .started, current.record.trigger != .resumed else { return false }
        let gap = current.record.capturedAt.timeIntervalSince(previous.record.capturedAt)
        return gap >= 0 && gap <= min(a.continuitySeconds, b.continuitySeconds)
    }
}
