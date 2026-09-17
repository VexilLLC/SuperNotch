import XCTest
@testable import SuperNotch

final class BasketCollectionTests: XCTestCase {
    @MainActor func testLegacyMigrationCollectionsMergeAndOriginalPreservation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["one.txt", "two.txt"].map { directory.appendingPathComponent($0) }
        let original = Data("Never move or delete these originals".utf8)
        for url in urls { try original.write(to: url) }
        let storage = directory.appendingPathComponent("shelf.json")
        let legacy = urls.enumerated().map { index, url in
            ShelfItem(id: UUID(), path: url.path, bookmark: nil, pinned: index == 0, addedAt: Date())
        }
        let legacyBytes = try JSONEncoder().encode(legacy)
        try legacyBytes.write(to: storage)
        let store = FileShelfStore(storageURL: storage, retentionDuration: { nil }, monitorRetention: false)
        XCTAssertEqual(store.activeItems.count, 2)
        XCTAssertEqual(store.items.map(\.id), legacy.map(\.id))
        XCTAssertEqual(store.baskets, [.main])
        XCTAssertTrue(store.createBasket(name: "Work"))
        let work = store.activeBasketID
        XCTAssertTrue(store.activeItems.isEmpty)
        XCTAssertEqual(try Data(contentsOf: storage.appendingPathExtension("legacy-backup")), legacyBytes)
        store.add(urls: [urls[0], urls[0]])
        XCTAssertEqual(store.activeItems.count, 1)
        XCTAssertEqual(store.items.count, 3, "Same original may be referenced by different baskets")
        XCTAssertTrue(store.createBasket(name: "Later"))
        let later = store.activeBasketID
        store.add(urls: [urls[1]], to: work)
        XCTAssertTrue(store.activeItems.isEmpty, "A delayed drop retains its captured destination")
        XCTAssertEqual(store.basketItemCount(work), 2)
        store.removeActiveBasket()
        XCTAssertFalse(store.baskets.contains { $0.id == later })
        store.selectBasket(work)
        let first = try XCTUnwrap(store.activeItems.first { $0.path == urls[0].path })
        store.move(first, to: ShelfBasket.mainID)
        XCTAssertEqual(store.basketItemCount(ShelfBasket.mainID), 2)
        XCTAssertEqual(store.basketItemCount(work), 1)
        XCTAssertTrue(try XCTUnwrap(store.items.first { $0.id == legacy[0].id }).pinned)
        let second = try XCTUnwrap(store.activeItems.first)
        store.togglePin(second)
        store.clearUnpinned()
        XCTAssertEqual(store.activeItems.count, 1)
        store.removeActiveBasket()
        XCTAssertEqual(store.baskets.count, 1)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(store.items.allSatisfy(\.pinned), "Merging duplicate references preserves either pin")
        XCTAssertTrue(store.renameActiveBasket(name: "Inbox"))
        let restored = FileShelfStore(storageURL: storage, retentionDuration: { nil }, monitorRetention: false)
        XCTAssertEqual(restored.activeBasket.name, "Inbox")
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertTrue(restored.items.allSatisfy(\.pinned))
        for url in urls { XCTAssertEqual(try Data(contentsOf: url), original) }
    }

    @MainActor func testActiveBasketPersistenceScopedClearAndMissingDestinationFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("keep".utf8).write(to: file)
        let storage = directory.appendingPathComponent("shelf.json")
        let store = FileShelfStore(storageURL: storage, retentionDuration: { nil }, monitorRetention: false)
        store.add(urls: [file])
        XCTAssertTrue(store.createBasket(name: "Second"))
        let second = store.activeBasketID
        store.add(urls: [file])
        let restored = FileShelfStore(storageURL: storage, retentionDuration: { nil }, monitorRetention: false)
        XCTAssertEqual(restored.activeBasketID, second)
        restored.clearUnpinned()
        XCTAssertTrue(restored.activeItems.isEmpty)
        XCTAssertEqual(restored.basketItemCount(ShelfBasket.mainID), 1)
        restored.removeActiveBasket()
        XCTAssertTrue(restored.createBasket(name: "Third"))
        let third = restored.activeBasketID
        XCTAssertTrue(restored.renameBasket(ShelfBasket.mainID, name: "Inbox"))
        XCTAssertEqual(restored.activeBasketID, third)
        restored.add(urls: [file], to: second)
        XCTAssertTrue(restored.activeItems.isEmpty)
        XCTAssertEqual(restored.basketItemCount(ShelfBasket.mainID), 1)
        XCTAssertTrue(restored.createBasket(name: "Fourth"))
        let fourth = restored.activeBasketID
        restored.removeBasket(third)
        XCTAssertEqual(restored.activeBasketID, fourth, "A merge retains a newer selection in another window")
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    @MainActor func testBasketLimitsAndUnreadableArchiveAreNonDestructive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("shelf.json")
        let store = FileShelfStore(storageURL: storage, retentionDuration: { nil }, monitorRetention: false)
        XCTAssertFalse(store.createBasket(name: "  "))
        XCTAssertFalse(store.createBasket(name: String(repeating: "a", count: 41)))
        XCTAssertFalse(store.createBasket(name: "two\nlines"))
        XCTAssertFalse(store.canRemoveBasket)
        for index in 1...11 { XCTAssertTrue(store.createBasket(name: "Basket \(index)")) }
        XCTAssertFalse(store.canCreateBasket)
        XCTAssertFalse(store.createBasket(name: "Too many"))
        XCTAssertEqual(store.baskets.count, 12)
        let corrupt = Data("Not a valid shelf archive".utf8)
        try corrupt.write(to: storage)
        let protected = FileShelfStore(storageURL: storage, retentionDuration: { 1 }, monitorRetention: false)
        XCTAssertNotNil(protected.message)
        XCTAssertFalse(protected.createBasket(name: "Must not overwrite"))
        protected.clearUnpinned()
        protected.save()
        XCTAssertEqual(try Data(contentsOf: storage), corrupt)
    }
}
