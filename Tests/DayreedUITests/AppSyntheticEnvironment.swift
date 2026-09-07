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
