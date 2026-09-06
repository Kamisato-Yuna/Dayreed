import DayreedCore
import Foundation
import Testing
@testable import DayreedCapture

@MainActor private final class SyntheticEnvironment: CaptureEnvironment {
    var allowed = CapturePermissions(screenRecording: .granted, accessibility: .granted)
    var application: ActiveApplication? = ActiveApplication(processIdentifier: 100, bundleIdentifier: "test.editor")
    var active = true
    var screenshotCalls = 0
    var historyCalls = 0
    var permissionRequests = 0
    var permissionQueries = 0
    var exclusions: Set<String> = []
    var requestedTitle = false
    var requestedAX = false
    var handler: (@MainActor @Sendable (CaptureEnvironmentEvent) -> Void)?
    var screenshotContinuation: CheckedContinuation<ScreenshotSample, Never>?
    var suspendScreenshot = false
    var historyContinuation: CheckedContinuation<HistorySample, Never>?
    var suspendHistory = false
    var axSample = HistorySample(windowTitle: "SYNTHETIC_TITLE", accessibilityText: "SYNTHETIC_AX",
                                 windowTitleQuality: .available, accessibilityTextQuality: .available)

    func permissions() -> CapturePermissions { permissionQueries += 1; return allowed }
    func currentApplication() -> ActiveApplication? { application }
    func isSessionActive() -> Bool { active }
    func requestScreenRecordingPermission() { permissionRequests += 1 }
    func requestAccessibilityPermission() { permissionRequests += 1 }
    func startMonitoring(_ handler: @escaping @MainActor @Sendable (CaptureEnvironmentEvent) -> Void) { self.handler = handler }
    func stopMonitoring() { handler = nil }
    func screenshot(excluding bundleIdentifiers: Set<String>) async -> ScreenshotSample {
        screenshotCalls += 1
        exclusions = bundleIdentifiers
        if suspendScreenshot { return await withCheckedContinuation { screenshotContinuation = $0 } }
        return ScreenshotSample(pngData: Data([1, 2, 3]), quality: .available)
    }
    func history(for application: ActiveApplication, windowTitle: Bool, accessibilityText: Bool) async -> HistorySample {
        historyCalls += 1
        requestedTitle = windowTitle
        requestedAX = accessibilityText
        if suspendHistory { return await withCheckedContinuation { historyContinuation = $0 } }
        return axSample
    }
}

@MainActor private struct CaptureFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayreed-capture-test-\(UUID())")
    let store: DayreedStore
    let environment = SyntheticEnvironment()
    let now = Date()
    let coordinator: CaptureCoordinator
    init(settings: CaptureSettings = CaptureSettings()) throws {
        store = try DayreedStore(directory: directory)
        let now = now
        coordinator = CaptureCoordinator(store: store, settings: settings, environment: environment,
                                         automaticallySchedules: false, now: { now })
    }
    func records() throws -> [CaptureRecordSummary] {
        try store.records(in: DateInterval(start: now.addingTimeInterval(-1), duration: 2)).records
    }
    func cleanUp() { coordinator.stop(); try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Test func initializationAndAllOffNeverCollectOrPrompt() async throws {
    let fixture = try CaptureFixture()
    defer { fixture.cleanUp() }
    #expect(fixture.environment.permissionQueries == 0)
    #expect(fixture.environment.handler == nil)
    fixture.coordinator.start()
    await fixture.coordinator.captureNow()
    #expect(fixture.coordinator.state.mode == .disabled)
    #expect(fixture.environment.permissionRequests == 0)
    #expect(fixture.environment.screenshotCalls == 0)
    #expect(fixture.environment.historyCalls == 0)
    #expect(try fixture.records().isEmpty)
}

@MainActor @Test(arguments: [false, true], [false, true])
func fourSourceCombinations(screenshots: Bool, history: Bool) async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(screenshotsEnabled: screenshots, historyEnabled: history,
                                                              windowTitlesEnabled: true, accessibilityTextEnabled: true))
    defer { fixture.cleanUp() }
    fixture.coordinator.start()
    await fixture.coordinator.captureNow()
    #expect(fixture.environment.screenshotCalls == (screenshots ? 1 : 0))
    #expect(fixture.environment.historyCalls == (history ? 1 : 0))
    #expect(fixture.environment.permissionRequests == 0)
    let records = try fixture.records()
    #expect(records.count == (screenshots || history ? 1 : 0))
    if let record = records.first {
        #expect(record.evidence.count == (screenshots ? 1 : 0) + (history ? 2 : 0))
        #expect(record.applicationBundleIdentifier == (history ? "test.editor" : nil))
    }
}

