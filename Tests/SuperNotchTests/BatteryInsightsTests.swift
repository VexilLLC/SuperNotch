import XCTest
@testable import SuperNotch

final class BatteryInsightsTests: XCTestCase {
    func testHealthPercentageIsRoundedAndBounded() {
        XCTAssertEqual(BatteryInsightsMath.healthPercent(fullChargeCapacity: 7_386, designCapacity: 8_579), 86)
        XCTAssertEqual(BatteryInsightsMath.healthPercent(fullChargeCapacity: 1_100, designCapacity: 1_000), 100)
        XCTAssertNil(BatteryInsightsMath.healthPercent(fullChargeCapacity: nil, designCapacity: 1_000))
        XCTAssertNil(BatteryInsightsMath.healthPercent(fullChargeCapacity: 500, designCapacity: 0))
    }

    func testPowerApplicationParserGroupsHelpersAndIgnoresDaemons() throws {
        let sample = """
          101  12.5  200000 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
          102   8.0  300000 /Applications/ChatGPT.app/Contents/Frameworks/ChatGPT Helper.app/Contents/MacOS/Helper --type=renderer
          103  20.0  100000 /Applications/Safari.app/Contents/MacOS/Safari
          104  80.0   50000 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
        """

        let apps = BatteryInsightsMath.powerApplications(fromPSOutput: sample)

        XCTAssertEqual(apps.map(\.name), ["ChatGPT", "Safari"])
        let chatGPT = try XCTUnwrap(apps.first)
        XCTAssertEqual(chatGPT.cpuPercent, 20.5, accuracy: 0.001)
        XCTAssertEqual(chatGPT.memoryBytes, 500_000 * 1_024)
    }

    func testImpactUsesCPUAndMemorySignals() {
        XCTAssertEqual(BatteryInsightsMath.impact(cpuPercent: 40, memoryBytes: 0), .high)
        XCTAssertEqual(BatteryInsightsMath.impact(cpuPercent: 8, memoryBytes: 2 * 1_073_741_824), .elevated)
        XCTAssertEqual(BatteryInsightsMath.impact(cpuPercent: 1, memoryBytes: 100 * 1_024 * 1_024), .low)
    }

    func testTemperatureIsReadAsHundredthsOfACelsiusDegree() throws {
        XCTAssertEqual(try XCTUnwrap(BatteryInsightsMath.temperatureCelsius(raw: 3_121)), 31.21, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(BatteryInsightsMath.temperatureCelsius(raw: 3_031)), 30.31, accuracy: 0.001)
        XCTAssertNil(BatteryInsightsMath.temperatureCelsius(raw: nil))
        XCTAssertNil(BatteryInsightsMath.temperatureCelsius(raw: 0))
        XCTAssertNil(BatteryInsightsMath.temperatureCelsius(raw: 900_000))
    }
}
