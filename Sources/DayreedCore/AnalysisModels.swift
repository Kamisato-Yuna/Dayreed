import Foundation

/// Stable, content-free errors suitable for App and Agent presentation.
public enum AnalysisError: String, Error, Codable, Sendable {
    case notConfigured, invalidConfiguration, paused, sourcesDisabled, busy, noEvidence
    case cancelled, timedOut, stale, conflict, notFound, invalidResponse, emptyResponse, refused
    case unsupportedImages, inputTooLarge, outputTooLarge, transport, providerFailed, credentials, processFailed, storage
}

public enum AnalysisSource: String, Codable, CaseIterable, Sendable {
    case application, screenshot, windowTitle, accessibilityText
}

public extension CaptureSettings {
    var analysisSources: Set<AnalysisSource> {
        var result = Set<AnalysisSource>()
        if screenshotsEnabled { result.insert(.screenshot) }
        if historyEnabled {
            result.insert(.application)
            if windowTitlesEnabled { result.insert(.windowTitle) }
            if accessibilityTextEnabled { result.insert(.accessibilityText) }
        }
        return result
    }
}

public extension EvidenceKind {
    var analysisSource: AnalysisSource {
        switch self {
        case .screenshot: .screenshot
        case .windowTitle: .windowTitle
        case .accessibilityText: .accessibilityText
        }
    }
}

/// Contains no key. Only an explicitly selected configuration can initiate analysis.
public struct ProviderConfiguration: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case openAICompatible, codexCLI, claudeCLI }
    public enum CLIAuthentication: String, Codable, Sendable { case dayreedAPIKey, existingLogin }
    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Complete chat completions URL (for example https://example.com/v1/chat/completions).
    public var endpoint: URL?
    public var model: String
    public var executableURL: URL?
    public var supportsImages: Bool
    public var timeoutSeconds: Double
    /// existingLogin is an explicit Settings choice, using only the CLI's selected auth directory.
    public var cliAuthentication: CLIAuthentication
    public var cliConfigurationDirectory: URL?
    public internal(set) var version: Int64 = 1

    public init(id: UUID = UUID(), name: String, kind: Kind, model: String,
                endpoint: URL? = nil, executableURL: URL? = nil,
                supportsImages: Bool = false, timeoutSeconds: Double = 90,
                cliAuthentication: CLIAuthentication = .dayreedAPIKey, cliConfigurationDirectory: URL? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.model = model
        self.endpoint = endpoint; self.executableURL = executableURL
        self.supportsImages = supportsImages; self.timeoutSeconds = timeoutSeconds
        self.cliAuthentication = cliAuthentication; self.cliConfigurationDirectory = cliConfigurationDirectory
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 200,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.utf8.count <= 200,
              !model.contains(where: { $0.isNewline || $0 == "\0" }),
              timeoutSeconds.isFinite, (1...600).contains(timeoutSeconds) else {
            throw AnalysisError.invalidConfiguration
        }
        switch kind {
        case .openAICompatible:
            guard let endpoint, let host = endpoint.host, !host.isEmpty,
                  endpoint.user == nil, endpoint.password == nil,
                  endpoint.query == nil, endpoint.fragment == nil,
                  endpoint.scheme == "https" || (endpoint.scheme == "http" &&
                    ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
                throw AnalysisError.invalidConfiguration
            }
        case .codexCLI, .claudeCLI:
            guard let executableURL, executableURL.isFileURL, executableURL.path.hasPrefix("/"),
                  !executableURL.path.contains("\0"), !(kind == .claudeCLI && supportsImages) else {
                throw AnalysisError.invalidConfiguration
            }
            if cliAuthentication == .existingLogin {
                guard let directory = cliConfigurationDirectory, directory.isFileURL,
                      directory.path.hasPrefix("/"), !directory.path.contains("\0") else {
                    throw AnalysisError.invalidConfiguration
                }
            }
        }
    }
}

public struct AnalysisRunStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, running, completed, failed, cancelled }
    public let phase: Phase
    public let processedRecords: Int
    public let error: AnalysisError?
    public let updatedAt: Date
    public init(phase: Phase = .idle, processedRecords: Int = 0, error: AnalysisError? = nil, updatedAt: Date = Date()) {
        self.phase = phase; self.processedRecords = processedRecords; self.error = error; self.updatedAt = updatedAt
    }
}

