import Foundation
import SQLite3

extension DayreedStore {
    func migrateAnalysisSchema() throws {
        try transaction {
            try execute("""
                CREATE TABLE provider_configurations (id TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);
                CREATE TABLE analysis_preferences (id INTEGER PRIMARY KEY CHECK(id=1), schedule BLOB NOT NULL, status BLOB NOT NULL);
                CREATE TABLE analysis_context (
                  id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL,
                  settings BLOB NOT NULL, paused INTEGER NOT NULL,
                  provider_id TEXT REFERENCES provider_configurations(id) ON DELETE SET NULL
                );
                CREATE TABLE activity_annotations (
                  record_id TEXT PRIMARY KEY NOT NULL REFERENCES records(id) ON DELETE CASCADE,
                  value BLOB NOT NULL
                );
                CREATE TABLE reports (
                  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
                  zone TEXT NOT NULL, value BLOB NOT NULL, UNIQUE(kind,start,zone)
                );
                CREATE TABLE report_sources (
                  report_id TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
                  record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
                  PRIMARY KEY(report_id,record_id)
                );
                CREATE INDEX report_sources_by_record ON report_sources(record_id);
                CREATE TABLE report_candidates (
                  id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, start REAL NOT NULL,
                  zone TEXT NOT NULL, value BLOB NOT NULL
                );
                CREATE TABLE candidate_sources (
                  candidate_id TEXT NOT NULL REFERENCES report_candidates(id) ON DELETE CASCADE,
                  record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
                  PRIMARY KEY(candidate_id,record_id)
                );
                CREATE INDEX candidate_sources_by_record ON candidate_sources(record_id);
                CREATE TRIGGER erase_derived_content BEFORE DELETE ON records BEGIN
                  DELETE FROM reports WHERE id IN
                    (SELECT report_id FROM report_sources WHERE record_id=OLD.id);
                  DELETE FROM report_candidates WHERE id IN
                    (SELECT candidate_id FROM candidate_sources WHERE record_id=OLD.id);
                  UPDATE analysis_context SET revision=revision+1 WHERE id=1;
                END;
                PRAGMA user_version=2;
                """)
            try statement("INSERT INTO analysis_context VALUES (1,0,?,1,NULL)") {
                try bind(encode(CaptureSettings()), at: 1, to: $0)
                try stepDone($0)
            }
            try statement("INSERT INTO analysis_preferences VALUES (1,?,?)") {
                try bind(encode(AnalysisSchedule()), at: 1, to: $0)
                try bind(encode(AnalysisRunStatus()), at: 2, to: $0)
                try stepDone($0)
            }
        }
    }

    public func analysisSchedule() throws -> AnalysisSchedule {
        try lock.withLock {
            try statement("SELECT schedule FROM analysis_preferences WHERE id=1") {
                guard try stepRow($0) else { throw DayreedStoreError.invalidRecord }
                return try decode(data($0, 0))
            }
        }
    }
    public func saveAnalysisSchedule(_ value: AnalysisSchedule) throws {
        try value.validate()
        try lock.withLock {
            try requireWrite()
            try statement("UPDATE analysis_preferences SET schedule=? WHERE id=1") {
                try bind(encode(value), at: 1, to: $0); try stepDone($0)
            }
        }
    }
    public func analysisRunStatus() throws -> AnalysisRunStatus {
        try lock.withLock {
            try statement("SELECT status FROM analysis_preferences WHERE id=1") {
                guard try stepRow($0) else { throw DayreedStoreError.invalidRecord }
                return try decode(data($0, 0))
            }
        }
    }
    public func saveAnalysisRunStatus(_ value: AnalysisRunStatus) throws {
        try lock.withLock {
            try requireWrite()
            try statement("UPDATE analysis_preferences SET status=? WHERE id=1") {
                try bind(encode(value), at: 1, to: $0); try stepDone($0)
            }
        }
    }

    public func providerConfigurations() throws -> [ProviderConfiguration] {
        try lock.withLock {
            try statement("SELECT value FROM provider_configurations ORDER BY id") {
                var result: [ProviderConfiguration] = []
                while try stepRow($0) { result.append(try decode(data($0, 0))) }
                return result
            }
        }
    }

