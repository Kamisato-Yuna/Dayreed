import Foundation
import SQLite3
import Testing
@testable import DayreedCore

private struct DomainFixture {
    let directory: URL
    let store: DayreedStore
    let providerID = UUID()
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Dayreed-domain-test-\(UUID())")
        store = try DayreedStore(directory: directory)
        try store.saveProviderConfiguration(ProviderConfiguration(id: providerID, name: "Synthetic", kind: .openAICompatible,
            model: "synthetic", endpoint: URL(string: "http://127.0.0.1/v1/chat/completions")))
        try store.selectProvider(id: providerID)
        try store.updateAnalysisContext(settings: CaptureSettings(historyEnabled: true), paused: false)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    @discardableResult
    func sample(at date: Date, title: String = "资料整理", trigger: CaptureTrigger = .timer,
                analyzed: Bool = true) throws -> UUID {
        let record = try store.append(CaptureRecordInput(capturedAt: date, trigger: trigger,
            applicationBundleIdentifier: "test.synthetic", qualities: SourceQualities(application: .available),
            evidence: [.text("SYNTHETIC_RAW_SECRET", kind: .accessibilityText)]))
        if analyzed {
            try store.saveAnalysis([ActivityClassification(recordID: record.id, title: title, summary: "合成摘要")],
                providerID: providerID, providerVersion: 1, sources: [record.id: [.application]], evidenceIDs: [record.id: []],
                expectedRevision: store.analysisContext().revision, continuitySeconds: 90)
        }
        return record.id
    }
}

@Test func timelineSplitsCrossMidnightWithoutDoubleCountingAndKeepsShortTail() throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let zone = "Asia/Shanghai"
    let boundary = try #require(ISO8601DateFormatter().date(from: "2026-09-07T00:00:00+08:00"))
    try fixture.sample(at: boundary.addingTimeInterval(-30))
    try fixture.sample(at: boundary.addingTimeInterval(30))
    try fixture.sample(at: boundary.addingTimeInterval(40))
    let firstDay = try ReportPeriod(kind: .daily, containing: boundary.addingTimeInterval(-1), timeZoneIdentifier: zone)
    let secondDay = try ReportPeriod(kind: .daily, containing: boundary, timeZoneIdentifier: zone)
    let first = try fixture.store.timeline(in: firstDay.interval).events
    let second = try fixture.store.timeline(in: secondDay.interval).events
    #expect(first.count == 1 && second.count == 1)
    #expect(first[0].observedSeconds == 30)
    #expect(second[0].observedSeconds == 40)
    #expect(first[0].end == second[0].start)
    let week1 = try ReportPeriod(kind: .weekly, containing: boundary.addingTimeInterval(-1), timeZoneIdentifier: zone)
    let week2 = try ReportPeriod(kind: .weekly, containing: boundary, timeZoneIdentifier: zone)
    #expect(week1.interval.end == week2.interval.start)
    #expect(try fixture.store.timeline(in: week1.interval).events[0].observedSeconds == 30)
    #expect(try fixture.store.timeline(in: week2.interval).events[0].observedSeconds == 40)
}

@Test func reportPeriodsRespectDSTISOWeeksAndInvalidZones() throws {
    let date = try #require(ISO8601DateFormatter().date(from: "2026-03-08T12:00:00-07:00"))
    let day = try ReportPeriod(kind: .daily, containing: date, timeZoneIdentifier: "America/Los_Angeles")
    #expect(day.interval.duration == 23 * 3_600)
    let yearBoundary = try #require(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
    let week = try ReportPeriod(kind: .weekly, containing: yearBoundary, timeZoneIdentifier: "UTC")
    #expect(week.interval.start == ISO8601DateFormatter().date(from: "2025-12-29T00:00:00Z"))
    #expect(week.interval.end == ISO8601DateFormatter().date(from: "2026-01-05T00:00:00Z"))
    #expect(throws: AnalysisError.invalidConfiguration) {
        try ReportPeriod(kind: .daily, containing: date, timeZoneIdentifier: "not/a/timezone")
    }
}

@Test func gapsPendingSamplesAndResumeBreakContinuityWithoutDiscardingPoints() throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.sample(at: start)
    try fixture.sample(at: start.addingTimeInterval(30), analyzed: false)
    try fixture.sample(at: start.addingTimeInterval(60))
    try fixture.sample(at: start.addingTimeInterval(70), trigger: .resumed)
    try fixture.sample(at: start.addingTimeInterval(75))
    try fixture.sample(at: start.addingTimeInterval(300))
    let events = try fixture.store.timeline(in: DateInterval(start: start, duration: 400)).events
    #expect(events.count == 5)
    #expect(events.filter { $0.state == .pending }.count == 1)
    #expect(events.reduce(0) { $0 + $1.observedSeconds } == 5)
    #expect(events.last?.observedSeconds == 0)
    for pair in zip(events, events.dropFirst()) { #expect(pair.0.end <= pair.1.start) }
}

