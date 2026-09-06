import Foundation

struct AgentConfiguration {
    let appURL: URL
    var helperURL: URL { appURL.appendingPathComponent("Contents/Helpers/dayreed") }
    var installerURL: URL { appURL.appendingPathComponent("Contents/Resources/install_cli.sh") }
    var installerAvailable: Bool { FileManager.default.isExecutableFile(atPath: installerURL.path) }
    var helperAvailable: Bool { FileManager.default.isExecutableFile(atPath: helperURL.path) }
    var defaultLinkMatches: Bool {
        let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/dayreed")
        return FileManager.default.isExecutableFile(atPath: link.path)
            && link.resolvingSymlinksInPath() == helperURL.resolvingSymlinksInPath()
    }

    func mcpJSON() throws -> String {
        let object = ["mcpServers": ["dayreed": ["command": helperURL.path, "args": ["mcp"]] as [String: Any]]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let result = String(data: data, encoding: .utf8) else { throw ReviewServiceError.failed }
        return result
    }

    var installCommand: String {
        let script = installerAvailable ? Self.shellQuote(installerURL.path) : "./script/install_cli.sh"
        return script + " install --app " + Self.shellQuote(appURL.path)
    }
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
