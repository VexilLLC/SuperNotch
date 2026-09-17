import XCTest
import AppKit
@testable import SuperNotch

final class ClipboardThumbnailTests: XCTestCase {
    func testThumbnailIsSmallJPEGAndHistoryWithoutThumbnailsStillDecodes() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try XCTUnwrap(bitmap.bitmapData), 90, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let thumbnail = try XCTUnwrap(ClipboardThumbnailCache.makeThumbnail(from: png))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: thumbnail))
        XCTAssertEqual(max(rep.pixelsWide, rep.pixelsHigh), ClipboardThumbnailCache.maxPixel)
        XCTAssertEqual(thumbnail.prefix(2), Data([0xFF, 0xD8]), "Thumbnails are stored as JPEG")
        XCTAssertLessThan(thumbnail.count, 200_000)

        let legacy = #"[{"id":"\#(UUID().uuidString)","createdAt":0,"kind":"image","text":"","paths":[],"isPinned":false}]"#
        let entries = try JSONDecoder().decode([ClipboardEntry].self, from: Data(legacy.utf8))
        XCTAssertNil(entries.first?.thumbnail)
    }

    @MainActor func testAttachedThumbnailPersists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("history.json")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = ClipboardEntry(id: UUID(), createdAt: Date(), kind: .image, text: "", payload: Data([1, 2, 3]), paths: [], isPinned: false)
        try JSONEncoder().encode([entry]).write(to: url)
        let store = ClipboardStore(historyURL: url, pasteboard: board)
        store.attachThumbnail(Data([0xFF, 0xD8, 0x00]), to: entry.id)
        store.attachThumbnail(Data([0x00]), to: entry.id) // Existing thumbnails are not replaced.
        store.flushPendingWrites()
        XCTAssertEqual(ClipboardStore(historyURL: url, pasteboard: board).items.first?.thumbnail, Data([0xFF, 0xD8, 0x00]))
    }
}
