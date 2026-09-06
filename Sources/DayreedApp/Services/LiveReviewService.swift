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
        ReviewCapabilities(read: true, openEvidence: true, configure: true)
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
        let records = try await records(in: query.interval)
        return ReviewSnapshot(events: records.map(Self.unanalyzedEvent))
    }

    func records(in interval: DateInterval) async throws -> [CaptureRecordSummary] {
        let database = try await prepare()
        return try await Task.detached {
            var records: [CaptureRecordSummary] = []
            var cursor: CaptureRecordCursor?
            repeat {
                let page = try database.records(in: interval, after: cursor)
                records.append(contentsOf: page.records)
                cursor = page.nextCursor
            } while cursor != nil
            return records
        }.value
    }

    nonisolated private static func unanalyzedEvent(_ record: CaptureRecordSummary) -> ReviewEvent {
        ReviewEvent(id: record.id.uuidString, start: record.capturedAt, end: record.capturedAt,
                    title: "待分析的采集记录", summary: "本地证据已记录。配置 Provider 后可分析已启用的来源。",
                    application: record.applicationBundleIdentifier ?? "",
                    evidence: record.evidence.map { reference in
            let source: EvidenceSource = switch reference.kind {
            case .screenshot: .screenshot
            case .windowTitle: .windowTitle
            case .accessibilityText: .accessibility
            }
            return ReviewEvidence(id: reference.id.uuidString, source: source,
                                  capturedAt: record.capturedAt, label: source.title + " · 本机证据")
        })
    }

    func open(evidence: ReviewEvidence) async throws {
        guard let id = UUID(uuidString: evidence.id) else { throw ReviewServiceError.failed }
        let database = try await prepare()
        let raw = try await Task.detached { try database.rawEvidence(id: id) }.value
        guard let raw else { throw ReviewServiceError.failed }
        evidencePresenter.show(raw)
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
        let interval = Calendar.current.dateInterval(of: .day, for: date)!
        return RecordDeletion(interval: interval, count: try await records(in: interval).count)
    }

    func delete(_ deletion: RecordDeletion) async throws {
        guard !deletionInProgress else { throw ReviewServiceError.failed }
        let database = try await prepare()
        coordinator?.pause()
        deletionInProgress = true
        defer { deletionInProgress = false }
        // Recheck while paused: a changed count requires a fresh confirmation.
        guard try await records(in: deletion.interval).count == deletion.count else { throw ReviewServiceError.conflict }
        _ = try await Task.detached { try database.deleteRecords(in: deletion.interval) }.value
        evidencePresenter.close()
        revision += 1
    }

    func save(markdown: String, report: ReviewReport?, query: ReviewQuery) async throws -> ReviewReport { throw ReviewServiceError.unavailable }
    func regenerate(_ query: ReviewQuery) async throws -> ReviewSnapshot { throw ReviewServiceError.unavailable }
    func correct(event: ReviewEvent, title: String, summary: String) async throws -> ReviewEvent { throw ReviewServiceError.unavailable }
    func checkUpdates() async throws -> String { throw ReviewServiceError.unavailable }
}

enum CaptureAction { case start, pause, resume, stop, refreshPermissions, screenPermission, accessibilityPermission }
struct RecordDeletion: Identifiable {
    let id = UUID()
    let interval: DateInterval
    let count: Int
}
