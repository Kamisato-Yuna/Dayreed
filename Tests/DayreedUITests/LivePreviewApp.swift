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
    @State private var appearance = "light"
    @State private var ready = false
    @State private var failure: String?

    init() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayreed-live-preview-\(UUID())")
        let suite = "Dayreed.LivePreview.\(UUID())"
        self.directory = directory
        self.suite = suite
        service = LiveReviewService(defaults: UserDefaults(suiteName: suite)!, directory: { directory },
                                    environment: AppSyntheticEnvironment(), automaticallySchedules: false,
                                    credentials: AppMemoryCredentials(), providerFactory: { _ in AppSyntheticProvider() })
    }

    var body: some Scene {
        Window("Dayreed · 真实适配器合成验收", id: "preview") {
            VStack(spacing: 0) {
                Group {
                    if ready { ContentView(service: service) }
                    else if let failure { Text("合成数据库创建失败 · \(failure)") }
                    else { ProgressView("准备合成样本…") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack {
                    Text("合成验收 · 昨天长文 / 明天空白").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("验收主题", selection: $appearance) {
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("验收主题").frame(width: 150)
                        .accessibilityIdentifier("preview.appearance")
                }.padding(8)
            }
            .preferredColorScheme(appearance == "dark" ? .dark : .light)
            .frame(minWidth: 720, minHeight: 480)
            .task {
                guard !ready else { return }
                delegate.directory = directory
                delegate.suite = suite
                do {
                    try await LivePreviewSamples.seed(service: service, image: Self.image())
                    ready = true
                } catch {
                    // Only bounded domain errors, never raw backend descriptions or data paths.
                    failure = (error as? ReviewServiceError)?.errorDescription
                        ?? (error as? AnalysisError)?.rawValue ?? "存储或样本校验失败"
                }
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
