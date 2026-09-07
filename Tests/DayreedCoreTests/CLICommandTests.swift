import Testing
import Foundation
@testable import DayreedCore

@Test func statusSupportsExplicitJSON() throws {
    #expect(try CLICommand(arguments: ["status", "--json"]) == .status)
    #expect(try CLICommand(arguments: ["status"]) == .status)
}

@Test func unsupportedOrSensitiveArgumentsAreRejected() {
    for arguments in [["status", "--raw"], ["--db", "/tmp/data.sqlite"], ["version", "--json", "extra"]] {
        #expect(throws: CLICommand.ParseError.invalidArguments) {
            try CLICommand(arguments: arguments)
        }
    }
}

@Test func versionHasSeparateHumanAndMachineForms() throws {
    #expect(try CLICommand(arguments: ["--version"]) == .version(json: false))
    #expect(try CLICommand(arguments: ["version", "--json"]) == .version(json: true))
}

@Test func queryDatesRespectTimezoneAndRejectAmbiguousOptions() throws {
    let query = try CLIQuery(date: "2026-03-08", timeZoneIdentifier: "America/New_York")
    #expect(query.interval.duration == 23 * 3600)
    #expect(try CLICommand(arguments: ["mcp"]) == .mcp)
    for args in [["timeline", "--date", "2026-02-30"],
                 ["timeline", "--date", "2026-09-06", "--timezone", "invalid/zone"],
                 ["timeline", "--date", "2026-09-06", "--date", "2026-09-07"],
                 ["report", "monthly", "--date", "2026-09-06"],
                 ["report", "daily", "--date", "2026-09-06", "--raw"]] {
        #expect(throws: CLICommand.ParseError.invalidArguments) { try CLICommand(arguments: args) }
    }
}
