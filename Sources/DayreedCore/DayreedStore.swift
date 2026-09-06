import Foundation
import SQLite3

/// Errors deliberately omit SQL, paths, raw content and SQLite's error message.
public enum DayreedStoreError: Error, Equatable, Sendable {
    case database(Int32), fileAccess, unsupportedSchema, invalidRecord, readOnly, invalidRetention
}

/// One connection, serialized operations, and ordinary SQLite transactions. The database holds
/// raw evidence as BLOBs so record/evidence insertion and deletion cannot leave orphan files.
public final class DayreedStore: @unchecked Sendable {
    public enum Access: Sendable { case readWrite, readOnly }
    let connection: OpaquePointer
    let lock = NSLock()
    private let access: Access
    private static let schemaVersion: Int32 = 2
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL, access: Access = .readWrite) throws {
        self.access = access
        // macOS temporary/Application Support paths may traverse /var or other directory aliases.
        // Resolve the caller's directory, while keeping the database leaf protected by NOFOLLOW.
        var file = directory.appendingPathComponent("records.sqlite3")
        do {
            if access == .readWrite {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                guard directoryAttributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw DayreedStoreError.fileAccess
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            // Foundation can preserve /var aliases when the leaf did not exist yet. POSIX
            // realpath after directory creation gives SQLite the actual no-symlink pathname.
            guard let resolved = directory.path.withCString({ realpath($0, nil) }) else {
                throw DayreedStoreError.fileAccess
            }
            defer { free(resolved) }
            file = URL(fileURLWithFileSystemRepresentation: resolved, isDirectory: true, relativeTo: nil)
                .appendingPathComponent("records.sqlite3")
            if access == .readWrite {
                if !FileManager.default.fileExists(atPath: file.path) {
                    guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        throw DayreedStoreError.fileAccess
                    }
                }
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw DayreedStoreError.fileAccess }
            if access == .readWrite {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        } catch { throw DayreedStoreError.fileAccess }
        var handle: OpaquePointer?
        let flags = (access == .readWrite ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY)
            | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let status = sqlite3_open_v2(file.path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw DayreedStoreError.database(status)
        }
        connection = handle
        do {
            sqlite3_busy_timeout(handle, 2_000)
            try execute("PRAGMA foreign_keys=ON")
            let version = try scalarInt("PRAGMA user_version")
            guard version == Self.schemaVersion || ((0...1).contains(version) && access == .readWrite) else {
                throw DayreedStoreError.unsupportedSchema
            }
            if access == .readWrite {
                // DELETE avoids long-lived WAL copies; secure_delete clears freed content in the DB.
                try execute("PRAGMA journal_mode=DELETE")
                try execute("PRAGMA secure_delete=ON")
                if version == 0 {
                    try transaction {
                        try execute("""
                            CREATE TABLE records (
                              id TEXT PRIMARY KEY NOT NULL,
                              captured_at REAL NOT NULL,
                              trigger TEXT NOT NULL,
                              bundle_id TEXT,
                              qualities BLOB NOT NULL
                            );
                            CREATE INDEX records_by_date ON records(captured_at, id);
                            CREATE TABLE evidence (
                              id TEXT PRIMARY KEY NOT NULL,
                              record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
                              kind TEXT NOT NULL,
                              media_type TEXT NOT NULL,
                              content BLOB NOT NULL,
                              UNIQUE(record_id, kind)
                            );
                            PRAGMA user_version=1;
                            """)
                    }
                }
                if version < 2 { try migrateAnalysisSchema() }
            } else {
                try execute("PRAGMA query_only=ON")
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    @discardableResult
    public func append(_ record: CaptureRecordInput) throws -> CaptureRecordSummary {
        try lock.withLock {
            try requireWrite()
            guard record.capturedAt.timeIntervalSince1970.isFinite,
                  record.evidence.count <= 3,
                  (record.applicationBundleIdentifier?.utf8.count ?? 0) <= 1_024,
                  Set(record.evidence.map(\.kind)).count == record.evidence.count,
                  record.evidence.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 32 * 1_024 * 1_024
                      && !$0.mediaType.isEmpty && $0.mediaType.utf8.count <= 128 }) else {
                throw DayreedStoreError.invalidRecord
            }
            let qualities: Data
            do { qualities = try JSONEncoder().encode(record.qualities) }
            catch { throw DayreedStoreError.invalidRecord }
            let references = record.evidence.map { EvidenceReference(id: UUID(), kind: $0.kind, byteCount: $0.data.count) }
            try transaction {
                try statement("INSERT INTO records VALUES (?, ?, ?, ?, ?)") { statement in
                    try bind(record.id.uuidString, at: 1, to: statement)
                    try check(sqlite3_bind_double(statement, 2, record.capturedAt.timeIntervalSince1970))
                    try bind(record.trigger.rawValue, at: 3, to: statement)
                    try bind(record.applicationBundleIdentifier, at: 4, to: statement)
                    try bind(qualities, at: 5, to: statement)
                    try stepDone(statement)
                }
                for (input, reference) in zip(record.evidence, references) {
                    try statement("INSERT INTO evidence VALUES (?, ?, ?, ?, ?)") { statement in
                        try bind(reference.id.uuidString, at: 1, to: statement)
                        try bind(record.id.uuidString, at: 2, to: statement)
                        try bind(input.kind.rawValue, at: 3, to: statement)
                        try bind(input.mediaType, at: 4, to: statement)
                        try bind(input.data, at: 5, to: statement)
                        try stepDone(statement)
                    }
                }
            }
            return CaptureRecordSummary(id: record.id, capturedAt: record.capturedAt, trigger: record.trigger,
                                        applicationBundleIdentifier: record.applicationBundleIdentifier,
                                        qualities: record.qualities, evidence: references)
        }
    }

    /// Half-open [start, end), oldest first. Follow nextCursor until nil for complete coverage.
    /// Keep the same interval across pages. Concurrent deletions or backdated inserts can change
    /// a later read; this is a live query, not a frozen report snapshot.
    public func records(in interval: DateInterval, limit: Int = 500,
                        after cursor: CaptureRecordCursor? = nil) throws -> CaptureRecordPage {
        try lock.withLock {
            try validate(interval)
            if let cursor, !cursor.capturedAt.timeIntervalSince1970.isFinite { throw DayreedStoreError.invalidRecord }
            let pageSize = min(max(limit, 1), 10_000)
            let cursorClause = cursor == nil ? "" : " AND (captured_at > ? OR (captured_at = ? AND id > ?))"
            return try statement("""
                SELECT id, captured_at, trigger, bundle_id, qualities FROM records
                WHERE captured_at >= ? AND captured_at < ?\(cursorClause) ORDER BY captured_at, id LIMIT ?
                """) { statement in
                try bind(interval, to: statement)
                if let cursor {
                    try check(sqlite3_bind_double(statement, 3, cursor.capturedAt.timeIntervalSince1970))
                    try check(sqlite3_bind_double(statement, 4, cursor.capturedAt.timeIntervalSince1970))
                    try bind(cursor.id.uuidString, at: 5, to: statement)
                }
                try check(sqlite3_bind_int(statement, cursor == nil ? 3 : 6, Int32(pageSize + 1)))
                var records: [CaptureRecordSummary] = []
                while try stepRow(statement) {
                    guard let id = UUID(uuidString: string(statement, 0) ?? ""),
                          let trigger = CaptureTrigger(rawValue: string(statement, 2) ?? ""),
                          let qualities = try? JSONDecoder().decode(SourceQualities.self, from: data(statement, 4)) else {
                        throw DayreedStoreError.invalidRecord
                    }
                    records.append(CaptureRecordSummary(
                        id: id, capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        trigger: trigger, applicationBundleIdentifier: string(statement, 3), qualities: qualities,
                        evidence: try evidenceReferences(recordID: id)
                    ))
                }
                let hasMore = records.count > pageSize
                if hasMore { records.removeLast() }
                let nextCursor = hasMore ? records.last.map { CaptureRecordCursor(capturedAt: $0.capturedAt, id: $0.id) } : nil
                return CaptureRecordPage(records: records, nextCursor: nextCursor)
            }
        }
    }

    public func rawEvidence(id: UUID) throws -> RawEvidence? {
        try lock.withLock {
            try statement("SELECT record_id, kind, media_type, content FROM evidence WHERE id=?") { statement in
                try bind(id.uuidString, at: 1, to: statement)
                guard try stepRow(statement) else { return nil }
                guard let recordID = UUID(uuidString: string(statement, 0) ?? ""),
                      let kind = EvidenceKind(rawValue: string(statement, 1) ?? ""),
                      let mediaType = string(statement, 2) else { throw DayreedStoreError.invalidRecord }
                return RawEvidence(id: id, recordID: recordID, kind: kind, mediaType: mediaType, data: data(statement, 3))
            }
        }
    }

    /// Deletes evidence and associated derived report bodies in the same transaction.
    @discardableResult
    public func deleteRecords(in interval: DateInterval) throws -> Int {
        try lock.withLock {
            try requireWrite()
            try validate(interval)
            return try transaction {
                try statement("DELETE FROM records WHERE captured_at >= ? AND captured_at < ?") { statement in
                    try bind(interval, to: statement)
                    try stepDone(statement)
                    return Int(sqlite3_changes(connection))
                }
            }
        }
    }

    @discardableResult
    public func deleteAll() throws -> Int {
        try lock.withLock {
            try requireWrite()
            return try transaction {
                try execute("DELETE FROM records")
                return Int(sqlite3_changes(connection))
            }
        }
    }

    /// Keeps today and the preceding days-1 calendar days in the caller's timezone.
    /// This removes database content; it cannot erase filesystem snapshots or external backups.
    @discardableResult
    public func applyRetention(days: Int, now: Date = Date(), calendar: Calendar = .current) throws -> Int {
        guard (1...3_650).contains(days), now.timeIntervalSince1970.isFinite,
              let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else {
            throw DayreedStoreError.invalidRetention
        }
        return try lock.withLock {
            try requireWrite()
            return try transaction {
                try statement("DELETE FROM records WHERE captured_at < ?") { statement in
                    try check(sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970))
                    try stepDone(statement)
                    return Int(sqlite3_changes(connection))
                }
            }
        }
    }

    func evidenceReferences(recordID: UUID) throws -> [EvidenceReference] {
        try statement("SELECT id, kind, length(content) FROM evidence WHERE record_id=? ORDER BY kind") { statement in
            try bind(recordID.uuidString, at: 1, to: statement)
            var references: [EvidenceReference] = []
            while try stepRow(statement) {
                guard let id = UUID(uuidString: string(statement, 0) ?? ""),
                      let kind = EvidenceKind(rawValue: string(statement, 1) ?? "") else {
                    throw DayreedStoreError.invalidRecord
                }
                references.append(EvidenceReference(id: id, kind: kind, byteCount: Int(sqlite3_column_int64(statement, 2))))
            }
            return references
        }
    }

    func requireWrite() throws {
        guard access == .readWrite else { throw DayreedStoreError.readOnly }
    }

    func validate(_ interval: DateInterval) throws {
        guard interval.start.timeIntervalSince1970.isFinite, interval.end.timeIntervalSince1970.isFinite else {
            throw DayreedStoreError.invalidRecord
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String) throws { try check(sqlite3_exec(connection, sql, nil, nil, nil)) }

    func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(connection, sql, -1, &statement, nil))
        guard let statement else { throw DayreedStoreError.database(SQLITE_ERROR) }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func scalarInt(_ sql: String) throws -> Int32 {
        try statement(sql) { statement in
            guard try stepRow(statement) else { throw DayreedStoreError.database(SQLITE_ERROR) }
            return sqlite3_column_int(statement, 0)
        }
    }

    func check(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw DayreedStoreError.database(status) }
    }

    func stepDone(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw DayreedStoreError.database(status) }
    }

    func stepRow(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw DayreedStoreError.database(status)
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        if let value {
            try value.withCString { pointer in
                try check(sqlite3_bind_text(statement, index, pointer, Int32(value.utf8.count), Self.transient))
            }
        } else {
            try check(sqlite3_bind_null(statement, index))
        }
    }

    func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        try value.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient))
        }
    }

    func bind(_ interval: DateInterval, to statement: OpaquePointer) throws {
        try check(sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970))
        try check(sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970))
    }

    func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, index) else { return nil }
        let buffer = UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index)))
        return String(decoding: buffer, as: UTF8.self)
    }

    func data(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
