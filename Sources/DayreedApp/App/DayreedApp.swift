import AppKit
import SwiftUI

@main
struct DayreedApp: App {
    @NSApplicationDelegateAdaptor(DayreedAppDelegate.self) private var delegate
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some Scene {
        Window("Dayreed", id: "main") {
            ContentView()
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1080, height: 720)

        Settings {
            SettingsView()
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        }
    }
}

final class DayreedAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
