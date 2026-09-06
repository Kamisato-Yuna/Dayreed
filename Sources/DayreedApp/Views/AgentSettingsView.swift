import AppKit
import SwiftUI

struct AgentSettingsView: View {
    private let configuration = AgentConfiguration(appURL: Bundle.main.bundleURL)
    @State private var message: String?
    var body: some View {
        Section("只读 CLI / MCP") {
            Text("Agent 1.0 只查询时间线、日报、周报与状态，不提供修改或原始证据工具。显式运行 CLI 无需额外启用开关。")
            LabeledContent("包内 CLI", value: configuration.helperAvailable ? "已找到可执行文件" : "当前 App 包未包含 CLI")
            Text(configuration.helperURL.path).font(.caption.monospaced()).textSelection(.enabled)
            LabeledContent("默认命令链接", value: configuration.defaultLinkMatches ? "~/.local/bin/dayreed 已指向此 App" : "尚未链接到此 App")
        }
        Section("MCP 配置") {
            Text("复制配置到支持 stdio 的本机 MCP 客户端。配置使用当前 App 的完整路径；移动 App 后请重新复制。")
                .font(.callout).foregroundStyle(.secondary)
            Button("复制 MCP 配置") { copy { try configuration.mcpJSON() } }.disabled(!configuration.helperAvailable)
            Text("工具：dayreed_status、dayreed_timeline、dayreed_report。启动 MCP 只开放查询，不启动采集或分析。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("终端安装") {
            Text("在 Dayreed 源码目录执行安装脚本，将 CLI 链接到 ~/.local/bin；脚本不会修改 shell 配置。MCP 直接使用包内 CLI，无需此链接。")
                .font(.callout).foregroundStyle(.secondary)
            Text(configuration.installCommand).font(.caption.monospaced()).textSelection(.enabled)
            Button("复制安装命令") { copy { configuration.installCommand } }.disabled(!configuration.helperAvailable)
            if let message { Text(message).font(.caption) }
        }
    }

    private func copy(_ value: () throws -> String) {
        do {
            let text = try value()
            NSPasteboard.general.clearContents()
            message = NSPasteboard.general.setString(text, forType: .string) ? "已复制" : "未能写入剪贴板"
        } catch { message = "未能生成配置" }
    }
}
