import DayreedAgent
import DayreedCore
import Foundation

@main
struct DayreedCLI {
    static let help = """
    用法：dayreed <命令>

      status [--json]       本地记录可用性及能力；不开始采集或分析
      version [--json]      版本及构建信息
      timeline --date YYYY-MM-DD [--timezone IANA] [--limit 1...500] [--cursor 游标] [--json|--markdown]
      report daily|weekly --date YYYY-MM-DD [--timezone IANA] [--json|--markdown]
      mcp                  只读 stdio MCP 服务
      mcp-config           输出本机可执行路径的 MCP 配置 JSON
      help                 显示帮助

    日期必须明确指定，时区默认为本机时区。周报按 ISO 周一开始。
    时间线默认 JSON 分页，nextCursor 非空时传回继续读取。
    只读取 Dayreed 固定数据空间，不输出原始截图/窗口正文，不修改记录。
    """

    static func main() {
        do {
            let queries = LocalAgentQueries()
            switch try CLICommand(arguments: Array(CommandLine.arguments.dropFirst())) {
            case .help: print(help)
            case .version(let json):
                if json { try writeJSON(versionInfo) }
                else { print("\(ProductInfo.name) \(ProductInfo.version) (\(ProductInfo.build))") }
            case .status: try writeJSON(queries.status())
            case .timeline(let query):
                let result = try queries.timeline(query)
                if query.format == .json { try writeJSON(result) }
                else { print(timelineMarkdown(result)) }
            case .report(let kind, let query):
                let result = try queries.report(kind: kind, query: query)
                if query.format == .json { try writeJSON(result) }
                else { print(result["markdown"] as? String ?? "") }
            case .mcp: try MCPServer(queries: queries).run()
            case .mcpConfig:
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
                try writeJSON(["mcpServers": ["dayreed": ["command": executable, "args": ["mcp"]]]])
            }
        } catch is CLICommand.ParseError {
            fail(code: "invalid_arguments", message: "不支持的参数或日期。运行 dayreed help 查看用法。", exitCode: 2)
        } catch let failure as AgentFailure {
            fail(code: failure.rawValue, message: failure.message, exitCode: failure == .notFound ? 4 : 3)
        } catch {
            fail(code: "operation_failed", message: "操作未完成。", exitCode: 1)
        }
    }

    private static var versionInfo: [String: Any] {
        ["name": ProductInfo.name, "version": ProductInfo.version, "build": ProductInfo.build,
         "bundleIdentifier": ProductInfo.bundleIdentifier, "minimumSystemVersion": ProductInfo.minimumSystemVersion]
    }
    private static func writeJSON(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0A); try FileHandle.standardOutput.write(contentsOf: data)
    }
    private static func fail(code: String, message: String, exitCode: Int32) -> Never {
        if let data = try? JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]], options: [.sortedKeys]) {
            try? FileHandle.standardError.write(contentsOf: data + Data([0x0A]))
        }
        exit(exitCode)
    }
    private static func timelineMarkdown(_ result: [String: Any]) -> String {
        var lines = ["# 时间线 · \(result["date"] as? String ?? "")", "", "时区：\(result["timezone"] as? String ?? "")", ""]
        for event in result["events"] as? [[String: Any]] ?? [] {
            let title = (event["title"] as? String ?? "待分析观测").replacingOccurrences(of: "\n", with: " ")
            lines.append("- **\(event["start"] as? String ?? "") – \(event["end"] as? String ?? "")** \(title)")
            if let summary = event["summary"] as? String, !summary.isEmpty { lines.append("  \(summary.replacingOccurrences(of: "\n", with: " "))") }
            lines.append("  来源：\((event["sources"] as? [String] ?? []).joined(separator: "、"))；状态：\(event["state"] as? String ?? "")")
        }
        if let cursor = result["nextCursor"] as? String { lines += ["", "下一页游标：`\(cursor)`"] }
        return lines.joined(separator: "\n")
    }
}
