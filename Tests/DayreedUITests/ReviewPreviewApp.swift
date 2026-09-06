import AppKit
import SwiftUI

/// Compiled only by script/build_review_preview.sh; never part of the shipping product.
@main struct ReviewPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate
    private let service = SyntheticReviewService()
    @State private var appearance: Appearance = .system
    var body: some Scene {
        Window("Dayreed · 合成数据验收", id: "preview") {
            ContentView(service: service)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Label("合成数据验收 · 无采集、无用户数据库、无网络", systemImage: "testtube.2")
                        Spacer()
                        Picker("测试外观", selection: $appearance) {
                            ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                        }.frame(width: 180)
                    }.font(.caption).padding(8)
                }
                .preferredColorScheme(appearance.colorScheme)
                .frame(minWidth: 840, minHeight: 480)
        }.defaultSize(width: 1080, height: 720)
        Settings { SettingsView(service: service).preferredColorScheme(appearance.colorScheme) }
    }
}
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
