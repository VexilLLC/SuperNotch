import XCTest
import SwiftUI
import AppKit
@testable import SuperNotch

final class QuickRingSnapshotTest: XCTestCase {
    @MainActor func testQuickRingRendersAtItsDesignedSize() throws {
        let renderer = ImageRenderer(content: QuickRingView(controller: .shared).preferredColorScheme(.dark))
        renderer.proposedSize = ProposedViewSize(width: QuickRingSelectionGeometry.panelSize, height: QuickRingSelectionGeometry.panelSize)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, QuickRingSelectionGeometry.panelSize, accuracy: 0.5)
        XCTAssertEqual(image.size.height, QuickRingSelectionGeometry.panelSize, accuracy: 0.5)
    }
}
