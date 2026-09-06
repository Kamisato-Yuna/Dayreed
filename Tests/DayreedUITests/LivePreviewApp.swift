import AppKit
import DayreedCore
import DayreedUpdate
import SwiftUI

/// A test-only app uses the production adapter against an isolated synthetic environment.
@main struct LivePreviewApp: App {
    @NSApplicationDelegateAdaptor(LivePreviewDelegate.self) private var delegate
    private let updater = UpdateController()
    private let service: LiveReviewService
    private let directory: URL
    private let suite: String
    @State private var ready = false
    @State private var failure = false

    init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayreed-live-preview-\(UUID())")
        let suite = "Dayreed.LivePreview.\(UUID())"
        self.directory = directory
        self.suite = suite
        service = LiveReviewService(defaults: UserDefaults(suiteName: suite)!, directory: { directory },
                                    environment: AppSyntheticEnvironment(), automaticallySchedules: false)
    }

    var body: some Scene {
        Window("Dayreed · 真实适配器合成验收", id: "preview") {
            Group {
                if ready { ContentView(service: service) }
                else if failure { Text("合成数据库创建失败") }
                else { ProgressView("准备合成样本…") }
            }
            .safeAreaInset(edge: .bottom) {
                Text("仅合成数据库与模拟权限 · 不采集真实桌面 · 不访问网络").font(.caption).padding(8)
            }
            .frame(minWidth: 840, minHeight: 480)
            .task {
                guard !ready else { return }
                delegate.directory = directory
                delegate.suite = suite
                do {
                    let database = try await service.prepare()
                    let sample = Self.image()
                    _ = try await Task.detached {
                        try database.append(CaptureRecordInput(capturedAt: .now, trigger: .manual,
                            applicationBundleIdentifier: "test.synthetic-editor",
                            qualities: SourceQualities(screenshot: .available, application: .available, windowTitle: .available, accessibilityText: .available),
                            evidence: [EvidenceInput(kind: .screenshot, mediaType: "image/png", data: sample),
                                       .text("合成窗口标题 · 不包含个人内容", kind: .windowTitle),
                                       .text("这是一段专用于证据窗口验收的合成辅助功能文本。", kind: .accessibilityText)]))
                    }.value
                    ready = true
                } catch { failure = true }
            }
        }.defaultSize(width: 1080, height: 720)
        Settings { SettingsView(service: service, updater: updater) }
    }

    @MainActor private static func image() -> Data {
        let image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            ("Dayreed 合成证据\n无个人内容" as NSString).draw(at: NSPoint(x: 48, y: 160), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.labelColor])
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}

final class LivePreviewDelegate: NSObject, NSApplicationDelegate {
    var directory: URL?
    var suite: String?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }
}
