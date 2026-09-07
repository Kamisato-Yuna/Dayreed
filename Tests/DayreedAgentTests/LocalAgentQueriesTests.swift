import DayreedAgent
import DayreedCore
import Foundation
import Testing

@Test func agentReadsSharedTimelineAndEditedReportWithoutRawEvidence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayreed-agent-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = try DayreedStore(directory: directory)
    let query = try CLIQuery(date: "2026-09-06", timeZoneIdentifier: "Asia/Shanghai", limit: 1)
    for offset in [60.0, 120.0] {
        try writer.append(CaptureRecordInput(capturedAt: query.day.addingTimeInterval(offset), trigger: .timer,
            applicationBundleIdentifier: "test.synthetic.editor", qualities: SourceQualities(application: .available, windowTitle: .available),
            evidence: [.text("RAW_AGENT_SENTINEL_SHOULD_NEVER_LEAVE", kind: .windowTitle)]))
    }
    let reader = try DayreedStore(directory: directory, access: .readOnly)
    let queries = LocalAgentQueries(store: reader)
    let first = try queries.timeline(query)
    #expect((first["events"] as? [[String: Any]])?.count == 1)
    let cursor = try #require(first["nextCursor"] as? String)
    let next = try queries.timeline(CLIQuery(date: query.date, timeZoneIdentifier: query.timeZoneIdentifier, limit: 1, cursor: cursor))
    #expect(next["nextCursor"] is NSNull)
    let json = String(data: try JSONSerialization.data(withJSONObject: [first, next]), encoding: .utf8)!
    #expect(!json.contains("RAW_AGENT_SENTINEL"))
    #expect(throws: AgentFailure.invalidCursor) {
        try queries.timeline(CLIQuery(date: "2026-09-07", timeZoneIdentifier: query.timeZoneIdentifier, cursor: cursor))
    }
    let period = try ReportPeriod(kind: .daily, containing: query.day, timeZoneIdentifier: query.timeZoneIdentifier)
    let reports = ReportService(store: writer)
    let candidate = try reports.generateCandidate(for: period)
    let report = try reports.acceptCandidate(id: candidate.id)
    _ = try reports.edit(id: report.id, markdown: "# 人工整理\n\n合成报告。", expectedVersion: report.version)
    let output = try queries.report(kind: "daily", query: query)
    #expect(output["markdown"] as? String == "# 人工整理\n\n合成报告。")
    #expect(output["isEdited"] as? Bool == true)
    #expect(output["rawContentIncluded"] as? Bool == false)
    #expect(throws: DayreedStoreError.readOnly) { try reader.deleteAll() }
    try writer.deleteAll()
    #expect(throws: AgentFailure.notFound) { try queries.report(kind: "daily", query: query) }
}
