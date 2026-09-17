import XCTest
import ChargeLimitCore
@testable import SuperNotch

final class ChargeLimitTests: XCTestCase {
    func testChargingIsHeldAtLimitAndResumesBelowHysteresis() {
        let config = ChargeLimitConfiguration(enabled: true, limit: 80)
        XCTAssertFalse(ChargeLimitPolicy.shouldInhibit(configuration: config, batteryPercent: 79, currentlyInhibited: false))
        XCTAssertTrue(ChargeLimitPolicy.shouldInhibit(configuration: config, batteryPercent: 80, currentlyInhibited: false))
        XCTAssertTrue(ChargeLimitPolicy.shouldInhibit(configuration: config, batteryPercent: 93, currentlyInhibited: false))
        // Held charge drifts down: keep holding until three points below the limit.
        XCTAssertTrue(ChargeLimitPolicy.shouldInhibit(configuration: config, batteryPercent: 78, currentlyInhibited: true))
        XCTAssertFalse(ChargeLimitPolicy.shouldInhibit(configuration: config, batteryPercent: 77, currentlyInhibited: true))
    }

    func testDisabledFullOrUnknownBatteryNeverHoldsCharge() {
        XCTAssertFalse(ChargeLimitPolicy.shouldInhibit(configuration: .init(enabled: false, limit: 80), batteryPercent: 95, currentlyInhibited: true))
        XCTAssertFalse(ChargeLimitPolicy.shouldInhibit(configuration: .init(enabled: true, limit: 100), batteryPercent: 100, currentlyInhibited: true))
        XCTAssertFalse(ChargeLimitPolicy.shouldInhibit(configuration: .init(enabled: true, limit: 80), batteryPercent: nil, currentlyInhibited: true))
    }

    func testLightIsGreenOnlyWhileHeldOnAdapter() {
        let config = ChargeLimitConfiguration(enabled: true, limit: 80)
        XCTAssertEqual(ChargeLimitPolicy.led(configuration: config, inhibited: true, adapterConnected: true), .green)
        XCTAssertEqual(ChargeLimitPolicy.led(configuration: config, inhibited: true, adapterConnected: false), .system)
        XCTAssertEqual(ChargeLimitPolicy.led(configuration: config, inhibited: false, adapterConnected: true), .system)
        var noLight = config
        noLight.controlsLED = false
        XCTAssertEqual(ChargeLimitPolicy.led(configuration: noLight, inhibited: true, adapterConnected: true), .system)
    }

    func testSleepPausesChargingUnlessAllowed() {
        XCTAssertTrue(ChargeLimitPolicy.shouldPauseForSleep(configuration: .init(enabled: true, limit: 80), currentlyInhibited: false))
        XCTAssertFalse(ChargeLimitPolicy.shouldPauseForSleep(configuration: .init(enabled: true, limit: 80, chargesDuringSleep: true), currentlyInhibited: false))
        XCTAssertFalse(ChargeLimitPolicy.shouldPauseForSleep(configuration: .init(enabled: true, limit: 80), currentlyInhibited: true))
        XCTAssertFalse(ChargeLimitPolicy.shouldPauseForSleep(configuration: .init(enabled: false, limit: 80), currentlyInhibited: false))
    }

