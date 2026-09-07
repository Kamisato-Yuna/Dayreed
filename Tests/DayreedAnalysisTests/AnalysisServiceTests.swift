import DayreedCore
import Foundation
import Testing
@testable import DayreedAnalysis

struct AnalysisFixture {
    let directory: URL
    let store: DayreedStore
    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Dayreed-analysis-test-\(UUID())")
        store = try DayreedStore(directory: directory)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    @discardableResult
    func append(_ offset: Double, id: UUID = UUID(), images: Bool = false,
                bundle: String = "test.synthetic", date: Date? = nil) throws -> CaptureRecordSummary {
        var evidence: [EvidenceInput] = [.text("SYNTHETIC_WINDOW_SECRET", kind: .windowTitle),
                                         .text("SYNTHETIC_AX_SECRET", kind: .accessibilityText)]
        if images { evidence.append(EvidenceInput(kind: .screenshot, mediaType: "image/png", data: Data([1, 2, 3]))) }
        return try store.append(CaptureRecordInput(id: id, capturedAt: date ?? origin.addingTimeInterval(offset), trigger: .timer,
            applicationBundleIdentifier: bundle, qualities: SourceQualities(screenshot: images ? .available : .disabled,
                application: .available, windowTitle: .available, accessibilityText: .available), evidence: evidence))
    }
    func service(provider: any AnalysisProvider, settings: CaptureSettings = CaptureSettings(historyEnabled: true),
                 pageSize: Int = 3, batchSize: Int = 2) async throws -> AnalysisService {
        let config = ProviderConfiguration(name: "Synthetic", kind: .openAICompatible, model: "synthetic",
            endpoint: URL(string: "http://127.0.0.1/v1/chat/completions"))
        try store.saveProviderConfiguration(config); try store.selectProvider(id: config.id)
        let service = try AnalysisService(store: store, pageSize: pageSize, batchSize: batchSize, providerFactory: { _ in provider })
        try await service.updateCaptureContext(settings: settings, paused: false)
        return service
    }
    var interval: DateInterval { DateInterval(start: origin, duration: 3_600) }
}

actor RecordingProvider: AnalysisProvider {
    var observations: [ProviderObservation] = []
    var calls = 0
    let uniqueTitles: Bool
    let failure: AnalysisError?
    let empty: Bool
    init(uniqueTitles: Bool = false, failure: AnalysisError? = nil, empty: Bool = false) {
        self.uniqueTitles = uniqueTitles; self.failure = failure; self.empty = empty
    }
    func classify(_ values: [ProviderObservation]) async throws -> [ActivityClassification] {
        calls += 1; observations += values
        if let failure { throw failure }
        if empty { return [] }
        return values.map { ActivityClassification(recordID: $0.recordID,
            title: uniqueTitles ? $0.recordID.uuidString : "资料整理", summary: "整理参考资料") }
    }
}

actor SuspendedProvider: AnalysisProvider {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false
    private(set) var calls = 0
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
    func classify(_ values: [ProviderObservation]) async throws -> [ActivityClassification] {
        calls += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation; started = true
            startedWaiters.forEach { $0.resume() }; startedWaiters = []
        }
        // Intentionally ignores cancellation to exercise late successful callbacks.
        return values.map { ActivityClassification(recordID: $0.recordID, title: "晚到", summary: "合成响应") }
    }
}

@Test func initialDefaultsDoNotSelectProviderOrStartAnalysis() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let service = try AnalysisService(store: fixture.store)
    #expect(try fixture.store.providerConfigurations().isEmpty)
    #expect(try fixture.store.analysisContext().selectedProviderID == nil)
    #expect(try fixture.store.analysisSchedule().enabled == false)
    await #expect(throws: AnalysisError.paused) { try await service.analyze(in: fixture.interval) }
    try await service.updateCaptureContext(settings: CaptureSettings(historyEnabled: true), paused: false)
    await #expect(throws: AnalysisError.notConfigured) { try await service.analyze(in: fixture.interval) }
    #expect(try fixture.store.analysisRunStatus().phase == .failed)
}

