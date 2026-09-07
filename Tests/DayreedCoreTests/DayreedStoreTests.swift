import Foundation
import SQLite3
import Testing
@testable import DayreedCore

private struct StoreFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayreed-test-\(UUID())")
    let store: DayreedStore
    init() throws { store = try DayreedStore(directory: directory) }
    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private func sample(at date: Date, id: UUID = UUID()) -> CaptureRecordInput {
    CaptureRecordInput(id: id, capturedAt: date, trigger: .manual,
                       applicationBundleIdentifier: "test.synthetic",
                       qualities: SourceQualities(screenshot: .available, application: .available,
                                                 windowTitle: .available, accessibilityText: .available),
                       evidence: [EvidenceInput(kind: .screenshot, mediaType: "image/png", data: Data([1, 2, 3])),
                                  .text("SYNTHETIC_WINDOW_SECRET", kind: .windowTitle),
                                  .text("SYNTHETIC_AX_SECRET", kind: .accessibilityText)])
}

@Test func storePersistsEvidenceAndDefaultProjectionOmitsRawContent() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let inserted = try fixture.store.append(sample(at: date))
    let reopened = try DayreedStore(directory: fixture.directory, access: .readOnly)
    let records = try reopened.records(in: DateInterval(start: date, duration: 1)).records
    #expect(records.count == 1)
    #expect(records.first?.id == inserted.id)
    #expect(records.first?.evidence.count == 3)
    let json = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
    #expect(!json.contains("SYNTHETIC_WINDOW_SECRET"))
    #expect(!json.contains("SYNTHETIC_AX_SECRET"))
    let reference = try #require(records.first?.evidence.first(where: { $0.kind == .accessibilityText }))
    let raw = try #require(try reopened.rawEvidence(id: reference.id))
    #expect(raw.recordID == inserted.id)
    #expect(String(decoding: raw.data, as: UTF8.self) == "SYNTHETIC_AX_SECRET")
    #expect(!String(reflecting: raw).contains("SYNTHETIC_AX_SECRET"))
    #expect(!String(reflecting: sample(at: date)).contains("SYNTHETIC_AX_SECRET"))
    #expect(throws: DayreedStoreError.readOnly) { try reopened.deleteAll() }
    #expect(throws: DayreedStoreError.readOnly) { try reopened.append(sample(at: date)) }
    #expect(throws: DayreedStoreError.readOnly) { try reopened.applyRetention(days: 1) }
}

@Test func deletionCascadesAndRespectsHalfOpenDateBoundaries() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let before = try fixture.store.append(sample(at: start.addingTimeInterval(-0.001)))
    let inside = try fixture.store.append(sample(at: start))
    let atEnd = try fixture.store.append(sample(at: start.addingTimeInterval(60)))
    let interval = DateInterval(start: start, duration: 60)
    #expect(try fixture.store.records(in: interval).records.map(\.id) == [inside.id])
    #expect(try fixture.store.deleteRecords(in: interval) == 1)
    for evidence in inside.evidence { #expect(try fixture.store.rawEvidence(id: evidence.id) == nil) }
    #expect(try fixture.store.rawEvidence(id: before.evidence[0].id) != nil)
    #expect(try fixture.store.rawEvidence(id: atEnd.evidence[0].id) != nil)
    #expect(try fixture.store.deleteAll() == 2)
    #expect(try fixture.store.rawEvidence(id: atEnd.evidence[0].id) == nil)
    let databaseBytes = try Data(contentsOf: fixture.directory.appendingPathComponent("records.sqlite3"))
    #expect(databaseBytes.range(of: Data("SYNTHETIC_AX_SECRET".utf8)) == nil)
    #expect(databaseBytes.range(of: Data("SYNTHETIC_WINDOW_SECRET".utf8)) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("records.sqlite3-wal").path))
}

