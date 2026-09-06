import DayreedCore
import Foundation

public struct ActiveApplication: Equatable, Sendable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?

    public init(processIdentifier: Int32, bundleIdentifier: String?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct ScreenshotSample: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let pngData: Data?
    public let quality: CaptureQuality
    public init(pngData: Data? = nil, quality: CaptureQuality) {
        self.pngData = pngData
        self.quality = quality
    }
    public var description: String { "ScreenshotSample(\(quality.rawValue), content redacted)" }
    public var debugDescription: String { description }
}

public struct HistorySample: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let windowTitle: String?
    public let accessibilityText: String?
    public let windowTitleQuality: CaptureQuality
    public let accessibilityTextQuality: CaptureQuality

    public init(windowTitle: String? = nil, accessibilityText: String? = nil,
                windowTitleQuality: CaptureQuality = .disabled, accessibilityTextQuality: CaptureQuality = .disabled) {
        self.windowTitle = windowTitle
        self.accessibilityText = accessibilityText
        self.windowTitleQuality = windowTitleQuality
        self.accessibilityTextQuality = accessibilityTextQuality
    }
    public var description: String { "HistorySample(content redacted)" }
    public var debugDescription: String { description }
}

public enum CaptureEnvironmentEvent: Sendable {
    case applicationChanged
    case sessionInactive, sessionActive
    case sleeping, woke
    case displaySleeping, displayWoke
    case locked, unlocked
}

/// Injectable at the OS boundary: tests never have to query or request real system permissions.
@MainActor
public protocol CaptureEnvironment: AnyObject {
    func permissions() -> CapturePermissions
    func currentApplication() -> ActiveApplication?
    func isSessionActive() -> Bool
    func startMonitoring(_ handler: @escaping @MainActor @Sendable (CaptureEnvironmentEvent) -> Void)
    func stopMonitoring()
    func screenshot(excluding bundleIdentifiers: Set<String>) async -> ScreenshotSample
    func history(for application: ActiveApplication, windowTitle: Bool, accessibilityText: Bool) async -> HistorySample
    func requestScreenRecordingPermission()
    func requestAccessibilityPermission()
}
