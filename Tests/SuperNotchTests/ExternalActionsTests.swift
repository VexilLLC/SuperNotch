import Foundation
import XCTest
@testable import SuperNotch

final class ExternalActionsTests: XCTestCase {
    func testParsesEverySupportedAuthorityAction() throws {
        for action in ExternalAction.allCases {
            let parsed = ExternalActionParser.parse(action.url)
            XCTAssertEqual(parsed, action, "Expected \(action.rawValue) to parse")
        }
    }

    func testAcceptsPathStyleAndCaseInsensitiveSchemeAndHost() {
        XCTAssertEqual(ExternalActionParser.parse(URL(string: "SUPERNOTCH://SHELF")!), .shelf)
        XCTAssertEqual(ExternalActionParser.parse(URL(string: "supernotch:///clipboard")!), .clipboard)
        XCTAssertEqual(ExternalActionParser.parse(URL(string: "supernotch://agenda/")!), .agenda)
    }

    func testRejectsUnknownOrStructuredURLs() {
        let rejected = [
            "https://shelf",
            "supernotch://unknown",
            "supernotch://shelf/extra",
            "supernotch:///shelf/extra",
            "supernotch://shelf?source=alfred",
            "supernotch://shelf#fragment",
            "supernotch://user@shelf",
            "supernotch://shelf:443",
            "supernotch:///",
            "supernotch://",
            "supernotch://shelf%2Fextra",
            "supernotch://%73helf",
            "supernotch://shel%66",
            "supernotch:///shel%66",
            "supernotch:////shelf"
        ]

        for value in rejected {
            XCTAssertNil(ExternalActionParser.parse(URL(string: value)!), "Expected rejection: \(value)")
        }
    }

    @MainActor
    func testDispatcherOnlyInvokesHandlerForSupportedURLs() {
        var received: [ExternalAction] = []
        let dispatcher = ExternalActionDispatcher { received.append($0) }

        XCTAssertTrue(dispatcher.dispatch(URL(string: "supernotch://notes")!))
        XCTAssertFalse(dispatcher.dispatch(URL(string: "supernotch://notes?unsafe=true")!))
        XCTAssertEqual(received, [.notes])
    }

    func testCanonicalURLsContainNoArguments() {
        for action in ExternalAction.allCases {
            let url = action.url
            XCTAssertEqual(url.scheme, ExternalAction.scheme)
            XCTAssertEqual(url.host, action.rawValue)
            XCTAssertNil(url.query)
            XCTAssertNil(url.fragment)
            XCTAssertTrue(url.path.isEmpty || url.path == "/")
        }
    }
}
