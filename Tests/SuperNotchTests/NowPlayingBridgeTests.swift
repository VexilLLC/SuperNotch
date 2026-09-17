import XCTest
@testable import SuperNotch

final class NowPlayingBridgeTests: XCTestCase {
    func testDecodesHelperLineAndPrefersParentApp() throws {
        let line = #"{"elapsed":12.5,"artist":"KALIL","rate":1,"bundle":"com.apple.WebKit.GPU","parentBundle":"com.apple.Safari","artworkKey":"A1","title":"TABOUT","duration":206.86,"playing":true,"album":"","timestamp":1789483724.7,"artwork":"AAEC"}"#
        let snapshot = try XCTUnwrap(NowPlayingSnapshot.decode(line: Data(line.utf8)))
        XCTAssertEqual(snapshot.title, "TABOUT")
        XCTAssertEqual(snapshot.duration ?? 0, 206.86, accuracy: 0.001)
        XCTAssertTrue(snapshot.playing)
        XCTAssertEqual(snapshot.appBundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(snapshot.artwork, "AAEC")
    }

    func testDecodesIdleSnapshotWithoutMetadata() throws {
        let snapshot = try XCTUnwrap(NowPlayingSnapshot.decode(line: Data(#"{"playing":false}"#.utf8)))
        XCTAssertNil(snapshot.title)
        XCTAssertFalse(snapshot.playing)
        XCTAssertNil(snapshot.appBundleIdentifier)
    }

    func testRejectsMalformedLine() {
        XCTAssertNil(NowPlayingSnapshot.decode(line: Data("not json".utf8)))
        XCTAssertNil(NowPlayingSnapshot.decode(line: Data(#"{"title":"Missing playing flag"}"#.utf8)))
    }
}
