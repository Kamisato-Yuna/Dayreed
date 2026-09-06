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
    var recordVersions: [String: Int64] = [:]
    var isCorrectable = true
    var stateTitle = ""
}

enum ReportKind: String, Sendable { case daily, weekly }

struct ReviewReport: Equatable, Sendable {
    let id: String
    var markdown: String
    let updatedAt: Date
    var sources: [ReviewEvidence]
    var version: Int64?
    var isEdited = false
    var needsReview = false
}

struct ReviewQuery: Equatable, Sendable {
    var date: Date
    var kind: ReportKind?
    var interval: DateInterval {
        var calendar = kind == .weekly ? Calendar(identifier: .iso8601) : Calendar.current
        calendar.timeZone = .current
        return calendar.dateInterval(of: kind == .weekly ? .weekOfYear : .day, for: date)!
    }
}

struct ReviewSnapshot: Sendable {
    var events: [ReviewEvent] = []
    var report: ReviewReport?
    var candidates: [ReviewReportCandidate] = []
}

struct ReviewReportCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let markdown: String
    let createdAt: Date
}

struct ReviewCapabilities: Sendable {
    var read = false
    var saveReport = false
    var regenerate = false
    var correctEvent = false
    var openEvidence = false
    var configure = false
    var checkUpdates = false
    var generateReport = false
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
    case unavailable, failed, conflict, notConfigured, noEvidence, paused, sourcesDisabled, unsupportedImages, credentials, cancelled, invalidConfiguration
    var errorDescription: String? {
        switch self {
        case .notConfigured: "请先在设置中配置并选定分析 Provider。"
        case .noEvidence: "此时段没有可用记录，请选择其他日期或先采集记录。"
        case .paused: "采集已暂停或停止，分析不会发送内容。继续采集后可重试。"
        case .sourcesDisabled: "所有分析来源已关闭，旧记录仍可查看。"
        case .unsupportedImages: "选定的 Provider 不支持截图。可选择支持图片的模型，或只启用历史来源。"
        case .credentials: "Provider 凭据不可用，请在设置中检查 Keychain 凭据或选定的 CLI 登录目录。"
        case .cancelled: "操作已取消，原有报告保持不变。"
        case .invalidConfiguration: "Provider 配置无效，请检查 URL、模型、程序路径和认证方式。"
        case .unavailable: "服务尚未连接。请稍后重试。"
        case .failed: "操作未完成。原有内容已保留，请重试。"
        case .conflict: "内容已在其他位置更新。请保留当前草稿后重新载入。"
        }
    }
}
