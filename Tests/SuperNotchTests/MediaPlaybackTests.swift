import XCTest
@testable import SuperNotch

final class MediaPlaybackTests: XCTestCase {
    func testParsesSpotifyNumbersFromDotAndCommaLocales() throws {
        XCTAssertEqual(try XCTUnwrap(MediaController.parseMediaNumber("52.351")), 52.351, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(MediaController.parseMediaNumber("52,351")), 52.351, accuracy: 0.0001)
        XCTAssertEqual(MediaController.parseMediaNumber(" 195232 "), 195_232)
        XCTAssertNil(MediaController.parseMediaNumber("not a number"))
    }
}
