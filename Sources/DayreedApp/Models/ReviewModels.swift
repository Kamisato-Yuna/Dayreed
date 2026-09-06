import Foundation

enum EvidenceSource: String, CaseIterable, Identifiable, Sendable {
    case screenshot, application, windowTitle, accessibility
    var id: Self { self }
    var title: String {
        switch self {
        case .screenshot: "截图"
        case .application: "应用切换"
        case .windowTitle: "窗口标题"
        case .accessibility: "辅助功能文本"
        }
    }
    var symbol: String {
        switch self {
        case .screenshot: "photo"
        case .application: "app.badge"
        case .windowTitle: "macwindow"
        case .accessibility: "text.viewfinder"
        }
    }
}

struct ReviewEvidence: Identifiable, Equatable, Sendable {
    let id: String
    let source: EvidenceSource
    let capturedAt: Date
    /// A redacted display label; never the raw capture payload.
    let label: String
}

struct ReviewEvent: Identifiable, Equatable, Sendable {
    let id: String
    let start: Date
    let end: Date
    var title: String
    var summary: String
    let application: String
    var evidence: [ReviewEvidence]
}

enum ReportKind: String, Sendable { case daily, weekly }

struct ReviewReport: Equatable, Sendable {
    let id: String
    var markdown: String
    let updatedAt: Date
    var sources: [ReviewEvidence]
}

struct ReviewQuery: Equatable, Sendable {
    var date: Date
    var kind: ReportKind?
    var interval: DateInterval {
        let calendar = Calendar.current
        return calendar.dateInterval(of: kind == .weekly ? .weekOfYear : .day, for: date)!
    }
}

struct ReviewSnapshot: Sendable {
    var events: [ReviewEvent] = []
    var report: ReviewReport?
}

struct ReviewCapabilities: Sendable {
    var read = false
    var saveReport = false
    var regenerate = false
    var correctEvent = false
    var openEvidence = false
    var configure = false
    var checkUpdates = false
}

struct SourcePreference: Identifiable, Equatable, Sendable {
    let source: EvidenceSource
    var enabled = false
    var permission = "尚未检查"
    var id: EvidenceSource { source }
}

struct ProviderChoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
}

struct ReviewPreferences: Equatable, Sendable {
    var sources = EvidenceSource.allCases.map { SourcePreference(source: $0) }
    var providers: [ProviderChoice] = []
    var selectedProviderID: String?
    var agentEnabled = false
    var agentAllowsChanges = false
    var agentIncludesRawContent = false
    var intervalSeconds = 60
    var excludedApplications = ""
    var retentionDays = 30
    var status = "采集服务尚未连接。所有来源默认关闭。"
}

/// Errors shown to users are intentionally bounded. Backend errors may contain capture content or secrets.
enum ReviewServiceError: Error, LocalizedError {
    case unavailable, failed, conflict
    var errorDescription: String? {
        switch self {
        case .unavailable: "服务尚未连接。请稍后重试。"
        case .failed: "操作未完成。原有内容已保留，请重试。"
        case .conflict: "内容已在其他位置更新。请保留当前草稿后重新载入。"
        }
    }
}
