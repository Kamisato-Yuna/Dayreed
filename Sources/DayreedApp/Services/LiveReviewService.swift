import DayreedCapture
import DayreedCore
import Foundation
import Observation

/// One app-owned adapter. Database creation and bulk reads/deletes run away from the UI actor.
@MainActor @Observable
final class LiveReviewService: ReviewService {
    private(set) var coordinator: CaptureCoordinator?
    private(set) var initializationFailed = false
    private(set) var revision = 0
    private(set) var deletionInProgress = false
    private(set) var isReviewWriting = false
    @ObservationIgnored private let persistence: CapturePreferences
    @ObservationIgnored private let directory: @Sendable () throws -> URL
    @ObservationIgnored private let environment: (any CaptureEnvironment)?
    @ObservationIgnored private let automaticallySchedules: Bool
    @ObservationIgnored private var database: DayreedStore?
    @ObservationIgnored private var opening: Task<DayreedStore, Error>?
    @ObservationIgnored private let evidencePresenter = EvidencePresenter()

    init(defaults: UserDefaults = .standard,
         directory: @escaping @Sendable () throws -> URL = { try DayreedDataDirectory.defaultURL() },
         environment: (any CaptureEnvironment)? = nil, automaticallySchedules: Bool = true) {
        persistence = CapturePreferences(defaults: defaults)
        self.directory = directory
        self.environment = environment
        self.automaticallySchedules = automaticallySchedules
    }

    var capabilities: ReviewCapabilities {
        ReviewCapabilities(read: true, saveReport: true, correctEvent: true, openEvidence: true, configure: true, generateReport: true)
    }
    var unavailableReason: String? { initializationFailed ? "本地存储未能打开，请重试。" : nil }

    @discardableResult
    func prepare() async throws -> DayreedStore {
        if let database { return database }
        let task: Task<DayreedStore, Error>
        if let opening { task = opening }
        else {
            let directory = directory
            task = Task.detached { try DayreedStore(directory: directory()) }
            opening = task
        }
        do {
            let opened = try await task.value
            if database == nil {
                database = opened
                let settings = persistence.load()
                let capture = CaptureCoordinator(store: opened, settings: settings, environment: environment,
                                                 automaticallySchedules: automaticallySchedules)
                coordinator = capture
                // A saved source selection is the user's ongoing capture preference.
                // First launch with all sources off neither starts collection nor requests TCC.
                if settings.hasEnabledSources { capture.start() }
            }
            opening = nil
            initializationFailed = false
            return opened
        } catch {
            opening = nil
            initializationFailed = true
            throw ReviewServiceError.failed
        }
    }

    func load(_ query: ReviewQuery) async throws -> ReviewSnapshot {
        let database = try await prepare()
        do { return try await Task.detached { try LiveReviewMapping.snapshot(store: database, query: query) }.value }
        catch { throw LiveReviewMapping.error(error) }
    }

    func records(in interval: DateInterval) async throws -> [CaptureRecordSummary] {
        let database = try await prepare()
        return try await Task.detached { try LiveReviewMapping.records(store: database, interval: interval) }.value
    }

    func open(evidence: ReviewEvidence) async throws {
        guard let id = UUID(uuidString: evidence.id) else { throw ReviewServiceError.failed }
        let database = try await prepare()
        let raw = try await Task.detached { try database.rawEvidence(id: id) }.value
        guard let raw else { throw ReviewServiceError.failed }
        try evidencePresenter.show(raw)
    }

    func preferences() async throws -> ReviewPreferences {
        _ = try await prepare()
        return ReviewPreferences(capture: persistence.load())
    }

    func save(preferences: ReviewPreferences) async throws -> ReviewPreferences {
        _ = try await prepare()
        guard !deletionInProgress else { throw ReviewServiceError.failed }
        let settings = preferences.captureSettings
        try persistence.save(settings)
        coordinator?.updateSettings(settings)
        if coordinator?.state.mode == .stopped && settings.hasEnabledSources { coordinator?.start() }
        return try await self.preferences()
    }

    func control(_ action: CaptureAction) {
        guard !deletionInProgress, let coordinator else { return }
        switch action {
        case .start: coordinator.start(); coordinator.resume()
        case .pause: coordinator.pause()
        case .resume: coordinator.resume()
        case .stop: coordinator.stop()
        case .refreshPermissions: coordinator.refreshPermissions()
        case .screenPermission: coordinator.requestScreenRecordingPermission()
        case .accessibilityPermission: coordinator.requestAccessibilityPermission()
        }
    }

    /// Pauses before counting; confirmation uses this fixed half-open interval and exact count.
    func prepareDeletion(date: Date) async throws -> RecordDeletion {
        _ = try await prepare()
        coordinator?.pause()
        guard !isReviewWriting else { throw ReviewServiceError.failed }
        let interval = Calendar.current.dateInterval(of: .day, for: date)!
        let database = try await prepare()
        let summary = try await Task.detached { try database.deletionSummary(in: interval) }.value
        return RecordDeletion(interval: interval, count: summary.recordCount, reportCount: summary.reportCount, candidateCount: summary.candidateCount)
    }