@Test func sourcesAreFilteredBeforeProviderAndHistoryNeedsNoImageCapability() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let record = try fixture.append(0, images: true)
    try fixture.append(60, bundle: "test.excluded")
    let provider = RecordingProvider()
    let service = try await fixture.service(provider: provider,
        settings: CaptureSettings(historyEnabled: true, excludedBundleIdentifiers: ["test.excluded"]))
    try await service.analyze(in: fixture.interval)
    let first = try #require(await provider.observations.first)
    #expect(await provider.observations.count == 1)
    #expect(first.applicationBundleIdentifier == "test.synthetic")
    #expect(first.evidence.isEmpty)
    #expect(first.sources == [.application])
    try await service.updateCaptureContext(settings: CaptureSettings(historyEnabled: true, accessibilityTextEnabled: true,
        excludedBundleIdentifiers: ["test.excluded"]), paused: false)
    try await service.analyze(in: fixture.interval)
    let latest = try #require(await provider.observations.last)
    #expect(latest.sources == [.application, .accessibilityText])
    #expect(latest.evidence.map(\.kind) == [.accessibilityText])
    #expect(try fixture.store.activityAnnotation(recordID: record.id)?.version == 2)
    #expect(!String(reflecting: latest).contains("SYNTHETIC_AX_SECRET"))
}

@Test func paginatedInputCoversEqualTimestampsAndFinalShortBatch() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    var expected = Set<UUID>()
    for index in 0..<37 { expected.insert(try fixture.append(Double(index / 3)).id) }
    let provider = RecordingProvider(uniqueTitles: true)
    let service = try await fixture.service(provider: provider, pageSize: 4, batchSize: 3)
    let result = try await service.analyze(in: fixture.interval)
    #expect(result.processedRecords == 37)
    #expect(await provider.calls == 13)
    #expect(Set(await provider.observations.map(\.recordID)) == expected)
    var cursor: TimelineCursor?
    var found: [UUID] = []
    repeat {
        let page = try DayreedQueryService(store: fixture.store).timeline(in: fixture.interval, limit: 5, after: cursor)
        found += page.events.flatMap(\.recordIDs); cursor = page.nextCursor
    } while cursor != nil
    #expect(found.count == 37)
    #expect(Set(found) == expected)
    #expect(try await service.analyze(in: fixture.interval).processedRecords == 0)
    #expect(await provider.calls == 13)
}

@Test func dualSourcesFormOneUnionAndKeepShortTailAndIsolatedPoint() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    for time in [0.0, 60, 70, 300] { try fixture.append(time, images: true) }
    let service = try await fixture.service(provider: RecordingProvider(),
        settings: CaptureSettings(screenshotsEnabled: true, historyEnabled: true))
    try await service.analyze(in: fixture.interval)
    let events = try fixture.store.timeline(in: fixture.interval).events
    #expect(events.count == 2)
    #expect(events[0].recordIDs.count == 3)
    #expect(events[0].sources == [.application, .screenshot])
    #expect(events[0].observedSeconds == 70)
    #expect(events[1].observedSeconds == 0)
    #expect(events[1].recordIDs.count == 1)
    #expect(events.reduce(0) { $0 + $1.observedSeconds } == 70)
    #expect(events[0].end < events[1].start)
    let projection = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
    #expect(!projection.contains("SYNTHETIC_WINDOW_SECRET"))
    #expect(!projection.contains("SYNTHETIC_AX_SECRET"))
}

@Test(arguments: [AnalysisError.providerFailed, .emptyResponse, .refused, .timedOut, .cancelled])
func failuresNeverCommitSuccess(_ failure: AnalysisError) async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let record = try fixture.append(0)
    let service = try await fixture.service(provider: RecordingProvider(failure: failure))
    await #expect(throws: failure) { try await service.analyze(in: fixture.interval) }
    #expect(try fixture.store.activityAnnotation(recordID: record.id) == nil)
    #expect(try fixture.store.analysisRunStatus().phase != .completed)
    #expect(try fixture.store.analysisRunStatus().error == failure)
}

@Test func emptyInjectedResponseIsNotSuccess() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    try fixture.append(0)
    let service = try await fixture.service(provider: RecordingProvider(empty: true))
    await #expect(throws: AnalysisError.emptyResponse) { try await service.analyze(in: fixture.interval) }
}

