import XCTest
@testable import SuperNotch

final class IslandActivityTests: XCTestCase {
    @MainActor func testLatestActivityExpiryAndDismissal() async throws {
        var enabled = true
        let controller = IslandActivityController(isEnabled: { enabled }, onPresentationChange: {})
        let first = IslandActivity(title: "First", detail: "", symbol: "timer", kind: .focus)
        let second = IslandActivity(title: "Second", detail: "", symbol: "wifi", kind: .network)
        controller.present(first, duration: 0.05)
        controller.present(second, duration: 0.2)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.current, second, "The older expiration cannot remove its replacement")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(controller.current)
        enabled = false
        controller.present(first)
        XCTAssertNil(controller.current)
        enabled = true
        controller.present(first)
        controller.dismiss()
        XCTAssertNil(controller.current)
    }
    private func baseline() -> IslandObservation {
        IslandObservation(hasBattery: true, battery: 80, charging: false, connected: true, capsLock: false, shelfIDs: [], focusRunning: false, focusRemaining: 1500)
    }
    func testSilentBaselineAndChangeOnlyActivities() {
        var detector = IslandActivityDetector()
        var observation = baseline()
        XCTAssertNil(detector.observe(observation))
        XCTAssertNil(detector.observe(observation))
        observation.capsLock = true
        XCTAssertEqual(detector.observe(observation)?.detail, "On")
        XCTAssertNil(detector.observe(observation))
        observation.capsLock = false
        XCTAssertEqual(detector.observe(observation)?.detail, "Off")
        observation.connected = false
        XCTAssertEqual(detector.observe(observation)?.title, "You're offline")
        observation.connected = true
        XCTAssertEqual(detector.observe(observation)?.title, "Connection restored")
    }
    func testBatteryThresholdAndAbsentBattery() {
        var detector = IslandActivityDetector()
        var observation = baseline()
        _ = detector.observe(observation)
        observation.battery = 20
        XCTAssertEqual(detector.observe(observation)?.title, "Low battery")
        observation.battery = 19
        XCTAssertNil(detector.observe(observation))
        observation.charging = true
        XCTAssertEqual(detector.observe(observation)?.title, "Charging")
        observation.battery = 9
        XCTAssertNil(detector.observe(observation), "Charging must not trigger low-battery alerts")
        observation.hasBattery = false; observation.charging = false
        XCTAssertNil(detector.observe(observation))
    }
    func testShelfIdentityAndFocusCompletion() {
        var detector = IslandActivityDetector()
        var observation = baseline()
        let initial = UUID()
        observation.shelfIDs = [initial]
        XCTAssertNil(detector.observe(observation), "Restored files are not new additions")
        observation.shelfIDs = [UUID()]
        XCTAssertEqual(detector.observe(observation)?.title, "File added", "Same count with a new ID still counts as an addition")
        observation.shelfIDs = []
        XCTAssertNil(detector.observe(observation))
        observation.focusRunning = true
        XCTAssertEqual(detector.observe(observation)?.title, "Focus started")
        observation.focusRunning = false; observation.focusRemaining = 100
        XCTAssertEqual(detector.observe(observation)?.title, "Focus paused")
        observation.focusRunning = true
        _ = detector.observe(observation)
        observation.focusRunning = false; observation.focusRemaining = 0
        XCTAssertEqual(detector.observe(observation)?.title, "Focus complete")
    }
}