    func delete(_ deletion: RecordDeletion) async throws {
        guard !deletionInProgress, !isReviewWriting else { throw ReviewServiceError.failed }
        deletionInProgress = true
        defer { deletionInProgress = false }
        let database = try await prepare()
        coordinator?.pause()
        // Recheck while paused: a changed count requires a fresh confirmation.
        let current = try await Task.detached { try database.deletionSummary(in: deletion.interval) }.value
        guard current.recordCount == deletion.count, current.reportCount == deletion.reportCount, current.candidateCount == deletion.candidateCount else { throw ReviewServiceError.conflict }
        _ = try await Task.detached { try database.deleteRecords(in: deletion.interval) }.value
        evidencePresenter.close()
        revision += 1
    }

    func save(markdown: String, report: ReviewReport?, query: ReviewQuery) async throws -> ReviewReport {
        let database = try await prepare()
        try beginReviewWrite()
        defer { isReviewWriting = false }
        do {
            return try await Task.detached {
                let reports = ReportService(store: database)
                if let report {
                    guard let id = UUID(uuidString: report.id), let version = report.version else { throw AnalysisError.conflict }
                    _ = try reports.edit(id: id, markdown: markdown, expectedVersion: version)
                } else {
                    _ = try reports.create(for: LiveReviewMapping.period(query), markdown: markdown)
                }
                guard let result = try LiveReviewMapping.snapshot(store: database, query: query).report else { throw ReviewServiceError.failed }
                return result
            }.value
        } catch { throw LiveReviewMapping.error(error) }
    }

    func regenerate(_ query: ReviewQuery) async throws -> ReviewSnapshot {
        guard query.kind != nil else { throw ReviewServiceError.unavailable }
        let database = try await prepare()
        try beginReviewWrite()
        defer { isReviewWriting = false }
        do {
            return try await Task.detached {
                _ = try ReportService(store: database).generateCandidate(for: LiveReviewMapping.period(query))
                return try LiveReviewMapping.snapshot(store: database, query: query)
            }.value
        } catch { throw LiveReviewMapping.error(error) }
    }

    func accept(candidate: ReviewReportCandidate, query: ReviewQuery) async throws -> ReviewSnapshot {
        try await changeCandidate(candidate, query: query, accept: true)
    }
    func discard(candidate: ReviewReportCandidate, query: ReviewQuery) async throws -> ReviewSnapshot {
        try await changeCandidate(candidate, query: query, accept: false)
    }
    private func changeCandidate(_ candidate: ReviewReportCandidate, query: ReviewQuery, accept: Bool) async throws -> ReviewSnapshot {
        guard let id = UUID(uuidString: candidate.id) else { throw ReviewServiceError.failed }
        let database = try await prepare()
        try beginReviewWrite()
        defer { isReviewWriting = false }
        do {
            return try await Task.detached {
                let reports = ReportService(store: database)
                guard try reports.candidates(for: LiveReviewMapping.period(query)).contains(where: { $0.id == id }) else { throw AnalysisError.notFound }
                if accept { _ = try reports.acceptCandidate(id: id) }
                else { try reports.discardCandidate(id: id) }
                return try LiveReviewMapping.snapshot(store: database, query: query)
            }.value
        } catch { throw LiveReviewMapping.error(error) }
    }

    func correct(event: ReviewEvent, title: String, summary: String) async throws -> ReviewEvent {
        guard event.isCorrectable else { throw ReviewServiceError.unavailable }
        let versions = Dictionary(uniqueKeysWithValues: event.recordVersions.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        guard !versions.isEmpty, versions.count == event.recordVersions.count else { throw ReviewServiceError.failed }
        let database = try await prepare()
        try beginReviewWrite()
        defer { isReviewWriting = false }
        do {
            let annotations = try await Task.detached {
                try database.correctActivities(recordIDs: Array(versions.keys), expectedVersions: versions, title: title, summary: summary)
            }.value
            var result = event
            result.title = title; result.summary = summary
            result.recordVersions = Dictionary(uniqueKeysWithValues: annotations.map { ($0.classification.recordID.uuidString, $0.version) })
            result.stateTitle = "已人工纠正 · 重新分析会保留纠正"
            return result
        } catch { throw LiveReviewMapping.error(error) }
    }
    private func beginReviewWrite() throws {
        guard !deletionInProgress, !isReviewWriting else { throw ReviewServiceError.failed }
        isReviewWriting = true
    }
    func checkUpdates() async throws -> String { throw ReviewServiceError.unavailable }
}

enum CaptureAction { case start, pause, resume, stop, refreshPermissions, screenPermission, accessibilityPermission }
struct RecordDeletion: Identifiable {
    let id = UUID()
    let interval: DateInterval
    let count: Int
    let reportCount: Int
    let candidateCount: Int
    var isEmpty: Bool { count == 0 && reportCount == 0 && candidateCount == 0 }
    var summary: String { "\(count) 条采集记录、\(reportCount) 份报告、\(candidateCount) 份候选" }
}
