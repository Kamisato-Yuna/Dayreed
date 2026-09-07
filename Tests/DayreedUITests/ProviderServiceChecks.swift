import DayreedAnalysis
import DayreedCore
import Foundation

extension LiveServiceChecks {
    @MainActor static func checkProviders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayreed-provider-ui-\(UUID())")
        let suite = "Dayreed.ProviderUI.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let provider = AppSyntheticProvider()
        let credentials = AppMemoryCredentials()
        let environment = AppSyntheticEnvironment()
        let service = LiveReviewService(defaults: defaults, directory: { directory }, environment: environment, automaticallySchedules: false,
            credentials: credentials, providerFactory: { _ in provider })
        let database = try await service.prepare()
        let analysis = service.analysis!
        expect(analysis.selectedID == nil && !analysis.schedule.enabled && credentials.readCount == 0)
        expect(analysis.guidanceText.contains("尚未配置 Provider"))
        var draft = ProviderDraft()
        draft.name = "合成配置"; draft.model = "synthetic"; draft.endpoint = "http://127.0.0.1/v1/chat/completions"
        let configuration = try draft.configuration()
        try await analysis.save(configuration, key: "TEST_ONLY_KEY")
        expect(analysis.configurations.count == 1 && analysis.selectedID == nil)
        expect(analysis.guidanceText.contains("已保存，但尚未选定"))
        expect(!service.capabilities.regenerate && credentials.readCount == 0)
        try await analysis.select(configuration.id)
        expect(service.capabilities.regenerate)
        expect(analysis.guidanceText.contains("所有分析来源已关闭"))
        var preferences = try await service.preferences()
        preferences.sources[1].enabled = true
        _ = try await service.save(preferences: preferences)
        expect(try !database.analysisContext().paused)
        expect(analysis.guidanceText.contains("自动分析未开启"))
        // Editing the selected configuration must preserve selection and live guidance.
        try await analysis.save(configuration, key: nil)
        expect(analysis.selectedID == configuration.id && !analysis.guidanceText.contains("尚未选定"))
        try await analysis.reload()
        expect(analysis.selectedID == configuration.id && service.capabilities.regenerate)
        expect(await provider.calls == 0 && credentials.readCount == 0)
        let query = ReviewQuery(date: .now)
        let day = query.interval.start
        // Scheduling ends at now; fixed 01:00/02:00 fixtures are future records in early-morning runs.
        let elapsedToday = query.date.timeIntervalSince(day)
        func append(_ date: Date) throws -> UUID {
            try database.append(CaptureRecordInput(capturedAt: date, trigger: .timer, applicationBundleIdentifier: "test.synthetic",
                qualities: SourceQualities(application: .available),
                evidence: [.text("SYNTHETIC_RAW_NOT_SELECTED", kind: .windowTitle), .text("SYNTHETIC_AX_NOT_SELECTED", kind: .accessibilityText)])).id
        }
        let first = try append(day.addingTimeInterval(elapsedToday / 3))
        let pending = try await service.load(query)
        expect(pending.events.first?.summary.contains("尚无分析摘要") == true)
        expect(pending.events.allSatisfy { !$0.summary.contains("选定 Provider") })
        // Reproduce the observed persisted invalidResponse without network or personal records.
        await provider.setFailure(.invalidResponse)
        do { _ = try await service.regenerate(query); preconditionFailure("invalid result accepted") }
        catch { expect(error as? ReviewServiceError == .invalidResponse) }
        expect(analysis.status.phase == .failed && analysis.status.error == .invalidResponse)
        expect(analysis.statusText.contains("不符合分析格式") && !analysis.statusText.contains("配置并选定"))
        expect(try database.activityAnnotation(recordID: first) == nil)
        let restored = try await LiveAnalysisController.make(database: database, credentials: credentials, factory: { _ in provider })
        expect(restored.selectedID == configuration.id && restored.statusText.contains("不符合分析格式"))
        await provider.setFailure(nil)
        var snapshot = try await service.regenerate(query)
        expect(snapshot.events.first?.title == "合成整理活动")
        let sources = await provider.lastSources
        let kinds = await provider.lastEvidenceKinds
        expect(sources == [.application] && kinds.isEmpty)
        expect(credentials.readCount == 0)
        expect(!(String(data: defaults.data(forKey: CapturePreferences.key)!, encoding: .utf8)!).contains("TEST_ONLY_KEY"))

        // Repeated state observations (last record/quality changes) must not cancel an unchanged context.
        await provider.setDelayed(true)
        let unchanged = Task { try await service.regenerate(query) }
        try await eventually { await provider.pending != nil }
        await service.coordinator!.captureNow()
        for _ in 0..<50 { await Task.yield() }
        await provider.complete()
        snapshot = try await unchanged.value
        expect(snapshot.events.contains { $0.title == "合成整理活动" })

