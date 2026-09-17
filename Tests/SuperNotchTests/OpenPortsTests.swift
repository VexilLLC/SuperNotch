import XCTest
@testable import SuperNotch

final class OpenPortsTests: XCTestCase {
    private func sample(
        port: UInt16,
        pid: Int32 = 501,
        address: String = "127.0.0.1",
        processName: String = "node",
        executablePath: String? = "/opt/homebrew/bin/node",
        isOwnProcess: Bool = true
    ) -> OpenPortSample {
        OpenPortSample(port: port, pid: pid, address: address, processName: processName,
                       executablePath: executablePath, isOwnProcess: isOwnProcess)
    }

    func testDualStackSocketsOfOneProcessMergeIntoOneEntry() throws {
        let entries = OpenPortMath.entries(from: [
            sample(port: 6379, pid: 3113, address: "::1", processName: "redis-server", executablePath: "/opt/homebrew/Cellar/redis/8.0.2/bin/redis-server"),
            sample(port: 6379, pid: 3113, address: "127.0.0.1", processName: "redis-server", executablePath: "/opt/homebrew/Cellar/redis/8.0.2/bin/redis-server"),
            sample(port: 6379, pid: 3113, address: "127.0.0.1", processName: "redis-server", executablePath: "/opt/homebrew/Cellar/redis/8.0.2/bin/redis-server")
        ])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.name, "redis-server")
        XCTAssertEqual(entry.addresses, ["127.0.0.1", "::1"])
        XCTAssertTrue(entry.isLocalOnly)
        XCTAssertEqual(entry.detail, "127.0.0.1, ::1 · local only")
        XCTAssertEqual(entry.id, "3113.6379")
    }

    func testTwoProcessesOnTheSamePortStaySeparateAndSortByPort() {
        let entries = OpenPortMath.entries(from: [
            sample(port: 8080, pid: 42),
            sample(port: 3000, pid: 7),
            sample(port: 8080, pid: 9)
        ])
        XCTAssertEqual(entries.map(\.port), [3000, 8080, 8080])
        XCTAssertEqual(entries.map(\.pid), [7, 9, 42])
    }

    func testNamesComeFromTheExecutableSoHelpersKeepTheirOwnName() {
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        XCTAssertEqual(OpenPortMath.displayName(executablePath: helper, processName: "Code Helper (Pl"), "Code Helper (Plugin)")
        XCTAssertEqual(OpenPortMath.displayName(executablePath: nil, processName: "rapportd"), "rapportd")
        XCTAssertEqual(OpenPortMath.displayName(executablePath: "", processName: "rapportd"), "rapportd")
    }

    func testEntryKeepsTheParentAppForItsIconAndSubtitle() throws {
        let helper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let entry = try XCTUnwrap(OpenPortMath.entries(from: [
            sample(port: 22495, pid: 29615, processName: "Code Helper (Pl", executablePath: helper)
        ]).first)
        XCTAssertEqual(entry.appPath, "/Applications/Visual Studio Code.app")
        XCTAssertEqual(entry.appName, "Visual Studio Code")

        let plain = try XCTUnwrap(OpenPortMath.entries(from: [sample(port: 3000)]).first)
        XCTAssertNil(plain.appPath)
        XCTAssertNil(plain.appName)
    }

    func testWildcardAndRoutableBindsAreNotLocalOnly() throws {
        let wildcard = try XCTUnwrap(OpenPortMath.entries(from: [
            sample(port: 56401, address: "0.0.0.0", processName: "rapportd", executablePath: "/usr/libexec/rapportd"),
            sample(port: 56401, address: "::", processName: "rapportd", executablePath: "/usr/libexec/rapportd")
        ]).first)
        XCTAssertFalse(wildcard.isLocalOnly)
        XCTAssertEqual(wildcard.detail, "0.0.0.0, :: · on your network")

        let routable = try XCTUnwrap(OpenPortMath.entries(from: [sample(port: 5000, address: "192.168.1.24")]).first)
        XCTAssertFalse(routable.isLocalOnly)
    }

    func testLoopbackClassification() {
        XCTAssertTrue(OpenPortMath.isLoopback("127.0.0.1"))
        XCTAssertTrue(OpenPortMath.isLoopback("127.94.0.2"))
        XCTAssertTrue(OpenPortMath.isLoopback("::1"))
        XCTAssertFalse(OpenPortMath.isLoopback("0.0.0.0"))
        XCTAssertFalse(OpenPortMath.isLoopback("192.168.1.24"))
        XCTAssertTrue(OpenPortMath.isWildcard("0.0.0.0"))
        XCTAssertTrue(OpenPortMath.isWildcard("::"))
        XCTAssertFalse(OpenPortMath.isWildcard("127.0.0.1"))
    }

    func testWebURLPrefersLocalhostAndBracketsIPv6() throws {
        let loopback = try XCTUnwrap(OpenPortMath.entries(from: [sample(port: 3000)]).first)
        XCTAssertEqual(loopback.webURL?.absoluteString, "http://localhost:3000")

        let wildcard = try XCTUnwrap(OpenPortMath.entries(from: [sample(port: 8080, address: "0.0.0.0")]).first)
        XCTAssertEqual(wildcard.webURL?.absoluteString, "http://localhost:8080")

        let routable = try XCTUnwrap(OpenPortMath.entries(from: [sample(port: 8080, address: "192.168.1.24")]).first)
        XCTAssertEqual(routable.webURL?.absoluteString, "http://192.168.1.24:8080")

        let sixDigits = try XCTUnwrap(OpenPortMath.entries(from: [sample(port: 8080, address: "fe80::1")]).first)
        XCTAssertEqual(sixDigits.webURL?.absoluteString, "http://[fe80::1]:8080")
    }

    func testAddressOrderIsStableAcrossScans() {
        XCTAssertEqual(OpenPortMath.sortAddresses(["::1", "0.0.0.0", "::", "127.0.0.1"]), ["0.0.0.0", "127.0.0.1", "::", "::1"])
    }

    func testEmptySamplesProduceNoEntries() {
        XCTAssertTrue(OpenPortMath.entries(from: []).isEmpty)
    }

    @MainActor func testPortsSectionStartsCollapsedAndRemembersItsState() {
        let name = "OpenPortsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let preferences = MenuBarPreferences(defaults: defaults)
        XCTAssertFalse(preferences.portsExpanded)
        preferences.portsExpanded = true
        XCTAssertTrue(MenuBarPreferences(defaults: defaults).portsExpanded)

        preferences.reset()
        XCTAssertFalse(MenuBarPreferences(defaults: defaults).portsExpanded)
    }

    func testPortsModuleAndPanelSectionAreConfigurable() {
        XCTAssertTrue(MenuBarModuleID.ports.needsPortScanning)
        XCTAssertFalse(MenuBarModuleID.ports.needsPerformanceSampling)
        XCTAssertFalse(MenuBarModuleID.cpu.needsPortScanning)
        XCTAssertEqual(MenuBarModuleID.ports.styles, [.value])
        XCTAssertTrue(MenuBarModuleID.ports.formats.isEmpty)
        XCTAssertTrue(MenuBarPanelSection.allCases.contains(.ports))
    }
}