@Test func coreTimelinePaginationHasNoOverlapOrLossAtSameTimestamp() throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var ids = Set<UUID>()
    for index in 0..<23 { ids.insert(try fixture.sample(at: start.addingTimeInterval(Double(index / 3)), title: "项目\(index)")) }
    let interval = DateInterval(start: start, duration: 100)
    var cursor: TimelineCursor?
    var values: [TimelineEvent] = []
    repeat {
        let page = try DayreedQueryService(store: fixture.store).timeline(in: interval, limit: 4, after: cursor)
        values += page.events; cursor = page.nextCursor
    } while cursor != nil
    #expect(values.count == 23)
    #expect(Set(values.flatMap(\.recordIDs)) == ids)
    let safeJSON = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    #expect(!safeJSON.contains("SYNTHETIC_RAW_SECRET"))
}

@Test func reportsPersistCandidatesAndProtectConcurrentManualEdits() throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.sample(at: date)
    let period = try ReportPeriod(kind: .daily, containing: date, timeZoneIdentifier: "UTC")
    let service = ReportService(store: fixture.store)
    let candidate = try service.generateCandidate(for: period)
    #expect(try fixture.store.report(for: period) == nil)
    let initial = try service.acceptCandidate(id: candidate.id)
    let edited = try service.edit(id: initial.id, markdown: "# 我的修改", expectedVersion: initial.version)
    let replacement = try service.generateCandidate(for: period)
    #expect(try fixture.store.report(for: period)?.markdown == "# 我的修改")
    let latest = try service.edit(id: initial.id, markdown: "# 第二次修改", expectedVersion: edited.version)
    #expect(throws: AnalysisError.conflict) { try service.acceptCandidate(id: replacement.id) }
    #expect(try fixture.store.report(for: period)?.markdown == latest.markdown)
    #expect(throws: AnalysisError.conflict) { try service.edit(id: initial.id, markdown: "stale", expectedVersion: edited.version) }
    let fresh = try service.generateCandidate(for: period)
    let replaced = try service.acceptCandidate(id: fresh.id)
    #expect(replaced.version == latest.version + 1)
    #expect(!replaced.isEdited)
    let reopened = try DayreedStore(directory: fixture.directory, access: .readOnly)
    #expect(try DayreedQueryService(store: reopened).report(for: period) == replaced)
    #expect(try ReportService(store: reopened).candidates(for: period).map(\.id) == [replacement.id])
    #expect(throws: DayreedStoreError.readOnly) { try ReportService(store: reopened).acceptCandidate(id: replacement.id) }
}

@Test func correctionsSurviveReanalysisAndInvalidateReportCandidates() throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let id = try fixture.sample(at: date)
    let period = try ReportPeriod(kind: .daily, containing: date, timeZoneIdentifier: "UTC")
    let service = ReportService(store: fixture.store)
    let report = try service.acceptCandidate(id: service.generateCandidate(for: period).id)
    let draft = try service.generateCandidate(for: period)
    let corrected = try fixture.store.correctActivity(recordID: id, title: "用户纠正", summary: "纠正摘要", expectedVersion: 1)
    #expect(corrected.isCorrected)
    #expect(try fixture.store.report(for: period)?.needsReview == true)
    #expect(try fixture.store.report(for: period)?.markdown == report.markdown)
    #expect(throws: AnalysisError.conflict) { try service.acceptCandidate(id: draft.id) }
    try fixture.store.saveAnalysis([ActivityClassification(recordID: id, title: "模型重写", summary: "")],
        providerID: fixture.providerID, providerVersion: 1, sources: [id: [.application]], evidenceIDs: [id: []],
        expectedRevision: fixture.store.analysisContext().revision, continuitySeconds: 90)
    #expect(try fixture.store.activityAnnotation(recordID: id)?.classification.title == "用户纠正")
    try fixture.store.clearActivityCorrection(recordID: id, expectedVersion: corrected.version)
    #expect(try fixture.store.activityAnnotation(recordID: id)?.isCorrected == false)
}

