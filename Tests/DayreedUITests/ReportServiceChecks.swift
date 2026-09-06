import DayreedCore
import Foundation

extension LiveServiceChecks {
    @MainActor static func checkReports() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayreed-report-ui-\(UUID())")
        let suite = "Dayreed.ReportUI.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let service = LiveReviewService(defaults: defaults, directory: { directory }, environment: AppSyntheticEnvironment(), automaticallySchedules: false)
        let database = try await service.prepare()
        let query = ReviewQuery(date: .now, kind: .daily)
        let manual = try await service.save(markdown: "# 手工日报\n没有采集也可写", report: nil, query: query)
        expect(manual.isEdited && manual.version == 1 && manual.sources.isEmpty)
        do { _ = try await service.save(markdown: "并发创建", report: nil, query: query); preconditionFailure("duplicate create accepted") }
        catch { expect(error as? ReviewServiceError == .conflict) }
        do { _ = try await service.regenerate(query); preconditionFailure("empty report generation accepted") }
        catch { expect(error as? ReviewServiceError == .noEvidence) }
        expect(try await service.load(query).report?.markdown == manual.markdown)

        let provider = ProviderConfiguration(name: "合成Provider", kind: .openAICompatible, model: "synthetic", endpoint: URL(string: "http://127.0.0.1/v1/chat/completions"))
        try database.saveProviderConfiguration(provider)
        try database.selectProvider(id: provider.id)
        try database.updateAnalysisContext(settings: CaptureSettings(historyEnabled: true), paused: false)
        var ids: [UUID] = []
        let noon = query.interval.start.addingTimeInterval(12 * 3600)
        for offset in [0.0, 30.0] {
            let record = try database.append(CaptureRecordInput(capturedAt: noon.addingTimeInterval(offset), trigger: .timer,
                applicationBundleIdentifier: "test.synthetic", qualities: SourceQualities(application: .available),
                evidence: [.text("RAW_SHOULD_NOT_APPEAR", kind: .windowTitle)]))
            ids.append(record.id)
            try database.saveAnalysis([ActivityClassification(recordID: record.id, title: "整理文档", summary: "合成摘要")],
                providerID: provider.id, providerVersion: 1, sources: [record.id: [.application]], evidenceIDs: [record.id: []],
                expectedRevision: database.analysisContext().revision, continuitySeconds: 60)
        }
        let events = try await service.load(ReviewQuery(date: .now)).events
        expect(events.count == 1 && events[0].end.timeIntervalSince(events[0].start) == 30)
        expect(events[0].recordVersions.count == 2 && events[0].isCorrectable && events[0].evidence.count == 2)
        var snapshot = try await service.regenerate(query)
        expect(snapshot.report?.markdown == manual.markdown && snapshot.candidates.count == 1)
        let oldCandidate = snapshot.candidates[0]
        let edited = try await service.save(markdown: "# 手工编辑的新版本", report: snapshot.report, query: query)
        do { _ = try await service.accept(candidate: oldCandidate, query: query); preconditionFailure("stale candidate accepted") }
        catch { expect(error as? ReviewServiceError == .conflict) }
        snapshot = try await service.discard(candidate: oldCandidate, query: query)
        expect(snapshot.report?.markdown == edited.markdown && snapshot.candidates.isEmpty)
        snapshot = try await service.regenerate(query)
        snapshot = try await service.accept(candidate: snapshot.candidates[0], query: query)
        expect(snapshot.report?.isEdited == false && snapshot.candidates.isEmpty && snapshot.report?.sources.count == 2)
        expect(snapshot.report?.markdown.contains("RAW_SHOULD_NOT_APPEAR") == false)
        let corrected = try await service.correct(event: events[0], title: "人工纠正", summary: "两条观测一起纠正")
        expect(corrected.recordVersions.values.allSatisfy { $0 == 2 })
        expect(try await service.load(query).report?.needsReview == true)
        do { _ = try await service.correct(event: events[0], title: "过期版本", summary: "不得部分保存"); preconditionFailure("stale correction accepted") }
        catch { expect(error as? ReviewServiceError == .conflict) }
        expect(try ids.allSatisfy { try database.activityAnnotation(recordID: $0)?.classification.title == "人工纠正" })
        let weekly = ReviewQuery(date: .now, kind: .weekly)
        expect(Calendar.current.component(.weekday, from: weekly.interval.start) == 2)
        let weekSnapshot = try await service.regenerate(weekly)
        expect(weekSnapshot.candidates.count == 1)
        let deletion = try await service.prepareDeletion(date: .now)
        try await service.delete(deletion)
        expect(try await service.load(query).report == nil)
        expect(try await service.load(weekly).candidates.isEmpty)
        // A manual report with zero source records still has an actual delete path.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date.now)!
        let emptyQuery = ReviewQuery(date: yesterday, kind: .daily)
        _ = try await service.save(markdown: "无来源手工报告", report: nil, query: emptyQuery)
        let emptyDeletion = try await service.prepareDeletion(date: yesterday)
        expect(emptyDeletion.count == 0 && emptyDeletion.reportCount == 1 && !emptyDeletion.isEmpty)
        try await service.delete(emptyDeletion)
        expect(try await service.load(emptyQuery).report == nil)
        try await service.control(.stop)
        print("PASS: empty-day manual report; duplicate create conflict; candidate review and replacement conflict; grouped real timeline; atomic correction; report needs-review; weekly bounds; deletion erases reports/candidates including source-free manual reports")
    }
}