public struct AnalysisSchedule: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var everySeconds: Double
    public var lookbackSeconds: Double
    public var currentDayOnly: Bool
    public var timeZoneIdentifier: String
    public init(enabled: Bool = false, everySeconds: Double = 300, lookbackSeconds: Double = 86_400,
                currentDayOnly: Bool = true, timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.enabled = enabled; self.everySeconds = everySeconds; self.lookbackSeconds = lookbackSeconds
        self.currentDayOnly = currentDayOnly; self.timeZoneIdentifier = timeZoneIdentifier
    }
    public func validate() throws {
        guard everySeconds.isFinite, (5...86_400).contains(everySeconds),
              lookbackSeconds.isFinite, (5...31_536_000).contains(lookbackSeconds),
              TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw AnalysisError.invalidConfiguration
        }
    }

    public func interval(endingAt end: Date) throws -> DateInterval {
        try validate()
        guard end.timeIntervalSince1970.isFinite else { throw AnalysisError.invalidConfiguration }
        let start = currentDayOnly
            ? try ReportPeriod(kind: .daily, containing: end, timeZoneIdentifier: timeZoneIdentifier).interval.start
            : end.addingTimeInterval(-lookbackSeconds)
        return DateInterval(start: start, end: end)
    }

    private enum CodingKeys: CodingKey { case enabled, everySeconds, lookbackSeconds, currentDayOnly, timeZoneIdentifier }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        everySeconds = try values.decode(Double.self, forKey: .everySeconds)
        lookbackSeconds = try values.decode(Double.self, forKey: .lookbackSeconds)
        currentDayOnly = try values.decodeIfPresent(Bool.self, forKey: .currentDayOnly) ?? true
        timeZoneIdentifier = try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? TimeZone.current.identifier
    }
}

public struct AnalysisContext: Codable, Equatable, Sendable {
    public let revision: Int64
    public let settings: CaptureSettings
    public let paused: Bool
    public let selectedProviderID: UUID?
}

/// One classification per observation. The provider never supplies time bounds.
public struct ActivityClassification: Codable, Equatable, Sendable {
    public let recordID: UUID
    public let title: String
    public let summary: String
    public init(recordID: UUID, title: String, summary: String) {
        self.recordID = recordID; self.title = title; self.summary = summary
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 400, summary.utf8.count <= 4_000,
              !title.contains("\0"), !summary.contains("\0") else { throw AnalysisError.invalidResponse }
    }
}

public struct ActivityAnnotation: Codable, Equatable, Sendable {
    public let classification: ActivityClassification
    public let providerID: UUID
    public let providerVersion: Int64
    public let sources: Set<AnalysisSource>
    public let evidenceIDs: [UUID]
    public let version: Int64
    public let isCorrected: Bool
    public let continuitySeconds: Double
    public let analyzedAt: Date
}

/// Read-only projection. Raw evidence is deliberately absent from this type.
public struct ActivityObservation: Codable, Equatable, Sendable {
    public let record: CaptureRecordSummary
    public let annotation: ActivityAnnotation?
}

public struct ActivityObservationPage: Codable, Equatable, Sendable {
    public let observations: [ActivityObservation]
    public let nextCursor: CaptureRecordCursor?
}

public enum TimelineAnalysisState: String, Codable, Sendable { case pending, analyzed, corrected }

public struct TimelineEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let title: String?
    public let summary: String?
    public let state: TimelineAnalysisState
    public let sources: Set<AnalysisSource>
    public let recordIDs: [UUID]
    public let evidenceIDs: [UUID]
    public let versions: [UUID: Int64]
    /// Duration is supported by adjacent observations, not an assertion of uninterrupted attention.
    public var observedSeconds: Double { end.timeIntervalSince(start) }
}

public struct TimelineCursor: Codable, Equatable, Sendable {
    public let start: Date
    public let id: UUID
    public init(start: Date, id: UUID) { self.start = start; self.id = id }
}

public struct TimelinePage: Codable, Equatable, Sendable {
    public let events: [TimelineEvent]
    public let nextCursor: TimelineCursor?
}

public enum ReportKind: String, Codable, Sendable { case daily, weekly }

public struct ReportPeriod: Codable, Equatable, Sendable {
    public let kind: ReportKind
    public let interval: DateInterval
    public let timeZoneIdentifier: String

    /// ISO week starts Monday. Calendar arithmetic handles DST and year/week boundaries.
    public init(kind: ReportKind, containing date: Date, timeZoneIdentifier: String) throws {
        guard date.timeIntervalSince1970.isFinite, let zone = TimeZone(identifier: timeZoneIdentifier) else {
            throw AnalysisError.invalidConfiguration
        }
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = zone
        guard let interval = calendar.dateInterval(of: kind == .daily ? .day : .weekOfYear, for: date) else {
            throw AnalysisError.invalidConfiguration
        }
        self.kind = kind; self.interval = interval; self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public struct ReportDocument: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let period: ReportPeriod
    public let markdown: String
    public let version: Int64
    public let isEdited: Bool
    public let needsReview: Bool
    public let updatedAt: Date
    public let recordIDs: [UUID]
}

public struct ReportCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let period: ReportPeriod
    public let markdown: String
    public let reportID: UUID?
    public let expectedReportVersion: Int64?
    public let createdAt: Date
    public let recordIDs: [UUID]
}

public struct ReportPage: Codable, Equatable, Sendable {
    public let reports: [ReportDocument]
    public let nextCursor: TimelineCursor?
}

public struct DeletionSummary: Codable, Equatable, Sendable {
    public let recordCount: Int
    public let reportCount: Int
    public let candidateCount: Int
    public var isEmpty: Bool { recordCount == 0 && reportCount == 0 && candidateCount == 0 }
}
