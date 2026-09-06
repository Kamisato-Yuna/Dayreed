import AppKit
import DayreedCore

/// Explicit local viewing only. No file export, web view, clipboard write, or persistent window restoration.
@MainActor
final class EvidencePresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(_ evidence: RawEvidence) {
        close()
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "本机证据 · 关闭窗口后释放"
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.sharingType = .none
        panel.delegate = self
        if evidence.kind == .screenshot {
            let image = NSImageView()
            image.image = NSImage(data: evidence.data)
            image.imageScaling = .scaleProportionallyUpOrDown
            panel.contentView = image
        } else {
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: panel.contentLayoutRect)
            text.string = String(data: evidence.data, encoding: .utf8) ?? "此证据无法显示。"
            text.isEditable = false
            text.isAutomaticLinkDetectionEnabled = false
            text.isAutomaticDataDetectionEnabled = false
            text.isRichText = false
            text.font = .systemFont(ofSize: 14)
            text.textContainerInset = NSSize(width: 16, height: 16)
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            panel.contentView = scroll
        }
        window = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.contentView = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
}
