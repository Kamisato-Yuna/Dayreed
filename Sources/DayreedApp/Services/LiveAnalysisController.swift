import DayreedAnalysis
import DayreedCore
import Foundation
import Observation

@MainActor @Observable
final class LiveAnalysisController {
    private(set) var configurations: [ProviderConfiguration] = []
    private(set) var selectedID: UUID?
    private(set) var schedule = AnalysisSchedule()
    private(set) var status = AnalysisRunStatus()
    private(set) var isConfiguring = false
    private(set) var configurationFailure: String?
    private struct CaptureContext: Equatable { let settings: CaptureSettings; let paused: Bool }
    @ObservationIgnored private var context: CaptureContext?
    @ObservationIgnored private var contextTask: Task<Void, Error>?
    @ObservationIgnored let service: AnalysisService
    @ObservationIgnored private let providers: ProviderSettingsService
    @ObservationIgnored private let database: DayreedStore

    private init(database: DayreedStore, service: AnalysisService, credentials: any ProviderCredentialStore) {
        self.database = database; self.service = service
        providers = ProviderSettingsService(store: database, credentials: credentials)
    }

    static func make(database: DayreedStore, credentials: any ProviderCredentialStore, factory: AnalysisProviderFactory?) async throws -> LiveAnalysisController {
        let service = try await Task.detached { try AnalysisService(store: database, credentials: credentials, providerFactory: factory) }.value
        let controller = LiveAnalysisController(database: database, service: service, credentials: credentials)
        try await controller.reload()
        return controller
    }

    func reload() async throws {
        let database = database
        let values = try await Task.detached {
            (try database.providerConfigurations(), try database.analysisContext().selectedProviderID, try database.analysisSchedule())
        }.value
        configurations = values.0; selectedID = values.1; schedule = values.2
        await refreshStatus()
    }
    func refreshStatus() async { status = await service.status }
    func updateContext(settings: CaptureSettings, paused: Bool) async throws {
        let requested = CaptureContext(settings: settings, paused: paused)
        if context == requested { try await contextTask?.value; return }
        let previous = contextTask
        context = requested
        let service = service
        let task = Task {
            _ = try? await previous?.value
            try await service.updateCaptureContext(settings: settings, paused: paused)
        }
        contextTask = task
        do { try await task.value }
        catch { if context == requested { context = nil }; throw error }
    }
    func restoreSchedule() async throws { try await service.restoreSchedule() }
    func analyze(_ interval: DateInterval) async throws {
        guard !isConfiguring else { throw ReviewServiceError.failed }
        guard selectedID != nil else { throw ReviewServiceError.notConfigured }
        guard context?.settings.hasEnabledSources == true else { throw ReviewServiceError.sourcesDisabled }
        guard context?.paused == false else { throw ReviewServiceError.paused }
        do { status = try await service.analyze(in: interval, reanalyze: true) }
        catch { await refreshStatus(); throw LiveReviewMapping.error(error) }
    }
    func cancel() async throws { try await service.cancel(); await refreshStatus() }

    func save(_ configuration: ProviderConfiguration, key: String?) async throws {
        try configuration.validate()
        try await changeConfiguration {
            try $0.save(configuration)
            if let key { try $0.setAPIKey(key, for: configuration.id) }
        }
    }
    func select(_ id: UUID?) async throws { try await changeConfiguration { try $0.select(id: id) } }
    func remove(_ id: UUID) async throws { try await changeConfiguration { try $0.remove(id: id) } }

    private func changeConfiguration(_ operation: @escaping @Sendable (ProviderSettingsService) throws -> Void) async throws {
        guard !isConfiguring else { throw ReviewServiceError.failed }
        isConfiguring = true; configurationFailure = nil
        defer { isConfiguring = false }
        await service.stopSchedule()
        do {
            try await service.cancel()
            let providers = providers
            try await Task.detached { try operation(providers) }.value
            try await reload()
            try await service.restoreSchedule()
        } catch {
            // Keychain and SQLite do not share a transaction. Reload what actually persisted and
            // stop opt-in scheduling after a partial failure, so changed credentials are not used.
            var disabled = schedule; disabled.enabled = false
            try? await service.configureSchedule(disabled)
            try? await reload()
            configurationFailure = "配置操作未完全完成，自动分析已停止。请检查当前配置后重试。"
            throw LiveReviewMapping.error(error)
        }
    }

    func configureSchedule(enabled: Bool, everySeconds: Double) async throws {
        guard !isConfiguring, !enabled || selectedID != nil else { throw ReviewServiceError.notConfigured }
        let value = AnalysisSchedule(enabled: enabled, everySeconds: everySeconds, currentDayOnly: true, timeZoneIdentifier: TimeZone.current.identifier)
        do { try await service.configureSchedule(value); schedule = value }
        catch { throw LiveReviewMapping.error(error) }
    }

    /// Live configuration guidance belongs here, not in a cached record summary.
    var guidanceText: String {
        if isConfiguring { return "正在保存 Provider 设置…" }
        guard selectedID != nil else {
            return configurations.isEmpty
                ? "尚未配置 Provider。请在设置中添加并选定用于分析的配置。"
                : "Provider 已保存，但尚未选定。请在设置的“选定 Provider”中选择用于分析的配置。"
        }
        guard context?.settings.hasEnabledSources == true else {
            return "Provider 已选定；所有分析来源已关闭。请先在设置中启用并应用来源。"
        }
        guard context?.paused == false else {
            return "Provider 已选定；采集已暂停或停止，恢复采集后才能分析。"
        }
        if schedule.enabled {
            return "Provider 已选定；自动分析仅处理当天记录。可用“分析本日”处理当前浏览日期。"
        }
        return "Provider 已选定；自动分析未开启。点击“分析本日”开始，或在设置中开启自动分析。"
    }

    var statusText: String {
        switch status.phase {
        case .idle: "尚未分析"
        case .running: "正在分析，已处理 \(status.processedRecords) 条记录"
        case .completed: "上次分析完成，处理 \(status.processedRecords) 条记录"
        case .cancelled: "分析已取消；原有结果保留"
        case .failed:
            "分析未完成：" + (status.error.map { LiveReviewMapping.error($0).errorDescription ?? "请重试" } ?? "请重试")
        }
    }
}
