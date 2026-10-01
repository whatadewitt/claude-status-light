import CoreGraphics
import Testing
@testable import ClaudeStatusLight

struct PanelGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func quadrantFollowsTheTileCenter() {
        #expect(PanelGeometry.quadrant(of: CGRect(x: 900, y: 700, width: 40, height: 40), in: screen) == .topRight)
        #expect(PanelGeometry.quadrant(of: CGRect(x: 10, y: 700, width: 40, height: 40), in: screen) == .topLeft)
        #expect(PanelGeometry.quadrant(of: CGRect(x: 10, y: 10, width: 40, height: 40), in: screen) == .bottomLeft)
        #expect(PanelGeometry.quadrant(of: CGRect(x: 900, y: 10, width: 40, height: 40), in: screen) == .bottomRight)
    }

    @Test func expandingKeepsTheAnchoredCornerFixed() {
        let tile = CGRect(x: 944, y: 744, width: 40, height: 40)   // top-right, 16pt margins
        let size = CGSize(width: 220, height: 120)

        let tr = PanelGeometry.frame(size: size, keeping: .topRight, of: tile, within: screen)
        #expect(tr.maxX == tile.maxX && tr.maxY == tile.maxY && tr.size == size)

        let bl = PanelGeometry.frame(size: size, keeping: .bottomLeft,
                                     of: CGRect(x: 16, y: 16, width: 40, height: 40), within: screen)
        #expect(bl.origin == CGPoint(x: 16, y: 16) && bl.size == size)

        let tl = PanelGeometry.frame(size: size, keeping: .topLeft,
                                     of: CGRect(x: 16, y: 744, width: 40, height: 40), within: screen)
        #expect(tl.minX == 16 && tl.maxY == 784)

        let br = PanelGeometry.frame(size: size, keeping: .bottomRight,
                                     of: CGRect(x: 944, y: 16, width: 40, height: 40), within: screen)
        #expect(br.maxX == 984 && br.minY == 16)
    }

    @Test func expandedFrameIsClampedOnScreen() {
        // A tile dragged near the middle-top: anchoring top-left would still
        // push a very wide panel past the right edge.
        let tile = CGRect(x: 480, y: 744, width: 40, height: 40)
        let f = PanelGeometry.frame(size: CGSize(width: 700, height: 900), keeping: .topLeft, of: tile, within: screen)
        #expect(f.maxX <= screen.maxX)
        #expect(f.minY >= screen.minY)
    }

    @Test func popsOutOnlyForNewlyWaitingSessions() {
        #expect(PanelGeometry.shouldPopOut(waiting: ["a"], previouslyWaiting: []))
        #expect(!PanelGeometry.shouldPopOut(waiting: ["a"], previouslyWaiting: ["a"]))
        #expect(PanelGeometry.shouldPopOut(waiting: ["a", "b"], previouslyWaiting: ["a"]))
        #expect(!PanelGeometry.shouldPopOut(waiting: [], previouslyWaiting: ["a"]))
    }
}