    func testConfigurationClampsLimitAndDecodesMissingFields() throws {
        XCTAssertEqual(ChargeLimitConfiguration(enabled: true, limit: 10).limit, 50)
        XCTAssertEqual(ChargeLimitConfiguration(enabled: true, limit: 140).limit, 100)
        let decoded = try JSONDecoder().decode(ChargeLimitConfiguration.self, from: Data(#"{"enabled":true,"limit":3}"#.utf8))
        XCTAssertEqual(decoded, ChargeLimitConfiguration(enabled: true, limit: 50, controlsLED: true, chargesDuringSleep: false))
    }

    func testSchemesUseDocumentedSMCValues() {
        XCTAssertEqual(ChargingControlScheme.chte.inhibitBytes, [1, 0, 0, 0])
        XCTAssertEqual(ChargingControlScheme.chte.enableBytes, [0, 0, 0, 0])
        XCTAssertEqual(ChargingControlScheme.ch0b.inhibitBytes, [2])
        XCTAssertEqual(MagSafeLED.green.rawValue, 3)
        XCTAssertEqual(SMCConnection.fourCharCode("CHTE"), 0x4348_5445)
    }

    func testInstallScriptQuotesPathsAndVerifiesHash() {
        let script = ChargeLimiter.installScript(source: "/Users/me/Apps/Super Notch's.app/Contents/MacOS/SuperNotchChargeHelper", sha256: "abc123", userID: 501)
        XCTAssertTrue(script.contains(#"'/Users/me/Apps/Super Notch'\''s.app/Contents/MacOS/SuperNotchChargeHelper'"#))
        XCTAssertTrue(script.contains("shasum -a 256 -c"))
        XCTAssertTrue(script.contains("-o 501 -g staff"))
        XCTAssertTrue(script.contains("launchctl bootstrap system '/Library/LaunchDaemons/org.supernotch.chargehelper.plist'"))
        XCTAssertTrue(ChargeLimiter.uninstallScript().contains("restore"))
    }

    func testLaunchDaemonRunsHelperAtLoadAndRestartsAfterCrash() throws {
        let data = try ChargeLimitPaths.launchDaemonPlistData()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "org.supernotch.chargehelper")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [ChargeLimitPaths.helperExecutable, "daemon"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
    }
}

final class ChargeLimitMaintenanceTests: XCTestCase {
    private let config = ChargeLimitConfiguration(enabled: true, limit: 80, sailingRange: 5)

    private func decide(_ percent: Int?, pluggedIn: Bool = true, inhibited: Bool = false, discharge: Bool = false, topUp: Bool = false, adapterControl: Bool = true, configuration: ChargeLimitConfiguration? = nil) -> ChargeLimitAction {
        ChargeLimitPolicy.decide(configuration: configuration ?? config, batteryPercent: percent, pluggedIn: pluggedIn, currentlyInhibited: inhibited, dischargeActive: discharge, topUpActive: topUp, supportsAdapterControl: adapterControl)
    }

    func testSailingRangeControlsWhenChargingResumes() {
        XCTAssertTrue(decide(76, inhibited: true).inhibitCharging)
        XCTAssertFalse(decide(75, inhibited: true).inhibitCharging)
        XCTAssertEqual(config.resumeLevel, 75)
        XCTAssertEqual(ChargeLimitConfiguration(enabled: true, limit: 80, sailingRange: 90).sailingRange, 20)
    }

    func testDischargeSwitchesAdapterOffOnlyWhilePluggedInAndAboveLimit() {
        let plugged = decide(95, discharge: true)
        XCTAssertTrue(plugged.discharging)
        XCTAssertTrue(plugged.disableAdapter)
        XCTAssertTrue(plugged.inhibitCharging)

        let unplugged = decide(95, pluggedIn: false, discharge: true)
        XCTAssertTrue(unplugged.discharging)
        XCTAssertFalse(unplugged.disableAdapter)

        let done = decide(80, discharge: true)
        XCTAssertTrue(done.dischargeFinished)
        XCTAssertFalse(done.disableAdapter)
        XCTAssertTrue(done.inhibitCharging, "charge is held at the limit once discharge finishes")
    }

    func testDischargeNeverRunsWithoutAdapterControlOrWhenDisabled() {
        XCTAssertTrue(decide(95, discharge: true, adapterControl: false).dischargeFinished)
        XCTAssertFalse(decide(95, discharge: true, adapterControl: false).disableAdapter)
        XCTAssertEqual(decide(95, discharge: true, configuration: .init(enabled: false, limit: 80)), .normal)
        XCTAssertEqual(decide(nil, discharge: true), .normal)
    }

    func testTopUpChargesToFullThenFinishesAndOverridesDischarge() {
        let charging = decide(90, inhibited: true, discharge: true, topUp: true)
        XCTAssertTrue(charging.toppingUp)
        XCTAssertFalse(charging.inhibitCharging)
        XCTAssertFalse(charging.disableAdapter)
        XCTAssertTrue(charging.dischargeFinished)

        let full = decide(100, topUp: true)
        XCTAssertTrue(full.topUpFinished)
        XCTAssertTrue(full.inhibitCharging)
    }

    func testRequestsExpireAndDoNotRepeatOnceFinished() {
        let now = Date()
        let requested = now.addingTimeInterval(-60)
        XCTAssertTrue(ChargeLimitPolicy.isRequestActive(requested, finishedFor: nil, now: now))
        XCTAssertFalse(ChargeLimitPolicy.isRequestActive(requested, finishedFor: requested, now: now))
        XCTAssertFalse(ChargeLimitPolicy.isRequestActive(now.addingTimeInterval(-49 * 3_600), finishedFor: nil, now: now))
        XCTAssertFalse(ChargeLimitPolicy.isRequestActive(nil, finishedFor: nil, now: now))
    }

    func testAdapterKeysUseBattValues() {
        XCTAssertEqual(AdapterControlKey.allCases.map(\.rawValue), ["CH0I", "CH0J", "CHIE"])
        XCTAssertEqual(AdapterControlKey.ch0j.disableByte, 0x01)
        XCTAssertEqual(AdapterControlKey.chie.disableByte, 0x08)
    }

    func testOlderHelperStatusStillDecodes() throws {
        let json = #"{"helperVersion":1,"enabled":true,"chargingInhibited":true,"pausedForSleep":false,"batteryPercent":99,"limit":80,"updatedAt":0,"adapterConnected":true,"supportsLED":true,"scheme":"CHTE"}"#
        let status = try JSONDecoder().decode(ChargeLimitStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.helperVersion, 1)
        XCTAssertFalse(status.supportsDischarge)
        XCTAssertFalse(status.discharging)
        XCTAssertLessThan(status.helperVersion, ChargeLimitPaths.helperVersion)
    }
}