    public func saveProviderConfiguration(_ configuration: ProviderConfiguration) throws {
        try configuration.validate()
        try lock.withLock {
            try requireWrite()
            try transaction {
                var saved = configuration
                let previous: ProviderConfiguration? = try statement("SELECT value FROM provider_configurations WHERE id=?") {
                    try bind(configuration.id.uuidString, at: 1, to: $0)
                    return try stepRow($0) ? try decode(data($0, 0)) : nil
                }
                saved.version = (previous?.version ?? 0) + 1
                try statement("INSERT INTO provider_configurations VALUES (?,?) ON CONFLICT(id) DO UPDATE SET value=excluded.value") {
                    try bind(configuration.id.uuidString, at: 1, to: $0)
                    try bind(encode(saved), at: 2, to: $0)
                    try stepDone($0)
                }
                try advanceAnalysisRevision()
            }
        }
    }

    public func selectProvider(id: UUID?) throws {
        try lock.withLock {
            try requireWrite()
            try statement("UPDATE analysis_context SET provider_id=?,revision=revision+1 WHERE id=1") {
                try bind(id?.uuidString, at: 1, to: $0)
                try stepDone($0)
            }
        }
    }

    public func removeProviderConfiguration(id: UUID) throws {
        try lock.withLock {
            try requireWrite()
            try transaction {
                try statement("DELETE FROM provider_configurations WHERE id=?") {
                    try bind(id.uuidString, at: 1, to: $0); try stepDone($0)
                }
                try advanceAnalysisRevision()
            }
        }
    }

    public func analysisContext() throws -> AnalysisContext {
        try lock.withLock { try readAnalysisContext() }
    }

    /// Call before changing capture state in the App. This is synchronous with result commits.
    public func updateAnalysisContext(settings: CaptureSettings, paused: Bool) throws {
        try lock.withLock {
            try requireWrite()
            try statement("UPDATE analysis_context SET settings=?,paused=?,revision=revision+1 WHERE id=1") {
                try bind(encode(settings.normalized), at: 1, to: $0)
                try check(sqlite3_bind_int($0, 2, paused ? 1 : 0))
                try stepDone($0)
            }
        }
    }

    public func invalidatePendingAnalysis() throws {
        try lock.withLock { try requireWrite(); try advanceAnalysisRevision() }
    }

    func advanceAnalysisRevision() throws {
        try execute("UPDATE analysis_context SET revision=revision+1 WHERE id=1")
    }

    func readAnalysisContext() throws -> AnalysisContext {
        try statement("SELECT revision,settings,paused,provider_id FROM analysis_context WHERE id=1") {
            guard try stepRow($0) else { throw DayreedStoreError.invalidRecord }
            return AnalysisContext(revision: sqlite3_column_int64($0, 0), settings: try decode(data($0, 1)),
                                   paused: sqlite3_column_int($0, 2) != 0,
                                   selectedProviderID: string($0, 3).flatMap(UUID.init(uuidString:)))
        }
    }

    public func activityAnnotation(recordID: UUID) throws -> ActivityAnnotation? {
        try lock.withLock { try readAnnotation(recordID: recordID) }
    }

    func readAnnotation(recordID: UUID) throws -> ActivityAnnotation? {
        try statement("SELECT value FROM activity_annotations WHERE record_id=?") {
            try bind(recordID.uuidString, at: 1, to: $0)
            return try stepRow($0) ? try decode(data($0, 0)) : nil
        }
    }

    /// Checks source choice and evidence existence again inside the write transaction.
    /// A deletion, pause, configuration change or correction invalidates an outstanding revision.
    public func saveAnalysis(_ classifications: [ActivityClassification], providerID: UUID, providerVersion: Int64,
                             sources: [UUID: Set<AnalysisSource>], evidenceIDs: [UUID: [UUID]],
                             expectedRevision: Int64, continuitySeconds: Double, now: Date = Date()) throws {
        guard !classifications.isEmpty, Set(classifications.map(\.recordID)).count == classifications.count,
              continuitySeconds.isFinite, (0...5_400).contains(continuitySeconds),
              now.timeIntervalSince1970.isFinite else { throw AnalysisError.invalidResponse }
        try classifications.forEach { try $0.validate() }
        try lock.withLock {
            try requireWrite()
            try transaction {
                let context = try readAnalysisContext()
                guard context.revision == expectedRevision else { throw AnalysisError.stale }
                guard !context.paused else { throw AnalysisError.paused }
                guard context.selectedProviderID == providerID else { throw AnalysisError.stale }
                let allowed = context.settings.analysisSources
                for classification in classifications {
                    guard let usedSources = sources[classification.recordID], !usedSources.isEmpty,
                          usedSources.isSubset(of: allowed) else { throw AnalysisError.stale }
                    let refs = try evidenceReferences(recordID: classification.recordID)
                    let usedIDs = evidenceIDs[classification.recordID] ?? []
                    guard Set(usedIDs).isSubset(of: Set(refs.map(\.id))),
                          refs.filter({ usedIDs.contains($0.id) }).allSatisfy({ usedSources.contains($0.kind.analysisSource) }) else {
                        throw AnalysisError.stale
                    }
                    try statement("SELECT bundle_id FROM records WHERE id=?") {
                        try bind(classification.recordID.uuidString, at: 1, to: $0)
                        guard try stepRow($0) else { throw AnalysisError.stale }
                        if let bundle = string($0, 0), context.settings.excludedBundleIdentifiers.contains(bundle) {
                            throw AnalysisError.stale
                        }
                    }
                    let previous = try readAnnotation(recordID: classification.recordID)
                    // A deliberate user correction is never silently replaced by a provider.
                    if previous?.isCorrected == true { continue }
                    let annotation = ActivityAnnotation(classification: classification, providerID: providerID,
                        providerVersion: providerVersion,
                        sources: usedSources, evidenceIDs: usedIDs, version: (previous?.version ?? 0) + 1,
                        isCorrected: false, continuitySeconds: continuitySeconds, analyzedAt: now)
                    try writeAnnotation(annotation)
                    try markReportsForReview(recordID: classification.recordID)
                }
            }
        }
    }

