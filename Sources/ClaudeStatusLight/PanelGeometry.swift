import CoreGraphics

/// Pure placement logic for the auto-hiding floating panel: the collapsed
/// mascot tile keeps one corner pinned and the full panel grows away from it,
/// toward the middle of the screen.
enum PanelGeometry {
    /// The screen quadrant the tile's center sits in — the corner the panel
    /// should stay pinned to so it expands inward.
    static func quadrant(of rect: CGRect, in screen: CGRect) -> ScreenCorner {
        let top = rect.midY >= screen.midY
        let left = rect.midX < screen.midX
        switch (top, left) {
        case (true, true):   return .topLeft
        case (true, false):  return .topRight
        case (false, true):  return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// A frame of `size` sharing `corner` with `rect`, nudged back inside
    /// `screen` if it would spill off an edge.
    static func frame(size: CGSize, keeping corner: ScreenCorner, of rect: CGRect, within screen: CGRect) -> CGRect {
        var x: CGFloat
        var y: CGFloat
        switch corner {
        case .topLeft:     x = rect.minX;              y = rect.maxY - size.height
        case .topRight:    x = rect.maxX - size.width; y = rect.maxY - size.height
        case .bottomLeft:  x = rect.minX;              y = rect.minY
        case .bottomRight: x = rect.maxX - size.width; y = rect.minY
        }
        x = min(max(x, screen.minX), screen.maxX - size.width)
        y = max(min(y, screen.maxY - size.height), screen.minY)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Pop the panel out when a session starts waiting for input — not on
    /// every refresh while one keeps waiting.
    static func shouldPopOut(waiting: Set<String>, previouslyWaiting: Set<String>) -> Bool {
        !waiting.subtracting(previouslyWaiting).isEmpty
    }
}
