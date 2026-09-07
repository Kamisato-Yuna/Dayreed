@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import DayreedCore
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
public final class MacCaptureEnvironment: CaptureEnvironment {
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    public init() {}

    deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    public func permissions() -> CapturePermissions {
        CapturePermissions(screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notGranted,
                           accessibility: AXIsProcessTrusted() ? .granted : .notGranted)
    }

    public func requestScreenRecordingPermission() { _ = CGRequestScreenCaptureAccess() }

    public func requestAccessibilityPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    public func currentApplication() -> ActiveApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return ActiveApplication(processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
    }

    public func isSessionActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool else { return false }
        // Public session dictionary; the lock notification below is the primary event source.
        let screenLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        return onConsole && !screenLocked
    }

    public func startMonitoring(_ handler: @escaping @MainActor @Sendable (CaptureEnvironmentEvent) -> Void) {
        stopMonitoring()
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, CaptureEnvironmentEvent)] = [
            (NSWorkspace.didActivateApplicationNotification, .applicationChanged),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
            (NSWorkspace.willSleepNotification, .sleeping),
            (NSWorkspace.didWakeNotification, .woke),
            (NSWorkspace.screensDidSleepNotification, .displaySleeping),
            (NSWorkspace.screensDidWakeNotification, .displayWoke),
        ]
        for (name, event) in events {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler(event) }
            })
        }
        for (name, event) in [("com.apple.screenIsLocked", CaptureEnvironmentEvent.locked),
                              ("com.apple.screenIsUnlocked", .unlocked)] {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { handler(event) } })
        }
    }

    public func stopMonitoring() {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
    }

    /// Captures the main display with excluded applications removed, up to 2560 pixels per edge.
    /// No ScreenCaptureKit content API is called until preflight permission is already granted.
    public func screenshot(excluding bundleIdentifiers: Set<String>) async -> ScreenshotSample {
        guard CGPreflightScreenCaptureAccess() else { return ScreenshotSample(quality: .permissionRequired) }
        guard isSessionActive() else { return ScreenshotSample(quality: .unavailable) }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard !Task.isCancelled, isSessionActive(), CGPreflightScreenCaptureAccess() else {
                return ScreenshotSample(quality: .unavailable)
            }
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                return ScreenshotSample(quality: .unavailable)
            }
            let filter: SCContentFilter
            if bundleIdentifiers.isEmpty {
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            } else {
                // Excluding only currently running processes would miss an excluded app that
                // launches between enumeration and capture. Include only known allowed apps.
                // This filter also omits the desktop background and Dock by system design.
                let included = content.applications.filter { !bundleIdentifiers.contains($0.bundleIdentifier) }
                filter = SCContentFilter(display: display, including: included, exceptingWindows: [])
            }
            let configuration = SCStreamConfiguration()
            let scale = min(1, 2_560 / Double(max(display.width, display.height)))
            configuration.width = max(1, Int(Double(display.width) * scale))
            configuration.height = max(1, Int(Double(display.height) * scale))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsDisplay = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard !Task.isCancelled, isSessionActive(), CGPreflightScreenCaptureAccess() else {
                return ScreenshotSample(quality: .unavailable)
            }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
                return ScreenshotSample(quality: .failed)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination), bytes.length <= 32 * 1_024 * 1_024 else {
                return ScreenshotSample(quality: .failed)
            }
            return ScreenshotSample(pngData: bytes as Data, quality: .available)
        } catch {
            return ScreenshotSample(quality: CGPreflightScreenCaptureAccess() ? .failed : .permissionRequired)
        }
    }

    public func history(for application: ActiveApplication, windowTitle: Bool, accessibilityText: Bool) async -> HistorySample {
        guard isSessionActive() else {
            return HistorySample(windowTitleQuality: windowTitle ? .unavailable : .disabled,
                                 accessibilityTextQuality: accessibilityText ? .unavailable : .disabled)
        }
        return await Task.detached(priority: .utility) {
            AccessibilityReader.read(processIdentifier: application.processIdentifier,
                                     windowTitle: windowTitle, accessibilityText: accessibilityText)
        }.value
    }
}
