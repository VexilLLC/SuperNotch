import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import SuperNotch

final class CoreTests: XCTestCase {
    func testQuickRingSelectionUsesClockwiseWedgesAndCenterDeadZone() {
        let center = CGPoint(x: 200, y: 200)
        XCTAssertFalse(QuickRingSelectionGeometry.hasMovedEnough(from: center, to: CGPoint(x: 221, y: 200)))
        XCTAssertTrue(QuickRingSelectionGeometry.hasMovedEnough(from: center, to: CGPoint(x: 222, y: 200)))
        XCTAssertNil(QuickRingSelectionGeometry.segmentIndex(for: center, around: center))
        XCTAssertNil(QuickRingSelectionGeometry.segmentIndex(for: CGPoint(x: 200, y: 245), around: center))
        XCTAssertEqual(QuickRingSelectionGeometry.segmentIndex(for: CGPoint(x: 200, y: 300), around: center), 0)
        XCTAssertEqual(QuickRingSelectionGeometry.segmentIndex(for: CGPoint(x: 287, y: 250), around: center), 1)
        XCTAssertEqual(QuickRingSelectionGeometry.segmentIndex(for: CGPoint(x: 287, y: 150), around: center), 2)
        XCTAssertEqual(QuickRingSelectionGeometry.segmentIndex(for: CGPoint(x: 200, y: 100), around: center), 3)
        XCTAssertEqual(QuickRingSelectionGeometry.segmentIndex(for: CGPoint(x: 113, y: 150), around: center), 4)
        XCTAssertEqual(QuickRingSelectionGeometry.segmentIndex(for: CGPoint(x: 113, y: 250), around: center), 5)
    }

    func testQuickRingShortcutReleaseCommitsOnlyAHighlightedAction() {
        let slots: [RingAction] = [.shelf, .clipboard, .screenshot, .focus, .basket, .workspace]
        XCTAssertNil(QuickRingController.actionForShortcutRelease(isHolding: true, highlightedIndex: nil, slots: slots))
        XCTAssertNil(QuickRingController.actionForShortcutRelease(isHolding: false, highlightedIndex: 1, slots: slots))
        XCTAssertEqual(QuickRingController.actionForShortcutRelease(isHolding: true, highlightedIndex: 1, slots: slots), .clipboard)
        XCTAssertEqual(QuickRingController.actionForShortcutRelease(isHolding: true, highlightedIndex: 5, slots: slots), .workspace)
    }

    @MainActor func testClipboardPrivacyPersistenceAndPins() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("history.json")
        let board = NSPasteboard(name: NSPasteboard.Name("SuperNotchTests-\(UUID())"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardStore(historyURL: url, pasteboard: board)
        store.startMonitoring(); defer { store.stopMonitoring() }
        board.clearContents(); board.setString("https://example.com", forType: .string)
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(store.items.count, 1)
        let first = try XCTUnwrap(store.items.first)
        XCTAssertEqual(first.kind, .link)
        store.togglePin(first)
        board.clearContents(); board.setString("https://example.com", forType: .string)
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(store.items.count, 1); XCTAssertTrue(store.items[0].isPinned)
        board.clearContents(); board.setString("private secret", forType: .string)
        board.setString("1", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(store.items.count, 1)
        board.clearContents(); board.setString("temporary note", forType: .string)
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(store.items.count, 2)
        store.clearUnpinned()
        XCTAssertEqual(store.items.count, 1)
        store.flushPendingWrites()
        XCTAssertEqual(ClipboardStore(historyURL: url, pasteboard: board).items, store.items)
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(saved.contains("private secret"))
        store.copy(first); XCTAssertEqual(board.string(forType: .string), "https://example.com")
    }

    @MainActor func testClipboardLegacyHistoryAndSourceMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        let board = NSPasteboard(name: NSPasteboard.Name("SuperNotchMigration-\(UUID())"))
        defer { board.releaseGlobally() }
        let legacy: [[String: Any]] = [["id": UUID().uuidString, "createdAt": 0.0, "kind": "text", "text": "Original pinned note", "paths": [], "isPinned": true]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let restored = ClipboardStore(historyURL: url, pasteboard: board)
        XCTAssertEqual(restored.items.count, 1)
        let entry = try XCTUnwrap(restored.items.first)
        XCTAssertTrue(entry.isPinned)
        XCTAssertNil(entry.sourceAppName)
        XCTAssertNil(entry.sourceBundleIdentifier)
        let current = ClipboardEntry(id: UUID(), createdAt: Date(), kind: .text, text: "Source metadata roundtrip", payload: nil, paths: [], isPinned: false, sourceAppName: "Fixture Editor", sourceBundleIdentifier: "test.fixture.editor")
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(decoded, current)
    }

    func testImageConversionPreservesInputAndGeometry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<48 { for x in 0..<64 { bitmap.setColor(x < 32 ? NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1) : NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: x, y: y) } }
        let original = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])); try original.write(to: source)
        for type: UTType in [.png, .jpeg, .tiff, .heic] {
            let output = folder.appendingPathComponent("out.\(type.preferredFilenameExtension!)")
            try CaptureTransforms.convert(from: source, to: output, type: type)
            let result = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: output)))
            XCTAssertEqual(result.pixelsWide, 64); XCTAssertEqual(result.pixelsHigh, 48)
            if type == .jpeg { let color = try XCTUnwrap(result.colorAt(x: 50, y: 20)?.usingColorSpace(.deviceRGB)); XCTAssertGreaterThan(color.redComponent, 0.9); XCTAssertGreaterThan(color.greenComponent, 0.9) }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testCommandOutputErrorsAndBoundedStorage() async throws {
        let model = CommandToolsModel()
        model.command = "printf stdout-check; printf stderr-check >&2; exit 7"
        model.run()
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(100)); if !model.running { break } }
        XCTAssertFalse(model.running); XCTAssertTrue(model.output.contains("stdout-check")); XCTAssertTrue(model.output.contains("stderr-check")); XCTAssertTrue(model.output.contains("status 7"))
        model.command = "yes bounded-output | head -n 20000"
        model.run()
        for _ in 0..<50 { try await Task.sleep(for: .milliseconds(100)); if !model.running { break } }
        XCTAssertLessThan(model.output.count, 100_100); XCTAssertTrue(model.output.contains("truncated"))
        model.command = "sleep 20"; model.run(); try await Task.sleep(for: .milliseconds(100)); model.cancel()
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(100)); if !model.running { break } }
        XCTAssertFalse(model.running)
    }
}
