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
        drawStatus(state: state, in: NSRect(origin: .zero, size: size), background: background)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Draws the status glyph into the current graphics context.
    private static func drawStatus(state: LightState, in rect: NSRect, background: NSColor?) {
        if let bg = background {
            let inset = rect.width * 0.08
            let bgRect = rect.insetBy(dx: inset, dy: inset)
            bg.setFill()
            NSBezierPath(roundedRect: bgRect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22).fill()
        }

        let contentInset = rect.width * (background == nil ? 0 : 0.16)
        let contentRect = rect.insetBy(dx: contentInset, dy: contentInset)

        if let custom = customImage() {
            custom.draw(in: contentRect, from: .zero, operation: .sourceOver, fraction: 1)
            drawBadge(state.color, in: contentRect)
        } else {
            drawBurst(color: state.color, in: contentRect)
        }
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
        color.setFill()
        NSBezierPath(ovalIn: ringRect.insetBy(dx: r * 0.28, dy: r * 0.28)).fill()
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

    // MARK: - App bundle icon (.icns generation)

    /// A neutral, state-independent app icon: a white spark on a dark rounded
    /// tile. Used for the Finder / app-switcher icon (the live state shows via
    /// the runtime dock tint and menu bar).
    private static func drawAppIcon(in rect: NSRect) {
        let side = rect.width
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: side * 0.06, dy: side * 0.06),
                     xRadius: side * 0.22, yRadius: side * 0.22).fill()
        drawBurst(color: .white, in: rect.insetBy(dx: side * 0.2, dy: side * 0.2))
    }

    private static func appIconPNG(px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: px, height: px)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawAppIcon(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Writes a standard AppIcon.iconset directory (for `iconutil -c icns`).
    static func writeIconset(to dirPath: String) {
        let sizes: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        let dir = URL(fileURLWithPath: dirPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, px) in sizes {
            guard let data = appIconPNG(px: px) else { continue }
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