@MainActor @Test(arguments: [false, true], [false, true])
func permissionsAreIndependent(screenGranted: Bool, axGranted: Bool) async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(screenshotsEnabled: true, historyEnabled: true,
                                                              windowTitlesEnabled: true, accessibilityTextEnabled: true))
    defer { fixture.cleanUp() }
    fixture.environment.allowed = CapturePermissions(screenRecording: screenGranted ? .granted : .notGranted,
                                                    accessibility: axGranted ? .granted : .notGranted)
    fixture.coordinator.start()
    await fixture.coordinator.captureNow()
    let record = try #require(try fixture.records().first)
    #expect(record.qualities.screenshot == (screenGranted ? .available : .permissionRequired))
    #expect(record.qualities.accessibilityText == (axGranted ? .available : .permissionRequired))
    #expect(record.qualities.application == .available)
    #expect(fixture.environment.screenshotCalls == (screenGranted ? 1 : 0))
    #expect(fixture.environment.historyCalls == (axGranted ? 1 : 0))
    #expect(fixture.environment.permissionRequests == 0)
}

@MainActor @Test(arguments: [false, true], [false, true])
func titleAndAXSwitchesAreIndependent(title: Bool, ax: Bool) async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(historyEnabled: true, windowTitlesEnabled: title,
                                                              accessibilityTextEnabled: ax))
    defer { fixture.cleanUp() }
    fixture.coordinator.start()
    await fixture.coordinator.captureNow()
    let record = try #require(try fixture.records().first)
    #expect(record.evidence.count == (title ? 1 : 0) + (ax ? 1 : 0))
    #expect(record.qualities.windowTitle == (title ? .available : .disabled))
    #expect(record.qualities.accessibilityText == (ax ? .available : .disabled))
    #expect(fixture.environment.historyCalls == (title || ax ? 1 : 0))
    #expect(fixture.environment.requestedTitle == title)
    #expect(fixture.environment.requestedAX == ax)
}

@MainActor @Test func emptyAXAndUnavailableWindowRemainVisible() async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(historyEnabled: true, windowTitlesEnabled: true,
                                                              accessibilityTextEnabled: true))
    defer { fixture.cleanUp() }
    fixture.environment.axSample = HistorySample(windowTitleQuality: .unavailable, accessibilityTextQuality: .empty)
    fixture.coordinator.start()
    await fixture.coordinator.captureNow()
    let record = try #require(try fixture.records().first)
    #expect(record.qualities.windowTitle == .unavailable)
    #expect(record.qualities.accessibilityText == .empty)
    #expect(record.evidence.isEmpty)
}

@MainActor @Test func pauseExclusionSleepAndLockAreIndependentOfResume() async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(screenshotsEnabled: true, historyEnabled: true,
                                                              excludedBundleIdentifiers: ["test.private"]))
    defer { fixture.cleanUp() }
    let coordinator = fixture.coordinator
    coordinator.start()
    coordinator.pause()
    await coordinator.captureNow()
    #expect(coordinator.state.mode == .paused)
    fixture.environment.handler?(.sleeping)
    coordinator.resume()
    await coordinator.captureNow()
    #expect(coordinator.state.mode == .suspended)
    fixture.environment.handler?(.locked)
    fixture.environment.handler?(.woke)
    fixture.environment.handler?(.displaySleeping)
    fixture.environment.handler?(.displayWoke)
    #expect(coordinator.state.mode == .suspended)
    fixture.environment.handler?(.unlocked)
    fixture.environment.application = ActiveApplication(processIdentifier: 101, bundleIdentifier: "test.private")
    fixture.environment.handler?(.applicationChanged)
    await coordinator.captureNow()
    #expect(coordinator.state.mode == .excluded)
    #expect(try fixture.records().isEmpty)
    fixture.environment.application = ActiveApplication(processIdentifier: 102, bundleIdentifier: "test.editor")
    fixture.environment.handler?(.applicationChanged)
    await coordinator.captureNow()
    #expect(coordinator.state.mode == .running)
    #expect(try fixture.records().count == 1)
    #expect(fixture.environment.exclusions == ["test.private"])
    coordinator.pause()
    fixture.environment.handler?(.sessionInactive)
    fixture.environment.handler?(.sessionActive)
    #expect(coordinator.state.mode == .paused)
    coordinator.stop()
    #expect(fixture.environment.handler == nil)
}

@MainActor @Test(arguments: ["pauseResume", "disable", "switch", "exclude", "sleepWake", "lockUnlock", "revoke", "stopStart", "session", "expired"])
func staleInflightScreenshotsAreDiscarded(change: String) async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(screenshotsEnabled: true, historyEnabled: true))
    defer { fixture.cleanUp() }
    let coordinator = fixture.coordinator
    fixture.environment.suspendScreenshot = true
    coordinator.start()
    let work = Task { await coordinator.captureNow() }
    for _ in 0..<1_000 where fixture.environment.screenshotContinuation == nil { await Task.yield() }
    let continuation = try #require(fixture.environment.screenshotContinuation)
    switch change {
    case "pauseResume": coordinator.pause(); coordinator.resume()
    case "disable": coordinator.updateSettings(CaptureSettings())
    case "switch":
        fixture.environment.application = ActiveApplication(processIdentifier: 101, bundleIdentifier: "test.other")
        fixture.environment.handler?(.applicationChanged)
    case "exclude":
        coordinator.updateSettings(CaptureSettings(screenshotsEnabled: true, excludedBundleIdentifiers: ["test.editor"]))
    case "sleepWake": fixture.environment.handler?(.sleeping); fixture.environment.handler?(.woke)
    case "lockUnlock": fixture.environment.handler?(.locked); fixture.environment.handler?(.unlocked)
    case "revoke": fixture.environment.allowed.screenRecording = .notGranted
    case "stopStart": coordinator.stop(); coordinator.start()
    case "expired": try await Task.sleep(for: .seconds(15.1))
    default: fixture.environment.active = false
    }
    continuation.resume(returning: ScreenshotSample(pngData: Data([1, 2, 3]), quality: .available))
    await work.value
    #expect(try fixture.records().isEmpty)
    #expect(!coordinator.state.isCapturing)
}

