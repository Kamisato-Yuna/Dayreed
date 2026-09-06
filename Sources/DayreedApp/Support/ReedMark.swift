import AppKit

/// Optical-size companion to the layered App icon, drawn as a native template image.
@MainActor enum ReedMark {
    static func draw(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scale(by: rect.width / 18)
        transform.concat()
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let stems = NSBezierPath()
        stems.lineWidth = 1.2
        stems.lineCapStyle = .round
        stems.move(to: NSPoint(x: 7, y: 2))
        stems.curve(to: NSPoint(x: 4.4, y: 10), controlPoint1: NSPoint(x: 6.6, y: 6), controlPoint2: NSPoint(x: 5, y: 8))
        stems.move(to: NSPoint(x: 9, y: 2))
        stems.curve(to: NSPoint(x: 9.7, y: 13), controlPoint1: NSPoint(x: 8.7, y: 7), controlPoint2: NSPoint(x: 9.2, y: 10))
        stems.move(to: NSPoint(x: 11, y: 2))
        stems.curve(to: NSPoint(x: 14, y: 10), controlPoint1: NSPoint(x: 11.8, y: 6), controlPoint2: NSPoint(x: 12.5, y: 8))
        stems.stroke()
        for (x, y, angle) in [(4.2, 11.3, 20.0), (9.8, 14.2, -8.0), (14.2, 11.5, -28.0)] {
            NSGraphicsContext.saveGraphicsState()
            let head = NSAffineTransform()
            head.translateX(by: x, yBy: y)
            head.rotate(byDegrees: angle)
            head.concat()
            NSBezierPath(roundedRect: NSRect(x: -1, y: -2, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    static var image: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            // AppKit invokes this drawing handler synchronously on the UI thread.
            MainActor.assumeIsolated { draw(in: rect) }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Dayreed"
        return image
    }
}
