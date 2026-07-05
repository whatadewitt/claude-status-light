import AppKit

/// Renders the status glyph in a given state color at any size.
///
/// - If the user supplies a custom image at ~/.claude/status-light/icon.png
///   (e.g. the Claude mascot), it is drawn full-color with a small stoplight
///   dot badge in the corner so the artwork stays recognizable.
/// - Otherwise a Claude-style radial "spark" burst is drawn, tinted to the
///   state color.
enum IconRenderer {
    static func icon(for state: LightState, side: CGFloat, background: NSColor? = nil) -> NSImage {
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()

        if let bg = background {
            let inset = side * 0.08
            let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22).fill()
        }

        let contentInset = side * (background == nil ? 0 : 0.16)
        let contentRect = NSRect(x: contentInset, y: contentInset,
                                 width: side - contentInset * 2,
                                 height: side - contentInset * 2)

        if let custom = customImage() {
            // Full-color artwork + a stoplight dot badge for state.
            custom.draw(in: contentRect, from: .zero, operation: .sourceOver, fraction: 1)
            drawBadge(state.color, in: contentRect)
        } else {
            drawBurst(color: state.color, in: contentRect)
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func customImage() -> NSImage? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/status-light/icon.png")
        guard FileManager.default.fileExists(atPath: url.path),
              let img = NSImage(contentsOf: url) else { return nil }
        return img
    }

    /// A state-colored dot with a light ring, pinned to the bottom-right so it
    /// stays legible over any artwork.
    private static func drawBadge(_ color: NSColor, in rect: NSRect) {
        let r = rect.width * 0.24
        let cx = rect.maxX - r
        let cy = rect.minY + r
        let ringRect = NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: ringRect).fill()
        let inner = ringRect.insetBy(dx: r * 0.28, dy: r * 0.28)
        color.setFill()
        NSBezierPath(ovalIn: inner).fill()
    }

    /// A radial burst of tapered spokes — evokes the Claude spark.
    private static func drawBurst(color: NSColor, in rect: NSRect) {
        color.setFill()
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rays = 12
        let outerR = side * (8.0 / 18.0)
        let innerR = side * (2.3 / 18.0)
        let baseHalf = (CGFloat.pi / CGFloat(rays)) * 0.55

        for i in 0..<rays {
            let a = (CGFloat(i) / CGFloat(rays)) * 2 * .pi
            let tip = CGPoint(x: center.x + outerR * cos(a), y: center.y + outerR * sin(a))
            let b1 = CGPoint(x: center.x + innerR * cos(a - baseHalf),
                             y: center.y + innerR * sin(a - baseHalf))
            let b2 = CGPoint(x: center.x + innerR * cos(a + baseHalf),
                             y: center.y + innerR * sin(a + baseHalf))
            let spoke = NSBezierPath()
            spoke.move(to: b1)
            spoke.line(to: tip)
            spoke.line(to: b2)
            spoke.close()
            spoke.fill()
        }
        NSBezierPath(ovalIn: NSRect(x: center.x - innerR, y: center.y - innerR,
                                    width: innerR * 2, height: innerR * 2)).fill()
    }
}
