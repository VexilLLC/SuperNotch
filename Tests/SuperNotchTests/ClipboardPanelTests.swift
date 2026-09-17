import XCTest
@testable import SuperNotch

final class ClipboardPanelTests: XCTestCase {
    func testStoredOriginRemainsInsideVisibleScreenMargins() {
        let visible = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let size = NSSize(width: 600, height: 290)

        XCTAssertEqual(
            ClipboardPanelPlacement.clampedOrigin(NSPoint(x: -500, y: -300), windowSize: size, visibleFrame: visible),
            NSPoint(x: 108, y: 58)
        )
        XCTAssertEqual(
            ClipboardPanelPlacement.clampedOrigin(NSPoint(x: 2_000, y: 2_000), windowSize: size, visibleFrame: visible),
            NSPoint(x: 692, y: 552)
        )
        XCTAssertEqual(
            ClipboardPanelPlacement.clampedOrigin(NSPoint(x: 280, y: 180), windowSize: size, visibleFrame: visible),
            NSPoint(x: 280, y: 180)
        )
    }

    func testClampingHandlesAWindowLargerThanTheVisibleFrame() {
        let origin = ClipboardPanelPlacement.clampedOrigin(
            NSPoint(x: 900, y: 700),
            windowSize: NSSize(width: 900, height: 700),
            visibleFrame: NSRect(x: 20, y: 30, width: 640, height: 480)
        )

        XCTAssertEqual(origin, NSPoint(x: 28, y: 38))
    }
}
