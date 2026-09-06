import DayreedCapture
import DayreedCore
import Foundation

@MainActor final class AppSyntheticEnvironment: CaptureEnvironment {
    var requests = 0
    var queries = 0
    var samples = 0
    var monitoring = false
    var active = true
    var handler: (@MainActor @Sendable (CaptureEnvironmentEvent) -> Void)?
    var pending: CheckedContinuation<ScreenshotSample, Never>?
    var delay = false
    func permissions() -> CapturePermissions { queries += 1; return CapturePermissions(screenRecording: .granted, accessibility: .granted) }
    func currentApplication() -> ActiveApplication? { ActiveApplication(processIdentifier: 42, bundleIdentifier: "test.synthetic") }
    func isSessionActive() -> Bool { active }
    func startMonitoring(_ handler: @escaping @MainActor @Sendable (CaptureEnvironmentEvent) -> Void) { self.handler = handler; monitoring = true }
    func stopMonitoring() { monitoring = false; handler = nil }
    func requestScreenRecordingPermission() { requests += 1 }
    func requestAccessibilityPermission() { requests += 1 }
    func screenshot(excluding bundleIdentifiers: Set<String>) async -> ScreenshotSample {
        samples += 1
        if delay { return await withCheckedContinuation { pending = $0 } }
        return ScreenshotSample(pngData: Data([1, 2, 3]), quality: .available)
    }
    func history(for application: ActiveApplication, windowTitle: Bool, accessibilityText: Bool) async -> HistorySample {
        samples += 1
        return HistorySample(windowTitle: windowTitle ? "SYNTHETIC_SECRET_TITLE" : nil,
                             accessibilityText: accessibilityText ? "SYNTHETIC_SECRET_AX" : nil,
                             windowTitleQuality: windowTitle ? .available : .disabled,
                             accessibilityTextQuality: accessibilityText ? .available : .disabled)
    }
}

@main struct LiveServiceChecks {
    static func expect(_ value: Bool) { precondition(value) }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayreed-app-check-\(UUID())")
        let suite = "Dayreed.synthetic.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let environment = AppSyntheticEnvironment()
        let service = LiveReviewService(defaults: defaults, directory: { directory }, environment: environment, automaticallySchedules: false)
        let database = try await service.prepare()
        var preferences = try await service.preferences()
        let empty = try await service.load(ReviewQuery(date: .now))
        expect(empty.events.isEmpty && preferences.sources.allSatisfy { !$0.enabled })
        expect(environment.requests == 0 && environment.queries == 0 && !environment.monitoring && environment.samples == 0)
        preferences.sources[1].enabled = true
        preferences.sources[2].enabled = true
        preferences.sources[3].enabled = false
        preferences.intervalSeconds = 15
        preferences.excludedApplications = "test.excluded\ntest.password-manager"
        _ = try await service.save(preferences: preferences)
        let capture = service.coordinator!
        await capture.captureNow()
        expect(capture.settings.historyEnabled && !capture.settings.screenshotsEnabled && !capture.settings.accessibilityTextEnabled)
        let records = try await service.records(in: ReviewQuery(date: .now).interval)
        expect(records.count == 1 && records[0].evidence.count == 1 && records[0].evidence[0].kind == .windowTitle)
        let snapshot = try await service.load(ReviewQuery(date: .now))
        expect(!snapshot.events[0].summary.contains("SECRET") && !snapshot.events[0].evidence[0].label.contains("SECRET"))
        service.control(.pause)
        await capture.captureNow()
        expect(try database.records(in: ReviewQuery(date: .now).interval).records.count == 1)
        service.control(.resume)
        environment.active = false
        environment.handler?(.locked)
        expect(capture.state.mode == .suspended)
        await capture.captureNow()
        expect(try database.records(in: ReviewQuery(date: .now).interval).records.count == 1)
        environment.active = true
        environment.handler?(.unlocked)
        service.control(.screenPermission)
        service.control(.accessibilityPermission)
        expect(environment.requests == 2)
        preferences.sources[0].enabled = true
        preferences.sources[1].enabled = false
        _ = try await service.save(preferences: preferences)
        environment.delay = true
        let sample = Task { await capture.captureNow() }
        while environment.pending == nil { await Task.yield() }
        service.control(.pause)
        environment.pending!.resume(returning: ScreenshotSample(pngData: Data([1]), quality: .available))
        await sample.value
        expect(try database.records(in: ReviewQuery(date: .now).interval).records.count == 1)
        preferences.sources = preferences.sources.map { SourcePreference(source: $0.source) }
        _ = try await service.save(preferences: preferences)
        expect(try await service.load(ReviewQuery(date: .now)).events.count == 1)
        let saved = CapturePreferences(defaults: defaults).load()
        expect(!saved.hasEnabledSources && saved.intervalSeconds == 15 && saved.excludedBundleIdentifiers.count == 2)
        // Exercise pagination beyond one 500-record page, never using personal records.
        let now = Date.now
        for _ in 0..<505 { _ = try database.append(CaptureRecordInput(capturedAt: now, trigger: .manual, qualities: SourceQualities())) }
        expect(try await service.load(ReviewQuery(date: now)).events.count == 506)
        let deletion = try await service.prepareDeletion(date: now)
        expect(deletion.count == 506 && capture.state.mode == .paused)
        try await service.delete(deletion)
        expect(try await service.load(ReviewQuery(date: now)).events.isEmpty && service.revision == 1)
        expect(try database.rawEvidence(id: records[0].evidence[0].id) == nil)
        service.control(.stop)
        preferences.sources[1].enabled = true
        try CapturePreferences(defaults: defaults).save(preferences.captureSettings)
        let reopenedEnvironment = AppSyntheticEnvironment()
        let reopened = LiveReviewService(defaults: defaults, directory: { directory }, environment: reopenedEnvironment, automaticallySchedules: false)
        _ = try await reopened.prepare()
        expect(reopenedEnvironment.monitoring && reopenedEnvironment.requests == 0)
        reopened.control(.stop)
        print("PASS: all-off startup has no permission queries, prompts or sampling; independent sources; persistence; redacted lists; pause rejects late result; old records stay readable; all pages load; deletion counts, cascades and refreshes; saved sources resume on next launch without prompts")
    }
}