@Test(arguments: ["pause", "disable", "delete", "cancel"])
func staleCallbacksAreRejected(_ action: String) async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let record = try fixture.append(0)
    let provider = SuspendedProvider()
    let service = try await fixture.service(provider: provider)
    let task = Task { try await service.analyze(in: fixture.interval) }
    await provider.waitUntilStarted()
    switch action {
    case "pause": try await service.updateCaptureContext(settings: CaptureSettings(historyEnabled: true), paused: true)
    case "disable": try await service.updateCaptureContext(settings: CaptureSettings(), paused: false)
    case "delete": try fixture.store.deleteRecords(in: fixture.interval)
    default: try await service.cancel()
    }
    await provider.release()
    await #expect(throws: AnalysisError.stale) { try await task.value }
    #expect(try fixture.store.activityAnnotation(recordID: record.id) == nil)
    #expect(try fixture.store.analysisRunStatus().phase != .completed)
}

@Test func configurationAndSchedulePersistWithoutRunningAutomatically() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let provider = RecordingProvider()
    let service = try await fixture.service(provider: provider)
    let schedule = AnalysisSchedule(enabled: true, everySeconds: 600, lookbackSeconds: 1_200)
    try await service.configureSchedule(schedule)
    await service.stopSchedule()
    let reopened = try DayreedStore(directory: fixture.directory, access: .readOnly)
    #expect(try reopened.providerConfigurations().count == 1)
    #expect(try reopened.analysisSchedule() == schedule)
    #expect(await provider.calls == 0)
    #expect(throws: DayreedStoreError.readOnly) { try reopened.saveAnalysisSchedule(AnalysisSchedule()) }
}

@Test(.timeLimit(.minutes(1)))
func scheduledAnalysisDoesNotDuplicateRequestsAndPausedSourcesNeverRequest() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    try fixture.append(0, date: Date())
    let provider = RecordingProvider()
    let service = try await fixture.service(provider: provider)
    let schedule = AnalysisSchedule(enabled: true, everySeconds: 5, lookbackSeconds: 60)
    try await service.configureSchedule(schedule)
    try await service.configureSchedule(schedule)
    try await Task.sleep(for: .milliseconds(5_500))
    #expect(await provider.calls == 1)
    try await Task.sleep(for: .milliseconds(5_200))
    #expect(await provider.calls == 1)
    try await service.updateCaptureContext(settings: CaptureSettings(historyEnabled: true), paused: true)
    try fixture.append(1, date: Date())
    try await Task.sleep(for: .milliseconds(5_200))
    #expect(await provider.calls == 1)
    try await service.configureSchedule(AnalysisSchedule())
    #expect(try fixture.store.analysisSchedule().enabled == false)
}

@Test(.timeLimit(.minutes(1)))
func stoppingScheduleCancelsItsInFlightRunAndRejectsLateOutput() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let record = try fixture.append(0, date: Date())
    let provider = SuspendedProvider()
    let service = try await fixture.service(provider: provider)
    try await service.configureSchedule(AnalysisSchedule(enabled: true, everySeconds: 5, lookbackSeconds: 60))
    await provider.waitUntilStarted()
    try await service.configureSchedule(AnalysisSchedule())
    await provider.release()
    try await Task.sleep(for: .milliseconds(100))
    #expect(await provider.calls == 1)
    #expect(try fixture.store.activityAnnotation(recordID: record.id) == nil)
    #expect(try fixture.store.analysisRunStatus().phase == .cancelled)
}

actor CancellationAwareProvider: AnalysisProvider {
    private var waiter: CheckedContinuation<Void, Never>?
    private var started = false
    private(set) var wasCancelled = false
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func classify(_ values: [ProviderObservation]) async throws -> [ActivityClassification] {
        started = true; waiter?.resume(); waiter = nil
        do { try await Task.sleep(for: .seconds(20)) }
        catch { wasCancelled = true; throw AnalysisError.cancelled }
        return []
    }
}

@Test(.timeLimit(.minutes(1)))
func changingProviderSettingsCancelsAnInFlightRequestWithoutWaitingForResponse() async throws {
    let fixture = try AnalysisFixture(); defer { fixture.cleanup() }
    let record = try fixture.append(0)
    let provider = CancellationAwareProvider()
    let service = try await fixture.service(provider: provider)
    let task = Task { try await service.analyze(in: fixture.interval) }
    await provider.waitUntilStarted()
    try ProviderSettingsService(store: fixture.store).select(id: nil)
    await #expect(throws: AnalysisError.cancelled) { try await task.value }
    #expect(await provider.wasCancelled)
    #expect(try fixture.store.activityAnnotation(recordID: record.id) == nil)
}
