import DayreedCapture
import DayreedAnalysis
import DayreedCore
import Foundation
import Observation

/// One app-owned adapter. Database creation and bulk reads/deletes run away from the UI actor.
@MainActor @Observable
final class LiveReviewService: ReviewService {
    private(set) var analysis: LiveAnalysisController?
    private(set) var isTransitioning = false
    private(set) var coordinator: CaptureCoordinator?
    private(set) var initializationFailed = false
    private(set) var revision = 0
    private(set) var deletionInProgress = false
    private(set) var isReviewWriting = false
    @ObservationIgnored private let persistence: CapturePreferences
    @ObservationIgnored private let directory: @Sendable () throws -> URL
    @ObservationIgnored private let environment: (any CaptureEnvironment)?
    @ObservationIgnored private let credentials: any ProviderCredentialStore
    @ObservationIgnored private let providerFactory: AnalysisProviderFactory?
    @ObservationIgnored private let automaticallySchedules: Bool
    @ObservationIgnored private var database: DayreedStore?
    @ObservationIgnored private var opening: Task<DayreedStore, Error>?
    @ObservationIgnored private let evidencePresenter = EvidencePresenter()

    init(defaults: UserDefaults = .standard,
         directory: @escaping @Sendable () throws -> URL = { try DayreedDataDirectory.defaultURL() },
         environment: (any CaptureEnvironment)? = nil, automaticallySchedules: Bool = true,
         credentials: any ProviderCredentialStore = KeychainCredentialStore(), providerFactory: AnalysisProviderFactory? = nil) {
        persistence = CapturePreferences(defaults: defaults)
        self.directory = directory
        self.environment = environment
        self.automaticallySchedules = automaticallySchedules
        self.credentials = credentials; self.providerFactory = providerFactory
    }

    var capabilities: ReviewCapabilities {
        ReviewCapabilities(read: true, saveReport: true, regenerate: analysis?.selectedID != nil, correctEvent: true, openEvidence: true, configure: true, generateReport: true)
    }
    var unavailableReason: String? { initializationFailed ? "本地存储未能打开，请重试。" : nil }

    @discardableResult
    func prepare() async throws -> DayreedStore {
        if let database { return database }
        let task: Task<DayreedStore, Error>
        if let opening { task = opening }
        else {
            task = Task { @MainActor in
                let directory = self.directory
                let opened = try await Task.detached { try DayreedStore(directory: directory()) }.value
                let settings = self.persistence.load()
                let analysis = try await LiveAnalysisController.make(database: opened, credentials: self.credentials, factory: self.providerFactory)
                try await analysis.updateContext(settings: settings, paused: true)
                let capture = CaptureCoordinator(store: opened, settings: settings, environment: self.environment,
                                                 automaticallySchedules: self.automaticallySchedules)
                self.analysis = analysis
                self.coordinator = capture
                if settings.hasEnabledSources { capture.start() }
                try await analysis.updateContext(settings: settings, paused: capture.state.mode != .running)
                try await analysis.restoreSchedule()
                self.database = opened
                self.observeCaptureMode()
                return opened
            }
            opening = task
        }
        do {
            let opened = try await task.value
            opening = nil; initializationFailed = false
            return opened
        } catch {
            coordinator?.stop()
            opening = nil; initializationFailed = true
            throw ReviewServiceError.failed
        }
    }

    private func observeCaptureMode() {
        guard let coordinator else { return }
        withObservationTracking { _ = coordinator.state.mode } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeCaptureMode()
                guard !self.isTransitioning, !self.deletionInProgress else { return }
                try? await self.synchronizeAnalysisContext()
            }
        }
    }

    private func synchronizeAnalysisContext() async throws {
        guard let coordinator, let analysis else { return }
        try await analysis.updateContext(settings: coordinator.settings, paused: coordinator.state.mode != .running || deletionInProgress)
    }

    var enabledSourceDescription: String {
        let sources = coordinator?.settings.analysisSources ?? []
        let names = sources.map { source in
            switch source {
            case .application: "应用历史"
            case .screenshot: "截图"
            case .windowTitle: "窗口标题"
            case .accessibilityText: "辅助功能文本"
            }
        }.sorted()
        return names.isEmpty ? "全部关闭" : names.joined(separator: "、")
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
        guard !deletionInProgress, !isTransitioning else { throw ReviewServiceError.failed }
        isTransitioning = true
        defer { isTransitioning = false }
        let settings = preferences.captureSettings
        try await analysis?.updateContext(settings: settings, paused: true)
        try persistence.save(settings)
        coordinator?.updateSettings(settings)
        if coordinator?.state.mode == .stopped && settings.hasEnabledSources { coordinator?.start() }
        try await synchronizeAnalysisContext()
        return try await self.preferences()
    }

    func control(_ action: CaptureAction) async throws {
        guard !deletionInProgress, !isTransitioning, let coordinator else { throw ReviewServiceError.failed }
        isTransitioning = true
        defer { isTransitioning = false }
        switch action {
        case .refreshPermissions: coordinator.refreshPermissions(); return
        case .screenPermission: coordinator.requestScreenRecordingPermission(); return
        case .accessibilityPermission: coordinator.requestAccessibilityPermission(); return
        default: break
        }
        do {
            try await analysis?.updateContext(settings: coordinator.settings, paused: true)
            switch action {
            case .start: coordinator.start(); coordinator.resume()
            case .pause: coordinator.pause()
            case .resume: coordinator.resume()
            case .stop: coordinator.stop()
            default: break
            }
            try await synchronizeAnalysisContext()
        } catch {
            coordinator.pause()
            await analysis?.service.stopSchedule()
            throw LiveReviewMapping.error(error)
        }
    }

    /// Pauses before counting; confirmation uses this fixed half-open interval and exact count.
    func prepareDeletion(date: Date) async throws -> RecordDeletion {
        _ = try await prepare()
        try await control(.pause)
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
        if let coordinator { try await analysis?.updateContext(settings: coordinator.settings, paused: true); coordinator.pause() }
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
        let database = try await prepare()
        if query.kind == nil {
            guard !deletionInProgress, !isTransitioning, let analysis else { throw ReviewServiceError.unavailable }
            try await analysis.analyze(query.interval)
            return try await load(query)
        }
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
    func shutdown() async -> Bool {
        isTransitioning = true
        defer { isTransitioning = false }
        coordinator?.stop()
        evidencePresenter.close()
        guard let analysis else { return true }
        await analysis.service.stopSchedule()
        do {
            if let coordinator { try await analysis.updateContext(settings: coordinator.settings, paused: true) }
            try await analysis.cancel()
        } catch { return false }
        // Allow the owned CLI runner to terminate its exact child before the App exits.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await analysis.service.status.phase == .running {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return true
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
