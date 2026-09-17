import XCTest
import SwiftUI
import AppKit
@testable import SuperNotch

final class WorkspaceVisualTests: XCTestCase {
    @MainActor func testAccentGradientContinuesThroughTallWorkspace() throws {
        let width: CGFloat = 1_200
        let height: CGFloat = 900
        let renderer = ImageRenderer(content:
            ZStack {
                Color.black
                WorkspaceAccentBackground(color: .green)
            }
            .frame(width: width, height: height)
            .preferredColorScheme(.dark)
        )
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = 1

        let image = try XCTUnwrap(renderer.nsImage)
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let lowerCanvasColor = try XCTUnwrap(bitmap.colorAt(x: Int(width / 2), y: 100)?.usingColorSpace(.deviceRGB))

        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, height, accuracy: 0.5)
        XCTAssertGreaterThan(lowerCanvasColor.greenComponent, lowerCanvasColor.redComponent + 0.005)
    }

    @MainActor func testActivityWorkspaceRendersAtFullscreenReferenceSize() throws {
        _ = NSApplication.shared
        let state = AppState.shared
        let previousPage = state.page
        let previousToolGroup = state.toolGroup
        let previousToolDetail = state.toolDetail
        defer {
            state.page = previousPage
            state.toolGroup = previousToolGroup
            state.toolDetail = previousToolDetail
        }

        state.page = .tools
        state.toolGroup = ToolGroup.activity.rawValue
        state.toolDetail = "Events"

        // The supplied fullscreen reference is 2562 x 1628 pixels on a 2x display.
        let width: CGFloat = 1_281
        let height: CGFloat = 814
        let renderer = ImageRenderer(content:
            WorkspaceView()
                .transaction { $0.disablesAnimations = true }
                .frame(width: width, height: height)
                .preferredColorScheme(.dark)
        )
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, height, accuracy: 0.5)

        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 2_562)
        XCTAssertEqual(bitmap.pixelsHigh, 1_628)

        if let output = ProcessInfo.processInfo.environment["SUPERNOTCH_WORKSPACE_SNAPSHOT_OUTPUT"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    @MainActor func testPerformanceWorkspaceRendersAtFullscreenReferenceSize() throws {
        let state = AppState.shared
        let previousPage = state.page
        let previousToolGroup = state.toolGroup
        let previousToolDetail = state.toolDetail
        defer {
            state.page = previousPage
            state.toolGroup = previousToolGroup
            state.toolDetail = previousToolDetail
        }

        state.page = .tools
        state.toolGroup = ToolGroup.activity.rawValue
        state.toolDetail = "Performance"

        let width: CGFloat = 1_281
        let height: CGFloat = 814
        let renderer = ImageRenderer(content:
            WorkspaceView()
                .transaction { $0.disablesAnimations = true }
                .frame(width: width, height: height)
                .preferredColorScheme(.dark)
        )
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.nsImage)
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 2_562)
        XCTAssertEqual(bitmap.pixelsHigh, 1_628)

        if let output = ProcessInfo.processInfo.environment["SUPERNOTCH_PERFORMANCE_SNAPSHOT_OUTPUT"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
