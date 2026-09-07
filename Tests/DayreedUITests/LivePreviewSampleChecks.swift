import DayreedCore
import Foundation

@main struct LivePreviewSampleChecks {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayreed-preview-check-\(UUID())")
        let suite = "Dayreed.PreviewCheck.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let environment = AppSyntheticEnvironment()
        let service = LiveReviewService(defaults: defaults, directory: { directory }, environment: environment, automaticallySchedules: false)
        try await LivePreviewSamples.seed(service: service, image: Data([1, 2, 3]))
        let daily = try await service.load(ReviewQuery(date: .now, kind: .daily))
        precondition(daily.events.count == 4 && daily.events.allSatisfy { !$0.evidence.isEmpty })
        precondition(daily.report != nil && daily.candidates.count == 1)
        let weekly = try await service.load(ReviewQuery(date: .now, kind: .weekly))
        precondition(weekly.report != nil)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date.now)!
        let longReport = try await service.load(ReviewQuery(date: yesterday, kind: .daily))
        precondition((longReport.report?.markdown.count ?? 0) > 2000)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date.now)!
        let empty = try await service.load(ReviewQuery(date: tomorrow, kind: .daily))
        precondition(empty.events.isEmpty && empty.report == nil)
        let preferences = try await service.preferences()
        precondition(preferences.sources.allSatisfy { !$0.enabled })
        precondition(environment.requests == 0 && environment.samples == 0 && !environment.monitoring)
        print("PASS: preview samples seed through real Core; four activities with evidence; daily/weekly reports and candidate; long/empty dates; collection stays off")
    }
}