@MainActor @Test func concurrentSamplingCoalescesAndStopPreventsWrites() async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(screenshotsEnabled: true))
    defer { fixture.cleanUp() }
    fixture.environment.suspendScreenshot = true
    fixture.coordinator.start()
    let work = Task { await fixture.coordinator.captureNow() }
    for _ in 0..<1_000 where fixture.environment.screenshotContinuation == nil { await Task.yield() }
    let continuation = try #require(fixture.environment.screenshotContinuation)
    await fixture.coordinator.captureNow()
    await fixture.coordinator.captureNow()
    #expect(fixture.environment.screenshotCalls == 1)
    fixture.coordinator.stop()
    continuation.resume(returning: ScreenshotSample(pngData: Data([1]), quality: .available))
    await work.value
    #expect(try fixture.records().isEmpty)
}

@MainActor @Test func pausedInflightAXIsDiscardedBeforeScreenshotStarts() async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(screenshotsEnabled: true, historyEnabled: true,
                                                              accessibilityTextEnabled: true))
    defer { fixture.cleanUp() }
    fixture.environment.suspendHistory = true
    fixture.coordinator.start()
    let work = Task { await fixture.coordinator.captureNow() }
    for _ in 0..<1_000 where fixture.environment.historyContinuation == nil { await Task.yield() }
    let continuation = try #require(fixture.environment.historyContinuation)
    fixture.coordinator.pause()
    fixture.coordinator.resume()
    continuation.resume(returning: fixture.environment.axSample)
    await work.value
    #expect(fixture.environment.screenshotCalls == 0)
    #expect(try fixture.records().isEmpty)
}

@MainActor @Test func inactiveStartupAndUnknownExcludedAppNeverCollect() async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(screenshotsEnabled: true,
                                                              excludedBundleIdentifiers: ["test.private"]))
    defer { fixture.cleanUp() }
    fixture.environment.active = false
    fixture.coordinator.start()
    await fixture.coordinator.captureNow()
    #expect(fixture.coordinator.state.mode == .suspended)
    fixture.environment.active = true
    fixture.environment.handler?(.sessionActive)
    fixture.environment.application = nil
    await fixture.coordinator.captureNow()
    #expect(fixture.coordinator.state.mode == .excluded)
    #expect(fixture.environment.screenshotCalls == 0)
    #expect(try fixture.records().isEmpty)
}

@MainActor @Test func captureStorageFailureIsVisibleWithoutRawErrors() async throws {
    let fixture = try CaptureFixture(settings: CaptureSettings(historyEnabled: true))
    defer { fixture.cleanUp() }
    let readOnly = try DayreedStore(directory: fixture.directory, access: .readOnly)
    let coordinator = CaptureCoordinator(store: readOnly, settings: CaptureSettings(historyEnabled: true),
                                         environment: fixture.environment, automaticallySchedules: false)
    defer { coordinator.stop() }
    coordinator.start()
    await coordinator.captureNow()
    #expect(coordinator.state.storageFailed)
    #expect(coordinator.state.lastRecordID == nil)
    #expect(try fixture.records().isEmpty)
}

@MainActor @Test func periodicSchedulerAndApplicationEventUseSyntheticEnvironmentOnly() async throws {
    let fixture = try CaptureFixture()
    defer { fixture.cleanUp() }
    let coordinator = CaptureCoordinator(store: fixture.store,
                                         settings: CaptureSettings(screenshotsEnabled: true, intervalSeconds: 5),
                                         environment: fixture.environment)
    defer { coordinator.stop() }
    let start = Date()
    coordinator.start()
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while fixture.environment.screenshotCalls < 2, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(fixture.environment.screenshotCalls >= 2)
    fixture.environment.handler?(.applicationChanged)
    for _ in 0..<1_000 where fixture.environment.screenshotCalls < 3 { await Task.yield() }
    let page = try fixture.store.records(in: DateInterval(start: start, end: Date().addingTimeInterval(1)))
    #expect(page.records.contains { $0.trigger == .started })
    #expect(page.records.contains { $0.trigger == .timer })
    #expect(page.records.contains { $0.trigger == .applicationChanged })
    #expect(fixture.environment.permissionRequests == 0)
}
