import XCTest
import AppKit
@testable import SuperNotch

final class ArtworkMemoryTests: XCTestCase {
    private func image(width: Int, height: Int) throws -> NSImage {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        memset(try XCTUnwrap(rep.bitmapData), 128, rep.bytesPerRow * height)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    @MainActor func testDecodedCacheEvictsLeastRecentlyUsedWithinByteBudget() throws {
        let image = try image(width: 128, height: 128)
        let cost = 128 * 128 * 4
        let cache = MediaArtworkCache(costLimit: cost * 2)
        cache.insert(image, for: "a")
        cache.insert(image, for: "b")
        XCTAssertNotNil(cache.image(for: "a"))
        cache.insert(image, for: "c")
        XCTAssertNil(cache.image(for: "b"))
        XCTAssertNotNil(cache.image(for: "a"))
        XCTAssertNotNil(cache.image(for: "c"))
        XCTAssertEqual(cache.totalCost, cost * 2)
        cache.insert(image, for: "c")
        XCTAssertEqual(cache.totalCost, cost * 2, "Replacing a key must not double-count it")
        cache.insert(try self.image(width: 512, height: 512), for: "oversize")
        XCTAssertNil(cache.image(for: "oversize"))
        XCTAssertEqual(cache.totalCost, cost * 2)
    }

    @MainActor func testAutomaticArtworkDownsamplesAndSurvivesMetadataHeartbeat() async throws {
        let source = try image(width: 2048, height: 1024)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let encoded = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).base64EncodedString()
        let media = MediaController()
        media.updateAutomaticArtwork(key: "track", encoded: encoded)
        media.updateAutomaticArtwork(key: "track", encoded: nil)
        for _ in 0..<100 where media.artwork == nil { try await Task.sleep(for: .milliseconds(10)) }
        let decoded = try XCTUnwrap(media.artwork)
        XCTAssertEqual(decoded.size, NSSize(width: 512, height: 256))
        media.updateAutomaticArtwork(key: "track", encoded: encoded)
        XCTAssertTrue(media.artwork === decoded, "Repeated snapshots must reuse the decoded image")
        media.updateAutomaticArtwork(key: "different-track", encoded: nil)
        XCTAssertNil(media.artwork, "Never show the previous track's cover for a new missing image")
        media.updateAutomaticArtwork(key: "track", encoded: nil)
        XCTAssertTrue(media.artwork === decoded, "Cached artwork supports snapshots without image bytes")
    }

    @MainActor func testTrackChangeAndClearRejectStaleDecode() async throws {
        let source = try image(width: 2048, height: 1024)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let encoded = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).base64EncodedString()
        let media = MediaController()
        media.updateAutomaticArtwork(key: "old", encoded: encoded)
        media.updateAutomaticArtwork(key: "new", encoded: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(media.artwork)
        media.updateAutomaticArtwork(key: "old", encoded: encoded)
        media.updateAutomaticArtwork(key: nil, encoded: nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(media.artwork)
        media.updateAutomaticArtwork(key: "invalid", encoded: "not base64")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(media.artwork)
    }

    @MainActor func testIconsHaveOnlyDisplaySizedBitmapRepresentation() throws {
        let icon = SmallIconCache.fileIcon(for: "/System/Applications/Utilities/Activity Monitor.app", pixels: 64)
        let rep = try XCTUnwrap(icon.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(icon.representations.count, 1)
        XCTAssertEqual(rep.pixelsWide, 64)
        XCTAssertEqual(rep.pixelsHigh, 64)
        XCTAssertLessThanOrEqual(rep.bytesPerRow * rep.pixelsHigh, 64 * 64 * 4)
        XCTAssertTrue(icon === SmallIconCache.fileIcon(for: "/System/Applications/Utilities/Activity Monitor.app", pixels: 64))
    }
}
