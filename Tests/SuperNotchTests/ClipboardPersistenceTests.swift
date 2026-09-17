import XCTest
import AppKit
@testable import SuperNotch

final class ClipboardPersistenceTests: XCTestCase {
    @MainActor func testLegacyInlinePayloadMigratesToLazyExternalFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let historyURL = folder.appendingPathComponent("clipboard-history.json")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let payload = Data(repeating: 0xA5, count: 2 * 1024 * 1024)
        let entry = ClipboardEntry(
            id: UUID(), createdAt: Date(), kind: .image, text: "", payload: payload,
            payloadType: NSPasteboard.PasteboardType.png.rawValue,
            paths: [], isPinned: false
        )
        let legacyArchive = try JSONEncoder().encode([entry])
        try legacyArchive.write(to: historyURL)

        let store = ClipboardStore(historyURL: historyURL, pasteboard: board)
        XCTAssertEqual(store.items.first?.payload?.count, payload.count)
        store.flushPendingWrites()

        let metadata = try Data(contentsOf: historyURL)
        let persisted = try XCTUnwrap(JSONDecoder().decode([ClipboardEntry].self, from: metadata).first)
        let fileName = try XCTUnwrap(persisted.payloadFileName)
        let payloadURL = folder.appendingPathComponent("clipboard-payloads-v1").appendingPathComponent(fileName)

        XCTAssertNil(persisted.payload)
        XCTAssertNil(store.items.first?.payload, "A completed write releases the large in-memory payload")
        XCTAssertEqual(persisted.payloadByteCount, payload.count)
        XCTAssertEqual(persisted.payloadDigest, ClipboardEntry.digest(for: payload))
        XCTAssertEqual(try Data(contentsOf: payloadURL), payload)
        XCTAssertLessThan(metadata.count, 2_000, "Metadata writes must not base64-expand image bytes")
        XCTAssertGreaterThan(legacyArchive.count, payload.count)

        let restored = ClipboardStore(historyURL: historyURL, pasteboard: board)
        let restoredEntry = try XCTUnwrap(restored.items.first)
        XCTAssertNil(restoredEntry.payload, "External payloads stay lazy on launch")
        XCTAssertEqual(restoredEntry.payloadDigest, ClipboardEntry.digest(for: payload))
        restored.copy(restoredEntry)
        XCTAssertEqual(board.data(forType: .png), payload)
    }

    @MainActor func testMetadataEditDoesNotRewritePayloadAndDeleteCleansItUp() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let historyURL = folder.appendingPathComponent("clipboard-history.json")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let payload = Data(repeating: 0x4D, count: 256 * 1024)
        let entry = ClipboardEntry(
            id: UUID(), createdAt: Date(), kind: .richText, text: "Formatted text", payload: payload,
            payloadType: NSPasteboard.PasteboardType.rtf.rawValue,
            paths: [], isPinned: false
        )
        try JSONEncoder().encode([entry]).write(to: historyURL)
        let store = ClipboardStore(historyURL: historyURL, pasteboard: board)
        store.flushPendingWrites()

        let migrated = try XCTUnwrap(store.items.first)
        let fileName = try XCTUnwrap(migrated.payloadFileName)
        let payloadURL = folder.appendingPathComponent("clipboard-payloads-v1").appendingPathComponent(fileName)
        let before = try FileManager.default.attributesOfItem(atPath: payloadURL.path)[.modificationDate] as? Date

        XCTAssertTrue(store.setTags(["reference"], for: migrated))
        store.flushPendingWrites()
        let after = try FileManager.default.attributesOfItem(atPath: payloadURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "Changing metadata must not rewrite an unchanged payload")
        XCTAssertEqual(try Data(contentsOf: payloadURL), payload)

        store.delete(try XCTUnwrap(store.items.first))
        store.flushPendingWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadURL.path))
    }

    @MainActor func testLegacyExternalPayloadGetsFingerprintWithoutBecomingResident() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let historyURL = folder.appendingPathComponent("clipboard-history.json")
        let payloadFolder = folder.appendingPathComponent("clipboard-payloads-v1")
        let payloadURL = payloadFolder.appendingPathComponent("legacy.payload")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: payloadFolder, withIntermediateDirectories: true)

        let payload = Data(repeating: 0xC7, count: 512 * 1024)
        try payload.write(to: payloadURL)
        let entry = ClipboardEntry(
            id: UUID(), createdAt: Date(), kind: .image, text: "", payload: nil,
            payloadFileName: payloadURL.lastPathComponent, payloadByteCount: payload.count,
            payloadType: NSPasteboard.PasteboardType.png.rawValue,
            paths: [], isPinned: false
        )
        try JSONEncoder().encode([entry]).write(to: historyURL)

        let store = ClipboardStore(historyURL: historyURL, pasteboard: board)
        store.flushPendingWrites()

        let expected = ClipboardEntry.digest(for: payload)
        XCTAssertNil(store.items.first?.payload)
        XCTAssertEqual(store.items.first?.payloadDigest, expected)
        let persisted = try XCTUnwrap(JSONDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: historyURL)).first)
        XCTAssertNil(persisted.payload)
        XCTAssertEqual(persisted.payloadDigest, expected)
    }

    @MainActor func testMissingExternalImageDoesNotDestroyCurrentClipboard() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let historyURL = folder.appendingPathComponent("clipboard-history.json")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = ClipboardEntry(
            id: UUID(), createdAt: Date(), kind: .image, text: "", payload: nil,
            payloadFileName: "missing.payload", payloadByteCount: 128,
            payloadType: NSPasteboard.PasteboardType.png.rawValue,
            paths: [], isPinned: false
        )
        try JSONEncoder().encode([entry]).write(to: historyURL)
        board.clearContents()
        board.setString("keep me", forType: .string)

        let store = ClipboardStore(historyURL: historyURL, pasteboard: board)
        XCTAssertFalse(store.copy(try XCTUnwrap(store.items.first)))
        XCTAssertEqual(board.string(forType: .string), "keep me")
        XCTAssertEqual(store.status, "This image payload is missing from clipboard history.")
    }
}
