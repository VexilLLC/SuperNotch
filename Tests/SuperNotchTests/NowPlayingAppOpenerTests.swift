import XCTest
@testable import SuperNotch

@MainActor
final class NowPlayingAppOpenerTests: XCTestCase {
    func testVisibleWindowIsOnlyRaisedAndActivated() {
        XCTAssertEqual(
            NowPlayingAppOpener.plan(isRunning: true, isHidden: false, hasVisibleWindow: true, hasMinimizedWindow: false),
            [.raiseWindow, .activate]
        )
    }

    func testHiddenAppIsUnhiddenFirst() {
        XCTAssertEqual(
            NowPlayingAppOpener.plan(isRunning: true, isHidden: true, hasVisibleWindow: true, hasMinimizedWindow: false),
            [.unhide, .raiseWindow, .activate]
        )
    }

    func testMinimizedWindowIsRestoredInsteadOfReopening() {
        XCTAssertEqual(
            NowPlayingAppOpener.plan(isRunning: true, isHidden: false, hasVisibleWindow: false, hasMinimizedWindow: true),
            [.unminimize, .raiseWindow, .activate]
        )
    }

    func testRunningAppWithNoWindowsIsReopened() {
        XCTAssertEqual(
            NowPlayingAppOpener.plan(isRunning: true, isHidden: true, hasVisibleWindow: false, hasMinimizedWindow: false),
            [.unhide, .reopen, .raiseWindow, .activate]
        )
    }

    func testAppThatIsNotRunningIsLaunched() {
        XCTAssertEqual(
            NowPlayingAppOpener.plan(isRunning: false, isHidden: false, hasVisibleWindow: false, hasMinimizedWindow: false),
            [.launch]
        )
    }

    func testUnknownPlayerReportsFailureSoCallersCanFallBack() {
        XCTAssertFalse(NowPlayingAppOpener.open(bundleIdentifier: nil))
        XCTAssertFalse(NowPlayingAppOpener.open(bundleIdentifier: ""))
        XCTAssertFalse(NowPlayingAppOpener.open(bundleIdentifier: "com.example.not.installed.\(UUID().uuidString)"))
    }
}

final class SpotifyToggleTests: XCTestCase {
    func testSpotifyIsOnlyHiddenWhenAlreadyInFront() {
        XCTAssertEqual(SpotifyDockManager.toggleAction(spotifyIsFrontmost: false), "focus")
        XCTAssertEqual(SpotifyDockManager.toggleAction(spotifyIsFrontmost: true), "toggle")
    }
}
