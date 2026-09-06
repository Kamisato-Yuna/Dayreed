import DayreedCore
import Foundation

public typealias AnalysisProviderFactory = @Sendable (ProviderConfiguration) throws -> any AnalysisProvider

/// Explicit user-selected analysis. Initialization does not start a process, make a request, read raw
/// evidence, or enable capture. Keep one service for the App's store; UI actions await context changes.
public actor AnalysisService {
    private let store: DayreedStore
    private let providerFactory: AnalysisProviderFactory
    private let pageSize: Int
    private let batchSize: Int
    private var activeRequest: Task<[ActivityClassification], any Error>?
    private var scheduleTask: Task<Void, Never>?
    private var isRunning = false
    public private(set) var status: AnalysisRunStatus

    public init(store: DayreedStore, credentials: any ProviderCredentialStore = KeychainCredentialStore(),
                pageSize: Int = 250, batchSize: Int = 8, providerFactory: AnalysisProviderFactory? = nil) throws {
        self.store = store; self.pageSize = min(max(pageSize, 1), 10_000); self.batchSize = min(max(batchSize, 1), 100)
        self.providerFactory = providerFactory ?? { configuration in
            let key = configuration.kind == .openAICompatible || configuration.cliAuthentication == .dayreedAPIKey
                ? try credentials.read(for: configuration.id) : nil
            return try configuration.kind == .openAICompatible
                ? OpenAICompatibleProvider(configuration: configuration, apiKey: key)
                : CLIProvider(configuration: configuration, apiKey: key)
        }
        let previous = try store.analysisRunStatus()
        if previous.phase == .running {
            self.status = AnalysisRunStatus(phase: .cancelled, processedRecords: previous.processedRecords, error: .cancelled)
            try store.saveAnalysisRunStatus(self.status)
        } else { self.status = previous }
    }

    deinit { activeRequest?.cancel(); scheduleTask?.cancel() }

    public func updateCaptureContext(settings: CaptureSettings, paused: Bool) throws {
        // Store commit and invalidation serialize on the same database lock.
        try store.updateAnalysisContext(settings: settings, paused: paused)
        activeRequest?.cancel()
    }

    public func cancel() throws {
        try store.invalidatePendingAnalysis()
        activeRequest?.cancel()
    }

    @discardableResult
    public func analyze(in interval: DateInterval, reanalyze: Bool = false) async throws -> AnalysisRunStatus {
        guard !isRunning else { throw AnalysisError.busy }
        isRunning = true
        defer { isRunning = false; activeRequest = nil }
        var processed = 0
        do {
            guard interval.duration > 0, interval.start.timeIntervalSince1970.isFinite,
                  interval.end.timeIntervalSince1970.isFinite else { throw AnalysisError.invalidConfiguration }
            let context = try store.analysisContext()
            guard !context.paused else { throw AnalysisError.paused }
            guard context.settings.hasEnabledSources else { throw AnalysisError.sourcesDisabled }
            guard let providerID = context.selectedProviderID,
                  let configuration = try store.providerConfigurations().first(where: { $0.id == providerID }) else {
                throw AnalysisError.notConfigured
            }
            try configuration.validate()
            let provider = try providerFactory(configuration)
            try updateStatus(phase: .running, processed: 0)
            var cursor: CaptureRecordCursor?
            var batch: [ProviderObservation] = []
            var bytes = 0, eligible = 0
            repeat {
                try Task.checkCancellation()
                try checkContext(context)
                let page = try store.records(in: interval, limit: pageSize, after: cursor)
                for record in page.records {
                    try Task.checkCancellation()
                    if let bundle = record.applicationBundleIdentifier,
                       context.settings.excludedBundleIdentifiers.contains(bundle) { continue }
                    if let existing = try store.activityAnnotation(recordID: record.id),
                       existing.isCorrected || (!reanalyze && existing.providerID == providerID &&
                        existing.providerVersion == configuration.version &&
                        existing.sources == usableSources(record, settings: context.settings)) {
                        eligible += 1; continue
                    }
                    guard let observation = try assemble(record, settings: context.settings) else { continue }
                    eligible += 1
                    let weight = observation.evidence.reduce(0) { $0 + $1.data.count } + 1_024
                    guard weight <= 8 * 1_024 * 1_024 else { throw AnalysisError.inputTooLarge }
                    if !batch.isEmpty && (batch.count >= batchSize || bytes + weight > 8 * 1_024 * 1_024) {
                        processed += try await submit(batch, provider: provider, context: context, configuration: configuration)
                        try updateStatus(phase: .running, processed: processed)
                        batch = []; bytes = 0
                    }
                    batch.append(observation); bytes += weight
                }
                cursor = page.nextCursor
            } while cursor != nil
            if !batch.isEmpty { processed += try await submit(batch, provider: provider, context: context, configuration: configuration) }
            try Task.checkCancellation()
            try checkContext(context)
            guard eligible > 0 else { throw AnalysisError.noEvidence }
            try updateStatus(phase: .completed, processed: processed)
            return status
        } catch {
            let safe = Self.safeError(error)
            // Successfully completed earlier batches remain visible; this run still reports failure.
            try updateStatus(phase: safe == .cancelled ? .cancelled : .failed, processed: processed, error: safe)
            throw safe
        }
    }

    /// Persisted opt-in scheduling. The first run happens after the configured interval.
    /// Reuse enabled capture settings; this never turns a source on or resumes capture.
    public func configureSchedule(_ schedule: AnalysisSchedule) throws {
        try store.saveAnalysisSchedule(schedule)
        try restoreSchedule()
    }

    /// Call on App launch only after restoring user capture choices into updateCaptureContext.
    public func restoreSchedule() throws {
        scheduleTask?.cancel(); scheduleTask = nil
        let schedule = try store.analysisSchedule()
        try schedule.validate()
        guard schedule.enabled else { return }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(schedule.everySeconds)) }
                catch { return }
                guard !Task.isCancelled else { return }
                let end = Date()
                // Failure is available through status / Core's safe query, never logged with content.
                if let interval = try? schedule.interval(endingAt: end), interval.duration > 0 {
                    _ = try? await self?.analyze(in: interval)
                }
            }
        }
    }

    public func stopSchedule() { scheduleTask?.cancel(); scheduleTask = nil }

    private func assemble(_ record: CaptureRecordSummary, settings: CaptureSettings) throws -> ProviderObservation? {
        let allowed = settings.analysisSources
        var sources = Set<AnalysisSource>()
        var evidence: [RawEvidence] = []
        let application = allowed.contains(.application) && record.qualities.application == .available
            ? record.applicationBundleIdentifier : nil
        if application != nil { sources.insert(.application) }
        for reference in record.evidence where allowed.contains(reference.kind.analysisSource) {
            guard let raw = try store.rawEvidence(id: reference.id), raw.recordID == record.id else { throw AnalysisError.stale }
            evidence.append(raw); sources.insert(reference.kind.analysisSource)
        }
        guard !sources.isEmpty else { return nil }
        return ProviderObservation(recordID: record.id, capturedAt: record.capturedAt,
            applicationBundleIdentifier: application, evidence: evidence, sources: sources)
    }

    private func usableSources(_ record: CaptureRecordSummary, settings: CaptureSettings) -> Set<AnalysisSource> {
        var sources = Set(record.evidence.map { $0.kind.analysisSource }).intersection(settings.analysisSources)
        if settings.historyEnabled && record.qualities.application == .available && record.applicationBundleIdentifier != nil {
            sources.insert(.application)
        }
        return sources
    }

    private func submit(_ batch: [ProviderObservation], provider: any AnalysisProvider,
                        context: AnalysisContext, configuration: ProviderConfiguration) async throws -> Int {
        try Task.checkCancellation()
        try checkContext(context)
        let request = Task { try await provider.classify(batch) }
        activeRequest = request
        let store = self.store
        let contextWatcher = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard !Task.isCancelled else { return }
                if (try? store.analysisContext().revision) != context.revision { request.cancel(); return }
            }
        }
        defer { contextWatcher.cancel() }
        let values = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
        activeRequest = nil
        try Task.checkCancellation()
        try checkContext(context)
        guard !values.isEmpty else { throw AnalysisError.emptyResponse }
        guard values.count == batch.count, Set(values.map(\.recordID)) == Set(batch.map(\.recordID)),
              let providerID = context.selectedProviderID else { throw AnalysisError.invalidResponse }
        try store.saveAnalysis(values, providerID: providerID, providerVersion: configuration.version,
            sources: Dictionary(uniqueKeysWithValues: batch.map { ($0.recordID, $0.sources) }),
            evidenceIDs: Dictionary(uniqueKeysWithValues: batch.map { ($0.recordID, $0.evidence.map(\.id)) }),
            expectedRevision: context.revision, continuitySeconds: min(context.settings.normalized.intervalSeconds * 1.5, 5_400))
        return values.count
    }

    private func checkContext(_ expected: AnalysisContext) throws {
        guard try store.analysisContext().revision == expected.revision else { throw AnalysisError.stale }
    }
    private func updateStatus(phase: AnalysisRunStatus.Phase, processed: Int, error: AnalysisError? = nil) throws {
        status = AnalysisRunStatus(phase: phase, processedRecords: processed, error: error)
        try store.saveAnalysisRunStatus(status)
    }
    private static func safeError(_ error: any Error) -> AnalysisError {
        if let error = error as? AnalysisError { return error }
        if error is CancellationError { return .cancelled }
        if error is DayreedStoreError { return .storage }
        return .providerFailed
    }
}
