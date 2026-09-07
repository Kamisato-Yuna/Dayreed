import Foundation
import Testing
import DayreedCore
@testable import DayreedAgent

private final class QuerySpy: AgentQuerying {
    var calls = 0
    var fail = false
    func status() throws -> [String: Any] { calls += 1; return ["rawContentIncluded": false] }
    func timeline(_ query: CLIQuery) throws -> [String: Any] {
        calls += 1
        if fail { throw NSError(domain: "RAW_SENTINEL_SECRET", code: 1) }
        return ["date": query.date, "nextCursor": "another-page", "events": []]
    }
    func report(kind: String, query: CLIQuery) throws -> [String: Any] {
        calls += 1; throw AgentFailure.notFound
    }
}

private func send(_ server: MCPServer, _ object: [String: Any]) throws -> [String: Any]? {
    guard let response = server.response(to: try JSONSerialization.data(withJSONObject: object)) else { return nil }
    return try JSONSerialization.jsonObject(with: response) as? [String: Any]
}
private func initialize(_ server: MCPServer) throws {
    let reply = try #require(try send(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
        "protocolVersion": "2025-11-25", "clientInfo": ["name": "synthetic", "version": "1"], "capabilities": [:],
    ]]))
    #expect((reply["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
    #expect(try send(server, ["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
}

@Test func mcpHandshakeToolListAndReadOnlyCalls() throws {
    let spy = QuerySpy(); let server = MCPServer(queries: spy)
    let early = try send(server, ["jsonrpc": "2.0", "id": 0, "method": "tools/list"])
    #expect(early?["error"] != nil)
    try initialize(server)
    let reply = try send(server, ["jsonrpc": "2.0", "id": "list", "method": "tools/list"])
    let tools = try #require((reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String } == ["dayreed_status", "dayreed_timeline", "dayreed_report"])
    #expect(tools.allSatisfy { ($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true })
    let result = try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
        "name": "dayreed_timeline", "arguments": ["date": "2026-09-06", "timezone": "Asia/Shanghai", "limit": 2],
    ]])
    #expect((result?["result"] as? [String: Any])?["isError"] as? Bool == false)
    #expect(spy.calls == 1)
}

@Test func mcpRejectsRawFileSQLMutationsAndInvalidDatesBeforeCallingStore() throws {
    let spy = QuerySpy(); let server = MCPServer(queries: spy); try initialize(server)
    for argument in [["date": "2026-09-06", "raw": true] as [String: Any],
                     ["date": "2026-09-06", "path": "/private/data.sqlite"],
                     ["date": "2026-02-30"], ["date": "2026-09-06", "limit": true],
                     ["date": "2026-09-06", "limit": 1.5]] {
        let reply = try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "dayreed_timeline", "arguments": argument]])
        #expect((reply?["error"] as? [String: Any])?["code"] as? Int == -32602)
    }
    for name in ["rawEvidence", "delete", "execute_sql"] {
        let reply = try send(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name]])
        #expect(reply?["error"] != nil)
    }
    #expect(spy.calls == 0)
}

@Test func mcpNotificationsNeverQueryAndErrorsDoNotRevealUnderlyingContents() throws {
    let spy = QuerySpy(); let server = MCPServer(queries: spy); try initialize(server)
    #expect(try send(server, ["jsonrpc": "2.0", "method": "tools/call", "params": ["name": "dayreed_status"]]) == nil)
    #expect(spy.calls == 0)
    spy.fail = true
    let reply = try #require(try send(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [
        "name": "dayreed_timeline", "arguments": ["date": "2026-09-06"],
    ]]))
    let encoded = String(data: try JSONSerialization.data(withJSONObject: reply), encoding: .utf8)!
    #expect(!encoded.contains("RAW_SENTINEL_SECRET"))
    #expect((reply["result"] as? [String: Any])?["isError"] as? Bool == true)
    let missing = try send(server, ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": [
        "name": "dayreed_report", "arguments": ["kind": "daily", "date": "2026-09-06"],
    ]])
    #expect((missing?["result"] as? [String: Any])?["isError"] as? Bool == true)
}

@Test func malformedOversizedAndModernProbeHaveExplicitProtocolErrors() throws {
    let server = MCPServer(queries: QuerySpy())
    for data in [Data("{".utf8), Data(repeating: 65, count: MCPServer.maximumMessageBytes + 1)] {
        let reply = try #require(server.response(to: data))
        let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        #expect((object?["error"] as? [String: Any])?["code"] as? Int == -32700)
    }
    let discovery = try send(server, ["jsonrpc": "2.0", "id": 1, "method": "server/discover"])
    #expect((discovery?["error"] as? [String: Any])?["code"] as? Int == -32601)
}
