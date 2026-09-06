import DayreedCore
import Foundation

/// Only Dayreed-owned settings. Credentials and capture payloads never enter UserDefaults.
@MainActor
struct CapturePreferences {
    static let key = "Dayreed.capture.settings"
    let defaults: UserDefaults

    func load() -> CaptureSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(CaptureSettings.self, from: data) else { return CaptureSettings() }
        return settings.normalized
    }

    func save(_ settings: CaptureSettings) throws {
        defaults.set(try JSONEncoder().encode(settings.normalized), forKey: Self.key)
    }
}

extension ReviewPreferences {
    init(capture: CaptureSettings) {
        self.init()
        sources = [
            SourcePreference(source: .screenshot, enabled: capture.screenshotsEnabled),
            SourcePreference(source: .application, enabled: capture.historyEnabled),
            SourcePreference(source: .windowTitle, enabled: capture.windowTitlesEnabled),
            SourcePreference(source: .accessibility, enabled: capture.accessibilityTextEnabled),
        ]
        intervalSeconds = Int(capture.intervalSeconds)
        retentionDays = capture.retentionDays
        excludedApplications = capture.excludedBundleIdentifiers.sorted().joined(separator: "\n")
        status = "来源设置只在本机保存。全部关闭后仍可回顾旧记录。"
    }

    var captureSettings: CaptureSettings {
        func enabled(_ source: EvidenceSource) -> Bool { sources.first { $0.source == source }?.enabled ?? false }
        return CaptureSettings(screenshotsEnabled: enabled(.screenshot), historyEnabled: enabled(.application),
                               windowTitlesEnabled: enabled(.windowTitle), accessibilityTextEnabled: enabled(.accessibility),
                               excludedBundleIdentifiers: Set(excludedApplications.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)),
                               intervalSeconds: Double(intervalSeconds), retentionDays: retentionDays).normalized
    }
}
