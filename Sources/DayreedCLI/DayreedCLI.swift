import DayreedCore
import Foundation

@main
struct DayreedCLI {
    static let help = """
    用法：dayreed <命令>

      status [--json]   输出当前实现能力（JSON）
      version [--json]  输出版本及构建信息
      help             显示帮助

    当前为基础工程，尚未接入采集、记录查询或 MCP。
    """

    static func main() {
        do {
            switch try CLICommand(arguments: Array(CommandLine.arguments.dropFirst())) {
            case .help:
                print(help)
            case .version(let json):
                if json {
                    try writeJSON(versionInfo)
                } else {
                    print("\(ProductInfo.name) \(ProductInfo.version) (\(ProductInfo.build))")
                }
            case .status:
                try writeJSON([
                    "product": ProductInfo.name,
                    "version": ProductInfo.version,
                    "build": ProductInfo.build,
                    "stage": "foundation",
                    "capabilities": [
                        "screenshots": false,
                        "computerHistory": false,
                        "timelineQuery": false,
                        "reports": false,
                        "mcp": false,
                    ],
                    "rawContentIncluded": false,
                ])
            }
        } catch CLICommand.ParseError.invalidArguments {
            fail("不支持的参数。运行 dayreed help 查看用法。", code: 2)
        } catch {
            fail("无法编码命令结果。", code: 1)
        }
    }

    private static var versionInfo: [String: Any] {
        [
            "name": ProductInfo.name,
            "version": ProductInfo.version,
            "build": ProductInfo.build,
            "bundleIdentifier": ProductInfo.bundleIdentifier,
            "minimumSystemVersion": ProductInfo.minimumSystemVersion,
        ]
    }

    private static func writeJSON(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