    @discardableResult
    public func correctActivity(recordID: UUID, title: String, summary: String,
                                expectedVersion: Int64) throws -> ActivityAnnotation {
        let values = try correctActivities(recordIDs: [recordID], expectedVersions: [recordID: expectedVersion],
                                          title: title, summary: summary)
        guard let first = values.first else { throw AnalysisError.notFound }
        return first
    }

    /// All records in a merged event are checked and corrected in one transaction. No partial edit.
    @discardableResult
    public func correctActivities(recordIDs: [UUID], expectedVersions: [UUID: Int64],
                                   title: String, summary: String) throws -> [ActivityAnnotation] {
        guard !recordIDs.isEmpty, Set(recordIDs).count == recordIDs.count,
              Set(recordIDs) == Set(expectedVersions.keys) else { throw AnalysisError.invalidConfiguration }
        try ActivityClassification(recordID: recordIDs[0], title: title, summary: summary).validate()
        return try lock.withLock {
            try requireWrite()
            return try transaction {
                let values = try recordIDs.map { recordID in
                    guard let previous = try readAnnotation(recordID: recordID) else { throw AnalysisError.notFound }
                    guard previous.version == expectedVersions[recordID] else { throw AnalysisError.conflict }
                    return ActivityAnnotation(classification: ActivityClassification(recordID: recordID, title: title, summary: summary),
                        providerID: previous.providerID, providerVersion: previous.providerVersion,
                        sources: previous.sources, evidenceIDs: previous.evidenceIDs, version: previous.version + 1,
                        isCorrected: true, continuitySeconds: previous.continuitySeconds, analyzedAt: previous.analyzedAt)
                }
                for value in values {
                    try writeAnnotation(value)
                    try markReportsForReview(recordID: value.classification.recordID)
                }
                try advanceAnalysisRevision()
                return values
            }
        }
    }

    /// Explicitly allow reanalysis after a correction; no network call is made by this operation.
    public func clearActivityCorrection(recordID: UUID, expectedVersion: Int64) throws {
        try lock.withLock {
            try requireWrite()
            try transaction {
                guard let previous = try readAnnotation(recordID: recordID) else { throw AnalysisError.notFound }
                guard previous.version == expectedVersion else { throw AnalysisError.conflict }
                try writeAnnotation(ActivityAnnotation(classification: previous.classification,
                    providerID: previous.providerID, providerVersion: previous.providerVersion,
                    sources: previous.sources, evidenceIDs: previous.evidenceIDs,
                    version: previous.version + 1, isCorrected: false,
                    continuitySeconds: previous.continuitySeconds, analyzedAt: previous.analyzedAt))
                try markReportsForReview(recordID: recordID)
                try advanceAnalysisRevision()
            }
        }
    }

    func writeAnnotation(_ value: ActivityAnnotation) throws {
        try statement("INSERT INTO activity_annotations VALUES (?,?) ON CONFLICT(record_id) DO UPDATE SET value=excluded.value") {
            try bind(value.classification.recordID.uuidString, at: 1, to: $0)
            try bind(encode(value), at: 2, to: $0); try stepDone($0)
        }
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw DayreedStoreError.invalidRecord }
    }
    func decode<T: Decodable>(_ value: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: value) }
        catch { throw DayreedStoreError.invalidRecord }
    }
}
