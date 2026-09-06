import Foundation

public struct CLIQuery: Equatable, Sendable {
    public enum Format: String, Sendable { case json, markdown }
    public let date: String
    public let timeZoneIdentifier: String
    public let limit: Int
    public let cursor: String?
    public let format: Format

    public init(date: String, timeZoneIdentifier: String = TimeZone.current.identifier,
                limit: Int = 100, cursor: String? = nil, format: Format = .json) throws {
        guard date.utf8.count == 10, let zone = TimeZone(identifier: timeZoneIdentifier),
              (1...500).contains(limit), (cursor?.utf8.count ?? 0) <= 4096 else {
            throw CLICommand.ParseError.invalidArguments
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else {
            throw CLICommand.ParseError.invalidArguments
        }
        self.date = date; self.timeZoneIdentifier = zone.identifier
        self.limit = limit; self.cursor = cursor; self.format = format
    }

    public var day: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        let parts = date.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
    }

    public var interval: DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.dateInterval(of: .day, for: day)!
    }
}

public enum CLICommand: Equatable, Sendable {
    case help, status, mcp, mcpConfig
    case version(json: Bool)
    case timeline(CLIQuery)
    case report(kind: String, query: CLIQuery)

    public enum ParseError: Error, Equatable { case invalidArguments }

    public init(arguments: [String]) throws {
        switch arguments {
        case [], ["help"], ["--help"], ["-h"]: self = .help
        case ["version"], ["--version"]: self = .version(json: false)
        case ["version", "--json"]: self = .version(json: true)
        case ["status"], ["status", "--json"]: self = .status
        case ["mcp"]: self = .mcp
        case ["mcp-config"]: self = .mcpConfig
        default:
            if arguments.first == "timeline" {
                self = .timeline(try Self.query(Array(arguments.dropFirst()), paginated: true))
            } else if arguments.count >= 2, arguments[0] == "report", ["daily", "weekly"].contains(arguments[1]) {
                self = .report(kind: arguments[1], query: try Self.query(Array(arguments.dropFirst(2)), paginated: false))
            } else { throw ParseError.invalidArguments }
        }
    }

    private static func query(_ args: [String], paginated: Bool) throws -> CLIQuery {
        var values: [String: String] = [:]
        var format = CLIQuery.Format.json
        var formatSeen = false
        var index = 0
        while index < args.count {
            let key = args[index]
            if key == "--json" || key == "--markdown" {
                guard !formatSeen else { throw ParseError.invalidArguments }
                format = key == "--json" ? .json : .markdown
                formatSeen = true; index += 1; continue
            }
            let allowed = paginated ? ["--date", "--timezone", "--limit", "--cursor"] : ["--date", "--timezone"]
            guard allowed.contains(key), values[key] == nil, index + 1 < args.count else {
                throw ParseError.invalidArguments
            }
            values[key] = args[index + 1]; index += 2
        }
        guard let date = values["--date"] else { throw ParseError.invalidArguments }
        let limit: Int
        if let value = values["--limit"] {
            guard let number = Int(value) else { throw ParseError.invalidArguments }
            limit = number
        } else { limit = 100 }
        return try CLIQuery(date: date, timeZoneIdentifier: values["--timezone"] ?? TimeZone.current.identifier,
                            limit: limit, cursor: values["--cursor"], format: format)
    }
}
