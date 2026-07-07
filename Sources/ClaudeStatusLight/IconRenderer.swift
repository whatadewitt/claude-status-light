import AppKit

/// Renders the status glyph in a given state color at any size.
///
/// - If the user supplies a custom image at ~/.claude/status-light/icon.png,
///   it is drawn full-color with a small stoplight dot badge in the corner
///   so the artwork stays recognizable.
/// - Otherwise the Claude Code pixel mascot is drawn, tinted to the state
///   color.
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
            drawMascot(color: state.color, in: contentRect)
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

    /// The Claude Code pixel mascot: flat-top body, two slit eyes, a wider
    /// "arms" band, and four legs. `X` cells are filled with the state color;
    /// `.` cells (eyes, gaps) stay transparent.
    private static let mascotGrid: [String] = [
        ".XXXXXXXXXXX.",
        ".XXXXXXXXXXX.",
        ".XX.XXXXX.XX.",
        ".XX.XXXXX.XX.",
        "XXXXXXXXXXXXX",
        "XXXXXXXXXXXXX",
        "XXXXXXXXXXXXX",
        ".XXXXXXXXXXX.",
        ".XXXXXXXXXXX.",
        "..X.X...X.X..",
        "..X.X...X.X..",
    ]

    private static func drawMascot(color: NSColor, in rect: NSRect) {
        let cols = mascotGrid[0].count
        let rows = mascotGrid.count
        let cell = min(rect.width / CGFloat(cols), rect.height / CGFloat(rows))
        let originX = rect.midX - cell * CGFloat(cols) / 2
        let originY = rect.midY - cell * CGFloat(rows) / 2

        // Snap cell boundaries to a shared grid so adjacent cells butt with
        // no hairline cracks, and disable antialiasing for crisp pixel-art
        // edges even at menu bar size.
        let scale = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let xs = (0...cols).map { snap(originX + cell * CGFloat($0)) }
        let ys = (0...rows).map { snap(originY + cell * CGFloat($0)) }

        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        color.setFill()
        for (r, rowString) in mascotGrid.enumerated() {
            for (c, ch) in rowString.enumerated() where ch == "X" {
                let top = rows - r // grid rows go top-down, AppKit y goes up
                NSRect(x: xs[c], y: ys[top - 1],
                       width: xs[c + 1] - xs[c], height: ys[top] - ys[top - 1]).fill()
            }
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    // MARK: - App bundle icon (.icns generation)

    /// A neutral, state-independent app icon: the mascot in Claude terracotta
    /// on a dark rounded tile. Used for the Finder / app-switcher icon (the
    /// live state shows via the runtime dock tint and menu bar).
    private static func drawAppIcon(in rect: NSRect) {
        let side = rect.width
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: side * 0.06, dy: side * 0.06),
                     xRadius: side * 0.22, yRadius: side * 0.22).fill()
        let terracotta = NSColor(calibratedRed: 0xD9 / 255.0, green: 0x77 / 255.0,
                                 blue: 0x57 / 255.0, alpha: 1)
        drawMascot(color: terracotta, in: rect.insetBy(dx: side * 0.2, dy: side * 0.2))
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
