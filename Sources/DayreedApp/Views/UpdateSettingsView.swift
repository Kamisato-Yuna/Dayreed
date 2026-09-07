import DayreedCore
import DayreedUpdate
import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var controller: UpdateController

    var body: some View {
        Section("应用更新") {
            LabeledContent("当前版本", value: AppVersion.display)
            Text(status).foregroundStyle(.secondary)
            Toggle("自动检查更新", isOn: Binding(
                get: { controller.automaticallyChecksForUpdates },
                set: { controller.setAutomaticallyChecksForUpdates($0) }
            )).disabled(unavailable)
            Button("检查更新") { controller.checkForUpdates() }.disabled(!controller.canCheckForUpdates)
            Text("下载、安装与重新启动由系统风格的更新窗口继续处理。检查完成不代表更新已安装。").font(.caption).foregroundStyle(.secondary)
            Link("打开发布页", destination: URL(string: ProductInfo.repository + "/releases")!)
        }
    }

    private var unavailable: Bool {
        switch controller.state {
        case .unavailable: true
        default: false
        }
    }
    private var status: String {
        switch controller.state {
        case .unavailable(let reason): reason
        case .idle: "尚未检查更新"
        case .checking: "正在检查更新…"
        case .available(let version): "发现可用版本 \(version)"
        case .noUpdate: "当前没有适用于此 Mac 的可安装更新"
        case .downloading: "正在下载更新…"
        case .installing: "正在安装更新…"
        case .cancelled: "更新已取消"
        case .failed(let code): "更新未完成（错误码 \(code)），可稍后重试。"
        }
    }
}

enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ProductInfo.version
        let build = info["CFBundleVersion"] as? String ?? String(ProductInfo.build)
        return "\(version) (\(build))"
    }
}
