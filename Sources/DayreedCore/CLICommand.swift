public enum CLICommand: Equatable, Sendable {
    case help
    case version(json: Bool)
    case status

    public enum ParseError: Error, Equatable {
        case invalidArguments
    }

    public init(arguments: [String]) throws {
        switch arguments {
        case [], ["help"], ["--help"], ["-h"]:
            self = .help
        case ["version"], ["--version"]:
            self = .version(json: false)
        case ["version", "--json"]:
            self = .version(json: true)
        case ["status"], ["status", "--json"]:
            self = .status
        default:
            throw ParseError.invalidArguments
        }
    }
}
