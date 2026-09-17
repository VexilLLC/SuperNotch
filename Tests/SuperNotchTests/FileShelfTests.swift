import XCTest
@testable import SuperNotch

final class FileShelfTests: XCTestCase {
    @MainActor func testRetentionPinsAndPersistencePreserveOriginals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["expired.txt", "pinned.txt", "recent.txt"].map { directory.appendingPathComponent($0) }
        let contents = Data("Original contents must survive shelf operations".utf8)
        for url in urls { try contents.write(to: url) }
        let storage = directory.appendingPathComponent("shelf.json")
        var time = Date(timeIntervalSince1970: 100_000)
        let shelf = FileShelfStore(storageURL: storage, now: { time }, retentionDuration: { 3600 }, monitorRetention: false)
        shelf.add(urls: Array(urls.prefix(2)))
        let pinned = try XCTUnwrap(shelf.items.first { $0.path == urls[1].path })
        shelf.togglePin(pinned)
        time.addTimeInterval(3599)
        shelf.purgeExpired()
        XCTAssertEqual(shelf.items.count, 2)
        time.addTimeInterval(1)
        shelf.purgeExpired()
        XCTAssertEqual(shelf.items.map(\.id), [pinned.id])
        shelf.add(urls: [urls[2]])
        let restored = FileShelfStore(storageURL: storage, now: { time }, retentionDuration: { 3600 }, monitorRetention: false)
        XCTAssertEqual(restored.items.count, 2)
        XCTAssertTrue(try XCTUnwrap(restored.items.first { $0.id == pinned.id }).pinned)
        restored.togglePin(pinned)
        XCTAssertEqual(restored.items.count, 1, "Unpinning an expired reference applies retention")
        restored.clearUnpinned()
        XCTAssertTrue(restored.items.isEmpty)
        for url in urls { XCTAssertEqual(try Data(contentsOf: url), contents) }
    }

    @MainActor func testStartupExpirationAndForeverPolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("keep".utf8).write(to: file)
        let storage = directory.appendingPathComponent("shelf.json")
        let old = Date(timeIntervalSince1970: 100_000)
        let shelf = FileShelfStore(storageURL: storage, now: { old }, retentionDuration: { nil }, monitorRetention: false)
        shelf.add(urls: [file, file])
        XCTAssertEqual(shelf.items.count, 1)
        let future = old.addingTimeInterval(1_000_000)
        let forever = FileShelfStore(storageURL: storage, now: { future }, retentionDuration: { nil }, monitorRetention: false)
        XCTAssertEqual(forever.items.count, 1)
        let expiring = FileShelfStore(storageURL: storage, now: { future }, retentionDuration: { 3600 }, monitorRetention: false)
        XCTAssertTrue(expiring.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor func testRetentionWakeupExistsOnlyWhenAnItemCanExpire() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("keep".utf8).write(to: file)
        var duration: TimeInterval?
        let shelf = FileShelfStore(
            storageURL: directory.appendingPathComponent("shelf.json"),
            retentionDuration: { duration },
            monitorRetention: true
        )
        shelf.add(urls: [file])
        XCTAssertFalse(shelf.hasScheduledRetentionCheck, "Keep-until-removed needs no polling timer")
        duration = 3600
        shelf.retentionPolicyDidChange()
        XCTAssertTrue(shelf.hasScheduledRetentionCheck)
        duration = nil
        shelf.retentionPolicyDidChange()
        XCTAssertFalse(shelf.hasScheduledRetentionCheck)
    }
}
