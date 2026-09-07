import AppKit

@MainActor final class MarkView: NSView {
    override func draw(_ dirtyRect: NSRect) { ReedMark.draw(in: bounds) }
}

@main struct ExportBranding {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: export-branding OUTPUT_DIRECTORY") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = MarkView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        try view.dataWithPDF(inside: view.bounds).write(to: directory.appendingPathComponent("ReedTemplate.pdf"))
        for scale in [1, 2] {
            let pixels = 18 * scale
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            ReedMark.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(scale == 1 ? "ReedTemplate.png" : "ReedTemplate@2x.png"))
        }
    }
}
