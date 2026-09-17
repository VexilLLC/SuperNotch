import XCTest
import AppKit
@testable import SuperNotch

final class ClipboardTagTests: XCTestCase {
    private func entry(_ text: String, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), createdAt: Date(), kind: .text, text: text, payload: nil, paths: [], isPinned: pinned, sourceAppName: "Fixture Editor")
    }

    @MainActor func testTagsPersistSearchAndPreserveOriginalCopy() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = entry(" rgba(10, 20, 30, 0.5) ")
        try JSONEncoder().encode([original, entry("discard")]).write(to: url)
        let store = ClipboardStore(historyURL: url, pasteboard: board)
        XCTAssertEqual(store.items[0].tagNames, [])
        XCTAssertTrue(store.setTags([" Design ", "design", "Review"], for: original))
        XCTAssertEqual(store.items[0].tagNames, ["Design", "Review"])
        XCTAssertTrue(store.items[0].matchesSearch("fixture", tag: "DESIGN"))
        XCTAssertTrue(store.items[0].matchesSearch("review"))
        XCTAssertFalse(store.items[0].matchesSearch("", tag: "absent"))
        store.copy(store.items[0])
        XCTAssertEqual(board.string(forType: .string), original.text)
        store.clearUnpinned()
        XCTAssertEqual(store.items.count, 1)
        store.flushPendingWrites()
        XCTAssertEqual(ClipboardStore(historyURL: url, pasteboard: board).items, store.items)
    }

    @MainActor func testTagValidationAndSharedProtectionLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixtures = (0..<30).map { entry("pinned \($0)", pinned: true) } + [entry("extra")]
        try JSONEncoder().encode(fixtures).write(to: url)
        let store = ClipboardStore(historyURL: url, pasteboard: board)
        XCTAssertFalse(store.setTags(["new"], for: fixtures[30]))
        XCTAssertTrue(store.setTags(["new"], for: fixtures[0]))
        store.togglePin(fixtures[1])
        XCTAssertTrue(store.setTags(["new"], for: fixtures[30]))
        XCTAssertFalse(store.setTags(["bad,tag"], for: fixtures[30]))
        XCTAssertFalse(store.setTags((0..<9).map { "tag\($0)" }, for: fixtures[30]))
        XCTAssertEqual(store.items[30].tagNames, ["new"])
        XCTAssertTrue(store.setTags([], for: fixtures[30]))
        store.delete(fixtures[30])
        XCTAssertFalse(store.setTags(["gone"], for: fixtures[30]))
    }

    @MainActor func testRecaptureRetainsTagsAndCorruptArchiveIsPreserved() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = folder.appendingPathComponent("history.json")
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var tagged = entry("keep")
        tagged.tags = ["Saved"]
        try JSONEncoder().encode([tagged]).write(to: url)
        let store = ClipboardStore(historyURL: url, pasteboard: board)
        store.startMonitoring(); defer { store.stopMonitoring() }
        board.clearContents(); board.setString("keep", forType: .string)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(store.items, [tagged])
        store.stopMonitoring()
        store.flushPendingWrites()
        let broken = Data("not a history archive".utf8)
        try broken.write(to: url)
        let corrupt = ClipboardStore(historyURL: url, pasteboard: board)
        corrupt.isPaused = false
        corrupt.startMonitoring(); defer { corrupt.stopMonitoring() }
        board.clearContents(); board.setString("new", forType: .string)
        try await Task.sleep(for: .milliseconds(1100))
        corrupt.clearUnpinned()
        corrupt.flushPendingWrites()
        XCTAssertEqual(try Data(contentsOf: url), broken)
        XCTAssertTrue(corrupt.items.isEmpty)
    }
}
