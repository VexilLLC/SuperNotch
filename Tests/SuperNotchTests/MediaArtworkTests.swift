import XCTest
import AppKit
@testable import SuperNotch

final class MediaArtworkTests: XCTestCase {
    func testArtworkDecodeRejectsInvalidAndOversizedDataAndDownsamples() async throws {
        let invalid = await MediaArtworkLoader.decodeData(Data("Not an image".utf8))
        XCTAssertNil(invalid)
        let oversized = await MediaArtworkLoader.decodeData(Data(count: 10 * 1024 * 1024 + 1))
        XCTAssertNil(oversized)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2048, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try XCTUnwrap(bitmap.bitmapData), 128, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let decoded = await MediaArtworkLoader.decodeData(data)
        let image = try XCTUnwrap(decoded)
        XCTAssertEqual(image.size.width, 512)
        XCTAssertEqual(image.size.height, 256)
    }
}
