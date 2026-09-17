import XCTest
@testable import SuperNotch

final class SpotifyDockMachOTests: XCTestCase {
    func testInsertsAndDetectsHelperLoadCommand() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let binary = syntheticMachO(contentOffset: 2048)
        XCTAssertFalse(try SpotifyDockMachO.containsHelper(in: binary))
        try binary.write(to: file)

        try SpotifyDockMachO.insertHelper(into: file)
        let patched = try Data(contentsOf: file)
        XCTAssertTrue(try SpotifyDockMachO.containsHelper(in: patched))
        XCTAssertEqual(readUInt32(patched, at: 16), 2)
        XCTAssertGreaterThan(readUInt32(patched, at: 20), 24)
    }

    func testRejectsUnsupportedAndCrowdedBinaries() throws {
        XCTAssertThrowsError(try SpotifyDockMachO.containsHelper(in: Data(count: 64)))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try syntheticMachO(contentOffset: 64).write(to: file)
        XCTAssertThrowsError(try SpotifyDockMachO.insertHelper(into: file)) { error in
            XCTAssertEqual(error as? SpotifyDockMachOError, .insufficientHeaderSpace)
        }
    }

    private func syntheticMachO(contentOffset: UInt32) -> Data {
        var data = Data(count: 4096)
        writeUInt32(&data, at: 0, value: 0xFEED_FACF)
        writeUInt32(&data, at: 16, value: 1)
        writeUInt32(&data, at: 20, value: 24)
        writeUInt32(&data, at: 32, value: 0x2)
        writeUInt32(&data, at: 36, value: 24)
        writeUInt32(&data, at: 40, value: contentOffset)
        writeUInt32(&data, at: 48, value: contentOffset + 256)
        return data
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(0) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
    }

    private func writeUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8)) }
    }
}
