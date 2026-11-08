import AppKit

/// Claude-style spark drawn as a template image so it adapts to light/dark menu bars.
enum Logo {
    /// Uses the Claude app's own tray icon when installed (read at runtime, not bundled); falls back to a drawn spark.
    static let menuBar: NSImage = {
        let path = "/Applications/Claude.app/Contents/Resources/TrayIconTemplate@2x.png"
        if let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: 16, height: 16)
            img.isTemplate = true
            return img
        }
        return drawn
    }()

    static let drawn: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size, flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let lengths: [CGFloat] = [7.4, 5.6, 7.0, 5.2, 7.6, 5.8, 7.2, 5.4, 7.4, 5.6, 7.0, 5.4]
            NSColor.black.setStroke()
            for (i, len) in lengths.enumerated() {
                let a = CGFloat(i) * 2 * .pi / CGFloat(lengths.count)
                let p = NSBezierPath()
                p.lineWidth = 1.7
                p.lineCapStyle = .round
                p.move(to: NSPoint(x: c.x + cos(a) * 1.2, y: c.y + sin(a) * 1.2))
                p.line(to: NSPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
                p.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()
}
