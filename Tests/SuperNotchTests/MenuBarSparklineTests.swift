import XCTest
import AppKit
import SwiftUI
@testable import SuperNotch

final class MenuBarSparklineTests: XCTestCase {
    @MainActor func testNativeChartDrawsColoredHistoryAtMenuBarSize() throws {
        _ = NSApplication.shared
        let view = ActivityChartDrawingView(frame: NSRect(x: 0, y: 0, width: 30, height: 15))
        view.chart = ActivityChart(series: [.init(values: [0, 25, 50, 75, 100], color: .red)],
                                   capacity: 5, maximum: 100, showsGrid: false,
                                   lineWidth: 1.2, showsEndDot: false)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 30,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        var redPixels = 0
        for x in 0..<60 {
            for y in 0..<30 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.alphaComponent > 0.1, color.redComponent > color.blueComponent + 0.2 {
                    redPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(redPixels, 30, "The native replacement must render the line and shaded area")
        XCTAssertNil(view.hitTest(NSPoint(x: 15, y: 7)), "Menu-bar clicks must reach the status button")
    }
    @MainActor func testNativeGaugesDrawClampedValuesWithoutFillingRingCenter() throws {
        _ = NSApplication.shared
        let ring = ActivityRingDrawingView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        ring.fraction = 1.5
        ring.tint = .systemRed
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try XCTUnwrap(bitmap.bitmapData), 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        ring.draw(ring.bounds)
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 50, y: 4)).alphaComponent, 0.9)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 50, y: 50)).alphaComponent, 0, accuracy: 0.01)
        XCTAssertNil(ring.hitTest(.zero))
    }

}