        let lateID = try append(day.addingTimeInterval(elapsedToday * 2 / 3))
        let late = Task { try await service.regenerate(query) }
        try await eventually { await provider.pending != nil }
        try await service.control(.pause)
        expect(analysis.guidanceText.contains("暂停或停止"))
        await provider.complete()
        do { _ = try await late.value; preconditionFailure("paused late analysis committed") } catch { }
        expect(try database.activityAnnotation(recordID: lateID) == nil)
        expect(try database.analysisContext().paused)
        try await service.control(.resume)
        let closing = Task { try await service.regenerate(query) }
        try await eventually { await provider.pending != nil }
        preferences.sources[1].enabled = false
        _ = try await service.save(preferences: preferences)
        await provider.complete()
        do { _ = try await closing.value; preconditionFailure("closed source late analysis committed") } catch { }
        expect(try database.activityAnnotation(recordID: lateID) == nil)
        let beforeDisabled = await provider.calls
        do { _ = try await service.regenerate(query); preconditionFailure("disabled sources analyzed") }
        catch { expect(error as? ReviewServiceError == .sourcesDisabled) }
        expect(await provider.calls == beforeDisabled)

        // Explicit automatic scheduling handles only current-day unprocessed rows, without reports.
        await provider.setDelayed(false)
        preferences.sources[1].enabled = true
        _ = try await service.save(preferences: preferences)
        let yesterday = try append(day.addingTimeInterval(-3600))
        try await analysis.configureSchedule(enabled: true, everySeconds: 5)
        expect(analysis.guidanceText.contains("自动分析仅处理当天记录"))
        try await eventually(seconds: 8) { (try? database.activityAnnotation(recordID: lateID)) != nil }
        expect(try database.activityAnnotation(recordID: yesterday) == nil)
        expect(try database.report(for: LiveReviewMapping.period(ReviewQuery(date: .now, kind: .daily))) == nil)
        expect(try database.reportCandidates(for: LiveReviewMapping.period(ReviewQuery(date: .now, kind: .daily))).isEmpty)
        let countBeforePause = await provider.calls
        try await service.control(.pause)
        try await Task.sleep(for: .milliseconds(5200))
        expect(await provider.calls == countBeforePause)
        try await analysis.configureSchedule(enabled: false, everySeconds: 5)
        expect(!analysis.schedule.enabled)

        environment.active = false; environment.handler?(.locked)
        try await eventually { try database.analysisContext().paused }
        expect(try database.activityAnnotation(recordID: first) != nil)
        environment.active = true; environment.handler?(.unlocked)
        try await service.control(.resume)
        await provider.setDelayed(true)
        let quittingAnalysis = Task { try await service.regenerate(query) }
        try await eventually { await provider.pending != nil }
        let shutdown = Task { await service.shutdown() }
        try await eventually { try database.analysisContext().paused }
        await provider.complete()
        do { _ = try await quittingAnalysis.value; preconditionFailure("shutdown late result committed") } catch { }
        expect(await shutdown.value)
        credentials.failWrites = true
        do { try await analysis.save(configuration, key: "TEST_REPLACEMENT"); preconditionFailure("credential failure shown as success") }
        catch { expect(analysis.configurationFailure != nil && !analysis.schedule.enabled) }
        credentials.failWrites = false
        try await analysis.remove(configuration.id)
        expect(analysis.selectedID == nil && analysis.configurations.isEmpty)
        expect(!service.capabilities.regenerate && analysis.guidanceText.contains("尚未配置 Provider"))
        expect(await service.shutdown())

        draft.kind = .codexCLI; draft.executablePath = "relative/codex"
        do { _ = try draft.configuration(); preconditionFailure("relative CLI path accepted") } catch { }
        draft.executablePath = "/tmp/synthetic-codex"; draft.authentication = .existingLogin; draft.loginDirectory = "/tmp/synthetic-login"
        expect(try draft.configuration().cliConfigurationDirectory?.path == "/tmp/synthetic-login")
        print("PASS: selected Provider pending records do not claim missing selection; invalidResponse surfaces and survives reload without annotations; live selection/edit/off/pause/schedule guidance; real Provider settings with memory credentials; explicit selection; enabled-source-only inputs; unchanged capture state does not cancel; pause/off reject late results; opt-in current-day auto analysis without reports; key failure stays visible; shutdown; CLI form validation")
    }

    @MainActor static func eventually(seconds: Double = 3, file: StaticString = #fileID, line: UInt = #line, _ condition: @escaping @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while try await !condition() {
            guard ContinuousClock.now < deadline else { preconditionFailure("synthetic operation did not complete", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
