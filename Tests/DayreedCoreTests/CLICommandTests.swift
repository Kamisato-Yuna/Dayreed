import Testing
@testable import DayreedCore

@Test func statusSupportsExplicitJSON() throws {
    #expect(try CLICommand(arguments: ["status", "--json"]) == .status)
    #expect(try CLICommand(arguments: ["status"]) == .status)
}

@Test func unsupportedOrSensitiveArgumentsAreRejected() {
    for arguments in [["status", "--raw"], ["--db", "/tmp/data.sqlite"], ["mcp"], ["version", "--json", "extra"]] {
        #expect(throws: CLICommand.ParseError.invalidArguments) {
            try CLICommand(arguments: arguments)
        }
    }
}

@Test func versionHasSeparateHumanAndMachineForms() throws {
    #expect(try CLICommand(arguments: ["--version"]) == .version(json: false))
    #expect(try CLICommand(arguments: ["version", "--json"]) == .version(json: true))
}