@Test(arguments: ["range", "retention", "all"])
func deletionErasesRelatedReportBodiesCandidatesAndAnnotations(_ method: String) throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let id = try fixture.sample(at: date, title: "SYNTHETIC_DERIVED_SECRET")
    let period = try ReportPeriod(kind: .daily, containing: date, timeZoneIdentifier: "UTC")
    let service = ReportService(store: fixture.store)
    let first = try service.generateCandidate(for: period)
    let report = try service.acceptCandidate(id: first.id)
    _ = try service.edit(id: report.id, markdown: "SYNTHETIC_MANUAL_SECRET", expectedVersion: report.version)
    let pending = try service.generateCandidate(for: period)
    switch method {
    case "range": try fixture.store.deleteRecords(in: period.interval)
    case "retention": try fixture.store.applyRetention(days: 1, now: date.addingTimeInterval(3 * 86_400))
    default: try fixture.store.deleteAll()
    }
    #expect(try fixture.store.activityAnnotation(recordID: id) == nil)
    #expect(try fixture.store.report(for: period) == nil)
    #expect(try service.candidates(for: period).isEmpty)
    #expect(throws: AnalysisError.notFound) { try service.acceptCandidate(id: pending.id) }
    let bytes = try Data(contentsOf: fixture.directory.appendingPathComponent("records.sqlite3"))
    for marker in ["SYNTHETIC_DERIVED_SECRET", "SYNTHETIC_MANUAL_SECRET", "SYNTHETIC_RAW_SECRET"] {
        #expect(bytes.range(of: Data(marker.utf8)) == nil)
    }
}

@Test func candidateDetectsNewEvidenceAndReportsPaginate() throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    try fixture.sample(at: date)
    let period = try ReportPeriod(kind: .daily, containing: date, timeZoneIdentifier: "UTC")
    let service = ReportService(store: fixture.store)
    let stale = try service.generateCandidate(for: period)
    try fixture.sample(at: date.addingTimeInterval(60))
    #expect(throws: AnalysisError.stale) { try service.acceptCandidate(id: stale.id) }
    for index in 0..<7 {
        let current = date.addingTimeInterval(Double(index) * 86_400)
        if index > 0 { try fixture.sample(at: current) }
        let day = try ReportPeriod(kind: .daily, containing: current, timeZoneIdentifier: "UTC")
        _ = try service.acceptCandidate(id: service.generateCandidate(for: day).id)
    }
    var cursor: TimelineCursor?
    var ids = Set<UUID>()
    repeat {
        let page = try fixture.store.reports(in: DateInterval(start: period.interval.start, duration: 8 * 86_400), limit: 2, after: cursor)
        ids.formUnion(page.reports.map(\.id)); cursor = page.nextCursor
    } while cursor != nil
    #expect(ids.count == 7)
}

@Test func versionOneDatabaseMigratesWithoutLosingCaptureRecords() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Dayreed-migration-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var db: OpaquePointer?
    #expect(sqlite3_open(directory.appendingPathComponent("records.sqlite3").path, &db) == SQLITE_OK)
    let sql = """
        CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL,captured_at REAL NOT NULL,trigger TEXT NOT NULL,bundle_id TEXT,qualities BLOB NOT NULL);
        CREATE TABLE evidence(id TEXT PRIMARY KEY NOT NULL,record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,kind TEXT NOT NULL,media_type TEXT NOT NULL,content BLOB NOT NULL,UNIQUE(record_id,kind));
        PRAGMA user_version=1;
        """
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let store = try DayreedStore(directory: directory)
    #expect(try store.analysisContext().paused)
    #expect(try store.providerConfigurations().isEmpty)
    let input = CaptureRecordInput(capturedAt: Date(), trigger: .manual, qualities: SourceQualities())
    try store.append(input)
    #expect(try store.records(in: DateInterval(start: input.capturedAt, duration: 1)).records.first?.id == input.id)
}

@Test func batchCorrectionIsAtomicAcrossConflictPendingAndDeletedRecords() throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let first = try fixture.sample(at: date)
    let second = try fixture.sample(at: date.addingTimeInterval(60))
    #expect(throws: AnalysisError.conflict) {
        try fixture.store.correctActivities(recordIDs: [first, second], expectedVersions: [first: 1, second: 99], title: "新标题", summary: "")
    }
    #expect(try fixture.store.activityAnnotation(recordID: first)?.version == 1)
    #expect(try fixture.store.activityAnnotation(recordID: first)?.classification.title == "资料整理")
    let corrected = try fixture.store.correctActivities(recordIDs: [first, second], expectedVersions: [first: 1, second: 1],
                                                       title: "合并纠正", summary: "手工纠正")
    #expect(corrected.count == 2 && corrected.allSatisfy { $0.version == 2 && $0.isCorrected })
    let pending = try fixture.sample(at: date.addingTimeInterval(70), analyzed: false)
    #expect(throws: AnalysisError.notFound) {
        try fixture.store.correctActivities(recordIDs: [first, pending], expectedVersions: [first: 2, pending: 0], title: "不应部分写入", summary: "")
    }
    try fixture.store.deleteRecords(in: DateInterval(start: date.addingTimeInterval(60), duration: 1))
    #expect(throws: AnalysisError.notFound) {
        try fixture.store.correctActivities(recordIDs: [first, second], expectedVersions: [first: 2, second: 2], title: "不应部分写入", summary: "")
    }
    #expect(try fixture.store.activityAnnotation(recordID: first)?.version == 2)
    #expect(try fixture.store.activityAnnotation(recordID: first)?.classification.title == "合并纠正")
}