@Test func retentionUsesCalendarDaysAcrossDSTAndLocalMidnight() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
    let cutoff = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
    #expect(calendar.startOfDay(for: now).timeIntervalSince(cutoff) == 23 * 3_600)
    let old = try fixture.store.append(sample(at: cutoff.addingTimeInterval(-0.001)))
    let kept = try fixture.store.append(sample(at: cutoff))
    try fixture.store.append(sample(at: now))
    #expect(try fixture.store.applyRetention(days: 2, now: now, calendar: calendar) == 1)
    #expect(try fixture.store.rawEvidence(id: old.evidence[0].id) == nil)
    #expect(try fixture.store.rawEvidence(id: kept.evidence[0].id) != nil)
    #expect(throws: DayreedStoreError.invalidRetention) {
        try fixture.store.applyRetention(days: 0, now: now, calendar: calendar)
    }
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let midnight = calendar.startOfDay(for: now)
    #expect(try fixture.store.records(in: DateInterval(start: midnight, duration: 86_400)).records.count == 1)
}

@Test func duplicateAndFailedEvidenceWritesLeaveNoPartialRecord() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let first = sample(at: date)
    try fixture.store.append(first)
    #expect(throws: (any Error).self) { try fixture.store.append(first) }
    var db: OpaquePointer?
    #expect(sqlite3_open(fixture.directory.appendingPathComponent("records.sqlite3").path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    // Force the second table write to fail and prove the first table write rolls back.
    #expect(sqlite3_exec(db, "CREATE TRIGGER fail_evidence BEFORE INSERT ON evidence BEGIN SELECT RAISE(ABORT, 'synthetic'); END;", nil, nil, nil) == SQLITE_OK)
    #expect(throws: (any Error).self) { try fixture.store.append(sample(at: date)) }
    #expect(try fixture.store.records(in: DateInterval(start: date, duration: 1)).records.count == 1)
}

@Test func storeUsesPrivateFilesystemModesAndRejectsSymlinkDatabase() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
    let database = fixture.directory.appendingPathComponent("records.sqlite3")
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: database.path)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let alias = fixture.directory.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias.appendingPathComponent("records.sqlite3"), withDestinationURL: database)
    #expect(throws: DayreedStoreError.fileAccess) { try DayreedStore(directory: alias) }
}

@Test func paginationCoversMoreThanDefaultLimitIncludingEqualTimestamps() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var expected: [CaptureRecordInput] = []
    // Cross the default page size, with many equal timestamps at the page boundary.
    for index in 0..<507 {
        let input = CaptureRecordInput(capturedAt: start.addingTimeInterval(Double(index / 200)), trigger: .timer,
                                       qualities: SourceQualities(application: .available))
        expected.append(input)
        try fixture.store.append(input)
    }
    let interval = DateInterval(start: start, duration: 3)
    let first = try fixture.store.records(in: interval)
    #expect(first.records.count == 500)
    let cursor = try #require(first.nextCursor)
    let second = try fixture.store.records(in: interval, after: cursor)
    #expect(second.records.count == 7)
    #expect(second.nextCursor == nil)
    let ordered = expected.sorted {
        ($0.capturedAt, $0.id.uuidString) < ($1.capturedAt, $1.id.uuidString)
    }.map(\.id)
    #expect((first.records + second.records).map(\.id) == ordered)
    var all: [UUID] = []
    var after: CaptureRecordCursor?
    repeat {
        let page = try fixture.store.records(in: interval, limit: 100, after: after)
        #expect(page.records.count <= 100)
        all.append(contentsOf: page.records.map(\.id))
        after = page.nextCursor
    } while after != nil
    #expect(all == ordered)
    #expect(Set(all).count == 507)
    let empty = try fixture.store.records(in: DateInterval(start: start.addingTimeInterval(3), duration: 1))
    #expect(empty.records.isEmpty)
    #expect(empty.nextCursor == nil)
    let exact = try fixture.store.records(in: interval, limit: 507)
    #expect(exact.nextCursor == nil)
}
