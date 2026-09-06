import AppKit
import DayreedUpdate
import SwiftUI

@main
struct DayreedApp: App {
    @NSApplicationDelegateAdaptor(DayreedAppDelegate.self) private var delegate
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    @AppStorage("showMenuBar") private var showMenuBar = false
    @Environment(\.openWindow) private var openWindow

    @StateObject private var updater = UpdateController()
    private let service: any ReviewService
    @State private var reviewStore: ReviewStore

    init() {
        let service = LiveReviewService()
        self.service = service
        _reviewStore = State(initialValue: ReviewStore(service: service))
        Task { _ = try? await service.prepare() }
    }

    var body: some Scene {
        Window("Dayreed", id: "main") {
            ContentView(store: reviewStore)
                .onAppear { delegate.reviewStore = reviewStore; updater.start() }
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 840, minHeight: 480)
        }
        .defaultSize(width: 1080, height: 720)

        MenuBarExtra(isInserted: $showMenuBar) {
            Button("打开 Dayreed") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            SettingsLink { Text("设置…") }
            Divider()
            Button("退出 Dayreed") { NSApp.terminate(nil) }
        } label: { Image(nsImage: ReedMark.image) }

        Settings {
            SettingsView(service: service, updater: updater)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        }
    }
}

final class DayreedAppDelegate: NSObject, NSApplicationDelegate {
    weak var reviewStore: ReviewStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let reviewStore else { return .terminateNow }
        if reviewStore.isWorking {
            let alert = NSAlert()
            alert.messageText = "操作尚未完成"
            alert.informativeText = "请等待保存或生成结束后再退出。"
            alert.addButton(withTitle: "返回 Dayreed")
            alert.runModal()
            return .terminateCancel
        }
        guard reviewStore.isDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "报告还有未保存的修改"
        alert.informativeText = "返回编辑后可使用 ⌘S 保存。放弃修改会丢失当前草稿。"
        alert.addButton(withTitle: "返回编辑")
        alert.addButton(withTitle: "放弃修改并退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
