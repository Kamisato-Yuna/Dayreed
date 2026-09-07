import DayreedCore
import Foundation

/// Opens only Dayreed's fixed data location in SQLite read-only mode. Tests may inject a store;
/// the CLI and MCP provide no database-path, SQL or file-read parameter.
public struct LocalAgentQueries: AgentQuerying {
    private let openStore: () throws -> DayreedStore
    public init() {
        openStore = { try DayreedStore(directory: DayreedDataDirectory.defaultURL(), access: .readOnly) }
    }
    public init(store: DayreedStore) { openStore = { store } }

    public func status() throws -> [String: Any] {
        var result: [String: Any] = [
            "product": ProductInfo.name, "version": ProductInfo.version, "build": ProductInfo.build,
            "readOnly": true, "rawContentIncluded": false,
            "capabilities": ["screenshots": true, "computerHistory": true, "timelineQuery": true, "reports": true, "mcp": true],
        ]
        do {
            let store = try openStore()
            let context = try store.analysisContext()
            result["dataAvailable"] = true
            result["configuredSources"] = context.settings.analysisSources.map(\.rawValue).sorted()
            result["providerSelected"] = context.selectedProviderID != nil
            result["captureState"] = "请在App查看实时采集状态"
            result["analysis"] = try object(DayreedQueryService(store: store).analysisStatus())
        } catch {
            result["dataAvailable"] = false
            result["message"] = AgentFailure.unavailable.message
        }
        return result
    }

    public func timeline(_ query: CLIQuery) throws -> [String: Any] {
        let store = try readableStore()
        let cursor: TimelineCursor?
        if let text = query.cursor {
            guard let data = Data(base64Encoded: text),
                  let decoded = try? JSONDecoder().decode(Cursor.self, from: data),
                  decoded.date == query.date, decoded.timeZone == query.timeZoneIdentifier,
                  decoded.position.start.timeIntervalSince1970.isFinite,
                  decoded.position.start >= query.interval.start, decoded.position.start < query.interval.end else {
                throw AgentFailure.invalidCursor
            }
            cursor = decoded.position
        } else { cursor = nil }
        do {
            let page = try DayreedQueryService(store: store).timeline(in: query.interval, limit: query.limit, after: cursor)
            let next = try page.nextCursor.map {
                try JSONEncoder().encode(Cursor(date: query.date, timeZone: query.timeZoneIdentifier, position: $0)).base64EncodedString()
            }
            return [
                "date": query.date, "timezone": query.timeZoneIdentifier,
                "start": iso(query.interval.start), "end": iso(query.interval.end),
                "events": page.events.map { event -> [String: Any] in [
                    "id": event.id.uuidString, "start": iso(event.start), "end": iso(event.end),
                    "observedSeconds": event.observedSeconds,
                    "title": event.title.map { $0 as Any } ?? NSNull(),
                    "summary": event.summary.map { $0 as Any } ?? NSNull(),
                    "state": event.state.rawValue, "sources": event.sources.map(\.rawValue).sorted(),
                    "recordIDs": event.recordIDs.map(\.uuidString), "evidenceIDs": event.evidenceIDs.map(\.uuidString),
                ] },
                "nextCursor": next.map { $0 as Any } ?? NSNull(), "rawContentIncluded": false,
            ]
        } catch let failure as AgentFailure { throw failure }
        catch { throw AgentFailure.queryFailed }
    }

    public func report(kind: String, query: CLIQuery) throws -> [String: Any] {
        guard let kind = ReportKind(rawValue: kind) else { throw CLICommand.ParseError.invalidArguments }
        let store = try readableStore()
        do {
            let period = try ReportPeriod(kind: kind, containing: query.day, timeZoneIdentifier: query.timeZoneIdentifier)
            guard let report = try DayreedQueryService(store: store).report(for: period) else { throw AgentFailure.notFound }
            return [
                "id": report.id.uuidString, "kind": kind.rawValue, "timezone": period.timeZoneIdentifier,
                "start": iso(period.interval.start), "end": iso(period.interval.end),
                "markdown": report.markdown, "version": report.version, "isEdited": report.isEdited,
                "needsReview": report.needsReview, "updatedAt": iso(report.updatedAt),
                "recordIDs": report.recordIDs.map(\.uuidString), "rawContentIncluded": false,
            ]
        } catch let failure as AgentFailure { throw failure }
        catch { throw AgentFailure.queryFailed }
    }

    private func readableStore() throws -> DayreedStore {
        do { return try openStore() } catch { throw AgentFailure.unavailable }
    }
    private func object<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private struct Cursor: Codable {
        let date: String
        let timeZone: String
        let position: TimelineCursor
    }
}
