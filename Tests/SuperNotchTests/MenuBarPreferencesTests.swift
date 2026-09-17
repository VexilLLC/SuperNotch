import XCTest
@testable import SuperNotch

@MainActor
final class MenuBarPreferencesTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "MenuBarPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaultsShowOnlyTheLogoWithEveryModuleListed() {
        let preferences = MenuBarPreferences(defaults: makeDefaults())
        XCTAssertEqual(preferences.items.map(\.id), MenuBarModuleID.allCases)
        XCTAssertEqual(preferences.visibleItems.map(\.id), [.logo])
        XCTAssertTrue(preferences.showsLabels)
        XCTAssertTrue(preferences.colorful)
    }

    func testVisibilityStyleAndOrderPersist() {
        let defaults = makeDefaults()
        let preferences = MenuBarPreferences(defaults: defaults)
        preferences.setVisible(.cpu, true)
        preferences.setStyle(.cpu, .graph)
        preferences.setStyle(.battery, .graph) // unsupported, ignored
        preferences.move(.cpu, by: -5)
        preferences.showsLabels = false

        let reloaded = MenuBarPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.items.first?.id, .cpu)
        XCTAssertEqual(reloaded.setting(for: .cpu), MenuBarModuleSetting(id: .cpu, visible: true, style: .graph, format: nil))
        XCTAssertEqual(reloaded.setting(for: .battery).style, .value)
        XCTAssertFalse(reloaded.showsLabels)

        reloaded.reset()
        XCTAssertEqual(reloaded.items, MenuBarPreferences.defaultItems)
    }

    func testSanitizeDropsUnknownAndDuplicateEntriesAndAppendsNewModules() throws {
        let json = #"[{"id":"network","visible":true,"style":"graph"},{"id":"future","visible":true},{"id":"network","visible":false},{"id":"cpu","visible":true,"style":"sparkles"}]"#
        let items = MenuBarPreferences.sanitize(Data(json.utf8))
        XCTAssertEqual(items.count, MenuBarModuleID.allCases.count)
        XCTAssertEqual(items[0], MenuBarModuleSetting(id: .network, visible: true, style: .graph, format: .bytesPerSecond))
        XCTAssertEqual(items[1], MenuBarModuleSetting(id: .cpu, visible: true, style: .value))
        XCTAssertFalse(try XCTUnwrap(items.first { $0.id == .logo }).visible)
        XCTAssertEqual(MenuBarPreferences.sanitize(Data("not json".utf8)), MenuBarPreferences.defaultItems)
    }

    func testRatesAndBytesStayShort() {
        XCTAssertEqual(MenuBarFormat.rate(nil), "—")
        XCTAssertEqual(MenuBarFormat.rate(512), "512B/s")
        XCTAssertEqual(MenuBarFormat.rate(12_400), "12K/s")
        XCTAssertEqual(MenuBarFormat.rate(1_450_000), "1.4M/s")
        XCTAssertEqual(MenuBarFormat.rate(58_000_000), "58M/s")
        XCTAssertEqual(MenuBarFormat.bytes(71_200_000_000), "71.2G")
        XCTAssertEqual(MenuBarFormat.bytes(512_000_000_000), "512G")
    }

    func testFormatsPersistAndInvalidFormatsFallBack() {
        let defaults = makeDefaults()
        let preferences = MenuBarPreferences(defaults: defaults)
        XCTAssertEqual(preferences.setting(for: .network).resolvedFormat, .bytesPerSecond)
        preferences.setFormat(.network, .bitsPerSecond)
        preferences.setFormat(.memory, .free)
        preferences.setFormat(.cpu, .bitsPerSecond) // CPU has no formats, ignored

        let reloaded = MenuBarPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.setting(for: .network).resolvedFormat, .bitsPerSecond)
        XCTAssertEqual(reloaded.setting(for: .memory).resolvedFormat, .free)
        XCTAssertNil(reloaded.setting(for: .cpu).resolvedFormat)

        let items = MenuBarPreferences.sanitize(Data(#"[{"id":"storage","visible":true,"format":"bitsPerSecond"}]"#.utf8))
        XCTAssertEqual(items[0].resolvedFormat, .free)
    }

    func testPanelSectionsCanBeHiddenAndReset() {
        let defaults = makeDefaults()
        let preferences = MenuBarPreferences(defaults: defaults)
        XCTAssertTrue(MenuBarPanelSection.allCases.allSatisfy(preferences.showsPanelSection))
        preferences.setPanelSection(.apps, visible: false)
        XCTAssertFalse(MenuBarPreferences(defaults: defaults).showsPanelSection(.apps))
        preferences.reset()
        XCTAssertTrue(MenuBarPreferences(defaults: defaults).showsPanelSection(.apps))
    }

    func testBitRatesUseDecimalNetworkUnits() {
        XCTAssertEqual(MenuBarFormat.rate(100, bits: true), "800bps")
        XCTAssertEqual(MenuBarFormat.rate(12_500, bits: true), "100Kbps")
        XCTAssertEqual(MenuBarFormat.rate(1_200_000, bits: true), "9.6Mbps")
        XCTAssertEqual(MenuBarFormat.rate(12_500_000, bits: true), "100Mbps")
        XCTAssertEqual(MenuBarFormat.detailedRate(1_400_000, bits: true), "11.2 Mbps")
        XCTAssertEqual(MenuBarFormat.detailedRate(nil, bits: true), "—")
    }
}
