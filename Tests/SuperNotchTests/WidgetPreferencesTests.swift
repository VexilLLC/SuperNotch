import XCTest
@testable import SuperNotch

@MainActor
final class WidgetPreferencesTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "SuperNotch.WidgetPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testDefaultsAndPersistenceRoundTrip() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "widgets"

        let preferences = WidgetPreferences(defaults: defaults, key: key)
        XCTAssertEqual(preferences.visibleWidgets, IslandWidgetID.allCases)

        preferences.setVisible(widget: .agenda, false)
        preferences.move(.system, by: -2)
        XCTAssertEqual(preferences.visibleWidgets, [.system, .notes, .focus, .usage])
        XCTAssertEqual(defaults.array(forKey: key) as? [Int], [3, 0, 2, 4])

        let restored = WidgetPreferences(defaults: defaults, key: key)
        XCTAssertEqual(restored.visibleWidgets, [.system, .notes, .focus, .usage])
        XCTAssertFalse(restored.contains(.agenda))
        XCTAssertTrue(restored.contains(.notes))
    }

    func testVisibilityNeverAllowsEmptySelectionAndResetRestoresAll() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WidgetPreferences(defaults: defaults, key: "widgets")

        for widget in IslandWidgetID.allCases {
            preferences.setVisible(widget: widget, false)
        }
        XCTAssertEqual(preferences.visibleWidgets, [.usage])

        preferences.setVisible(widget: .usage, false)
        XCTAssertEqual(preferences.visibleWidgets, [.usage])

        preferences.ensureVisible(.notes)
        XCTAssertEqual(preferences.visibleWidgets, [.usage, .notes])
        preferences.reset()
        XCTAssertEqual(preferences.visibleWidgets, IslandWidgetID.allCases)
        XCTAssertEqual(defaults.array(forKey: "widgets") as? [Int], [0, 1, 2, 3, 4])
    }

    func testMalformedAndLegacyValuesAreSanitizedWithoutTouchingStandardDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "widgets"
        defaults.set([0, 0, 99, 2, -1], forKey: key)

        let sanitized = WidgetPreferences(defaults: defaults, key: key)
        XCTAssertEqual(sanitized.visibleWidgets, [.notes, .focus])

        defaults.set([true, 1.5, 2.0], forKey: key)
        let malformedNumbers = WidgetPreferences(defaults: defaults, key: key)
        XCTAssertEqual(malformedNumbers.visibleWidgets, [.focus])

        defaults.set("not an array", forKey: key)
        let malformed = WidgetPreferences(defaults: defaults, key: key)
        XCTAssertEqual(malformed.visibleWidgets, IslandWidgetID.allCases)

        let standardKey = "SuperNotch.WidgetPreferencesTests.standard.\(UUID().uuidString)"
        XCTAssertNil(UserDefaults.standard.object(forKey: standardKey))
    }

    func testMoveClampsAtEdgesAndIgnoresHiddenWidgets() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WidgetPreferences(defaults: defaults, key: "widgets")

        preferences.move(.notes, by: -50)
        XCTAssertEqual(preferences.visibleWidgets, IslandWidgetID.allCases)
        preferences.move(.notes, by: 50)
        XCTAssertEqual(preferences.visibleWidgets, [.agenda, .focus, .system, .usage, .notes])
        preferences.move(.notes, by: Int.max)
        XCTAssertEqual(preferences.visibleWidgets, [.agenda, .focus, .system, .usage, .notes])
        preferences.move(.notes, by: Int.min)
        XCTAssertEqual(preferences.visibleWidgets, IslandWidgetID.allCases)
        preferences.setVisible(widget: .focus, false)
        preferences.move(.focus, by: -1)
        XCTAssertEqual(preferences.visibleWidgets, [.notes, .agenda, .system, .usage])
    }
}