@Test func manualReportCanBeCreatedWithoutEvidenceAndConcurrentCreateHasOneWinner() async throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let period = try ReportPeriod(kind: .daily, containing: Date(timeIntervalSince1970: 1_800_000_000), timeZoneIdentifier: "UTC")
    let secondConnection = try DayreedStore(directory: fixture.directory)
    let firstService = ReportService(store: fixture.store), secondService = ReportService(store: secondConnection)
    let results = await withTaskGroup(of: Bool.self) { group in
        group.addTask { (try? firstService.create(for: period, markdown: "# 手工 A")) != nil }
        group.addTask { (try? secondService.create(for: period, markdown: "# 手工 B")) != nil }
        var results: [Bool] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(results.filter { $0 }.count == 1)
    let report = try #require(try fixture.store.report(for: period))
    #expect(report.recordIDs.isEmpty && report.isEdited && report.version == 1)
    #expect(throws: AnalysisError.conflict) { try firstService.create(for: period, markdown: "不覆盖") }
    #expect(try fixture.store.report(for: period)?.markdown == report.markdown)
}

@Test(arguments: ["range", "retention", "all"])
func manualReportsWithoutSourceRowsFollowDateDeletion(_ method: String) throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let period = try ReportPeriod(kind: .daily, containing: date, timeZoneIdentifier: "UTC")
    let later = try ReportPeriod(kind: .daily, containing: date.addingTimeInterval(7 * 86_400), timeZoneIdentifier: "UTC")
    _ = try ReportService(store: fixture.store).create(for: period, markdown: "SYNTHETIC_MANUAL_WITHOUT_SOURCE")
    _ = try ReportService(store: fixture.store).create(for: later, markdown: "保留新日报")
    switch method {
    case "range": try fixture.store.deleteRecords(in: period.interval)
    case "retention": try fixture.store.applyRetention(days: 1, now: later.interval.start)
    default: try fixture.store.deleteAll()
    }
    #expect(try fixture.store.report(for: period) == nil)
    #expect(try fixture.store.report(for: later) != nil || method == "all")
    let bytes = try Data(contentsOf: fixture.directory.appendingPathComponent("records.sqlite3"))
    #expect(bytes.range(of: Data("SYNTHETIC_MANUAL_WITHOUT_SOURCE".utf8)) == nil)
}

@Test func deletionSummaryMatchesDateAndCrossBoundaryCascadeUnion() throws {
    let fixture = try DomainFixture(); defer { fixture.cleanup() }
    let boundary = try #require(ISO8601DateFormatter().date(from: "2026-09-07T00:00:00Z"))
    try fixture.sample(at: boundary.addingTimeInterval(-30))
    try fixture.sample(at: boundary.addingTimeInterval(30))
    let previous = try ReportPeriod(kind: .daily, containing: boundary.addingTimeInterval(-1), timeZoneIdentifier: "UTC")
    let current = try ReportPeriod(kind: .daily, containing: boundary, timeZoneIdentifier: "UTC")
    let later = try ReportPeriod(kind: .daily, containing: boundary.addingTimeInterval(2 * 86_400), timeZoneIdentifier: "UTC")
    let service = ReportService(store: fixture.store)
    for period in [previous, current] {
        _ = try service.acceptCandidate(id: service.generateCandidate(for: period).id)
        _ = try service.generateCandidate(for: period)
    }
    _ = try service.create(for: later, markdown: "无记录手工报告")
    let reopened = try DayreedStore(directory: fixture.directory, access: .readOnly)
    let summary = try reopened.deletionSummary(in: previous.interval)
    #expect(summary.recordCount == 1 && summary.reportCount == 2 && summary.candidateCount == 2)
    #expect(!summary.isEmpty)
    #expect(try reopened.deletionSummary(in: later.interval).recordCount == 0)
    #expect(try reopened.deletionSummary(in: later.interval).reportCount == 1)
    #expect(try reopened.deletionSummary(in: DateInterval(start: boundary, duration: 0)).isEmpty)
    try fixture.store.deleteRecords(in: previous.interval)
    #expect(try fixture.store.report(for: previous) == nil && fixture.store.report(for: current) == nil)
    #expect(try service.candidates(for: previous).isEmpty && service.candidates(for: current).isEmpty)
    #expect(try fixture.store.report(for: later) != nil)
}
