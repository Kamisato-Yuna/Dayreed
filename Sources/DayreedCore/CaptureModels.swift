import Foundation

/// Creating settings never enables a source. The caller owns persisting user choices.
public struct CaptureSettings: Codable, Equatable, Sendable {
    public var screenshotsEnabled: Bool
    public var historyEnabled: Bool
    public var windowTitlesEnabled: Bool
    public var accessibilityTextEnabled: Bool
    public var excludedBundleIdentifiers: Set<String>
    public var intervalSeconds: TimeInterval
    public var retentionDays: Int

    public init(
        screenshotsEnabled: Bool = false,
        historyEnabled: Bool = false,
        windowTitlesEnabled: Bool = false,
        accessibilityTextEnabled: Bool = false,
        excludedBundleIdentifiers: Set<String> = [],
        intervalSeconds: TimeInterval = 60,
        retentionDays: Int = 30
    ) {
        self.screenshotsEnabled = screenshotsEnabled
        self.historyEnabled = historyEnabled
        self.windowTitlesEnabled = windowTitlesEnabled
        self.accessibilityTextEnabled = accessibilityTextEnabled
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.intervalSeconds = intervalSeconds
        self.retentionDays = retentionDays
    }

    public var hasEnabledSources: Bool { screenshotsEnabled || historyEnabled }

    public var normalized: Self {
        var value = self
        value.intervalSeconds = intervalSeconds.isFinite ? min(max(intervalSeconds, 5), 3_600) : 60
        value.retentionDays = min(max(retentionDays, 1), 3_650)
        return value
    }
}

/// Not granted intentionally does not claim the system can distinguish not-yet-asked from denied.
public enum CapturePermission: String, Codable, Sendable { case granted, notGranted }

public struct CapturePermissions: Codable, Equatable, Sendable {
    public var screenRecording: CapturePermission
    public var accessibility: CapturePermission

    public init(screenRecording: CapturePermission = .notGranted, accessibility: CapturePermission = .notGranted) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }
}

public enum CaptureQuality: String, Codable, Sendable {
    case disabled, available, empty, truncated, permissionRequired, unavailable, failed
}

public struct SourceQualities: Codable, Equatable, Sendable {
    public var screenshot: CaptureQuality
    public var application: CaptureQuality
    public var windowTitle: CaptureQuality
    public var accessibilityText: CaptureQuality

    public init(
        screenshot: CaptureQuality = .disabled,
        application: CaptureQuality = .disabled,
        windowTitle: CaptureQuality = .disabled,
        accessibilityText: CaptureQuality = .disabled
    ) {
        self.screenshot = screenshot
        self.application = application
        self.windowTitle = windowTitle
        self.accessibilityText = accessibilityText
    }
}

public enum CaptureTrigger: String, Codable, Sendable { case started, timer, applicationChanged, resumed, manual }
public enum EvidenceKind: String, Codable, Sendable { case screenshot, windowTitle, accessibilityText }

public struct EvidenceReference: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: EvidenceKind
    public let byteCount: Int

    public init(id: UUID, kind: EvidenceKind, byteCount: Int) {
        self.id = id
        self.kind = kind
        self.byteCount = byteCount
    }
}

/// Safe default query projection: no window title, accessibility text or image bytes.
public struct CaptureRecordSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let trigger: CaptureTrigger
    public let applicationBundleIdentifier: String?
    public let qualities: SourceQualities
    public let evidence: [EvidenceReference]
}

/// Ordinary timestamp + primary-key cursor, including records that share a timestamp.
public struct CaptureRecordCursor: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let id: UUID

    public init(capturedAt: Date, id: UUID) {
        self.capturedAt = capturedAt
        self.id = id
    }
}

public struct CaptureRecordPage: Codable, Equatable, Sendable {
    public let records: [CaptureRecordSummary]
    /// nil means this query has reached the end, not that a time range can never change later.
    public let nextCursor: CaptureRecordCursor?
}

/// Raw content is available only through an explicit local evidence read.
public struct RawEvidence: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let recordID: UUID
    public let kind: EvidenceKind
    public let mediaType: String
    public let data: Data
    public var description: String { "RawEvidence(\(kind.rawValue), content redacted)" }
    public var debugDescription: String { description }
}

public struct EvidenceInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let kind: EvidenceKind
    public let mediaType: String
    public let data: Data

    public init(kind: EvidenceKind, mediaType: String, data: Data) {
        self.kind = kind
        self.mediaType = mediaType
        self.data = data
    }

    public static func text(_ text: String, kind: EvidenceKind) -> Self {
        Self(kind: kind, mediaType: "text/plain; charset=utf-8", data: Data(text.utf8))
    }

    public var description: String { "EvidenceInput(\(kind.rawValue), content redacted)" }
    public var debugDescription: String { description }
}

public struct CaptureRecordInput: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let capturedAt: Date
    public let trigger: CaptureTrigger
    public let applicationBundleIdentifier: String?
    public let qualities: SourceQualities
    public let evidence: [EvidenceInput]

    public init(
        id: UUID = UUID(), capturedAt: Date, trigger: CaptureTrigger,
        applicationBundleIdentifier: String? = nil, qualities: SourceQualities,
        evidence: [EvidenceInput] = []
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.trigger = trigger
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.qualities = qualities
        self.evidence = evidence
    }

    public var description: String { "CaptureRecordInput(content redacted)" }
    public var debugDescription: String { description }
}

public enum DayreedDataDirectory {
    /// This only returns a location; it does not inspect any existing records.
    public static func defaultURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: false)
            .appendingPathComponent(ProductInfo.bundleIdentifier, isDirectory: true)
    }
}
