import XCTest
@testable import SuperNotch

final class SystemPerformanceTests: XCTestCase {
    func testCPUPercentagesUseDeltasAndIncludeNiceInUser() throws {
        let previous = [
            SystemCPUTime(user: 100, system: 50, idle: 850, nice: 0),
            SystemCPUTime(user: 200, system: 100, idle: 700, nice: 0)
        ]
        let current = [
            SystemCPUTime(user: 150, system: 70, idle: 880, nice: 10),
            SystemCPUTime(user: 240, system: 120, idle: 740, nice: 0)
        ]

        let usage = try XCTUnwrap(SystemPerformanceMath.cpuPercentages(previous: previous, current: current))

        XCTAssertEqual(usage.user, 100.0 / 210.0 * 100.0, accuracy: 0.000_001)
        XCTAssertEqual(usage.system, 40.0 / 210.0 * 100.0, accuracy: 0.000_001)
        XCTAssertEqual(usage.idle, 70.0 / 210.0 * 100.0, accuracy: 0.000_001)
        XCTAssertEqual(usage.user + usage.system + usage.idle, 100.0, accuracy: 0.000_001)
    }

    func testCPUPercentagesReturnNilForBaselineZeroIntervalOrCounterReset() {
        let zero = SystemCPUTime(user: 0, system: 0, idle: 0)
        let nonZero = SystemCPUTime(user: 3, system: 2, idle: 5)

        XCTAssertNil(SystemPerformanceMath.cpuPercentages(previous: [], current: [nonZero]))
        XCTAssertNil(SystemPerformanceMath.cpuPercentages(previous: [zero], current: [zero]))
        XCTAssertNil(SystemPerformanceMath.cpuPercentages(
            previous: [SystemCPUTime(user: 10, system: 5, idle: 20)],
            current: [SystemCPUTime(user: 9, system: 6, idle: 25)]
        ))
        XCTAssertNil(SystemPerformanceMath.cpuPercentages(
            previous: [nonZero],
            current: [nonZero, nonZero]
        ))
    }

    func testStorageNormalizationBoundsAvailableSpaceAndRejectsZeroCapacity() throws {
        let usage = try XCTUnwrap(SystemPerformanceMath.normalizedStorage(capacity: 1_000, available: 250))
        XCTAssertEqual(usage.capacity, 1_000)
        XCTAssertEqual(usage.available, 250)
        XCTAssertEqual(usage.used, 750)
        XCTAssertEqual(usage.usedFraction, 0.75, accuracy: 0.000_001)

        let overCapacity = try XCTUnwrap(SystemPerformanceMath.normalizedStorage(capacity: 1_000, available: 2_000))
        XCTAssertEqual(overCapacity.available, 1_000)
        XCTAssertEqual(overCapacity.usedFraction, 0, accuracy: 0.000_001)

        let negative = try XCTUnwrap(SystemPerformanceMath.normalizedStorage(capacity: 1_000, available: -1))
        XCTAssertEqual(negative.available, 0)
        XCTAssertEqual(negative.usedFraction, 1, accuracy: 0.000_001)
        XCTAssertNil(SystemPerformanceMath.normalizedStorage(capacity: 0, available: 0))
        XCTAssertNil(SystemPerformanceMath.normalizedStorage(capacity: -1, available: 0))
    }

    func testMemoryNormalizationBoundsCounters() throws {
        let memory = try XCTUnwrap(SystemPerformanceMath.normalizedMemory(
            physical: 16_000,
            used: 20_000,
            wired: 4_000,
            compressed: -1
        ))
        XCTAssertEqual(memory.used, 16_000)
        XCTAssertEqual(memory.available, 0)
        XCTAssertEqual(memory.wired, 4_000)
        XCTAssertEqual(memory.compressed, 0)
        XCTAssertEqual(memory.usedFraction, 1)
        XCTAssertNil(SystemPerformanceMath.normalizedMemory(physical: 0, used: 0, wired: 0, compressed: 0))
    }

    func testDiskThroughputUsesCounterDeltasAndRejectsResets() throws {
        let previous = SystemDiskCounters(readBytes: 1_000, writtenBytes: 2_000)
        let current = SystemDiskCounters(readBytes: 5_000, writtenBytes: 8_000)
        let throughput = try XCTUnwrap(SystemPerformanceMath.diskThroughput(previous: previous, current: current, elapsed: 2))
        XCTAssertEqual(throughput.readBytesPerSecond, 2_000)
        XCTAssertEqual(throughput.writtenBytesPerSecond, 3_000)
        XCTAssertNil(SystemPerformanceMath.diskThroughput(previous: current, current: previous, elapsed: 2))
        XCTAssertNil(SystemPerformanceMath.diskThroughput(previous: previous, current: current, elapsed: 0))
    }

    func testPerCoreActivityReportsEachProcessorAndZeroesResets() throws {
        let previous = [
            SystemCPUTime(user: 10, system: 10, idle: 80),
            SystemCPUTime(user: 50, system: 0, idle: 50),
            SystemCPUTime(user: 5, system: 5, idle: 5)
        ]
        let current = [
            SystemCPUTime(user: 30, system: 20, idle: 150, nice: 0),
            SystemCPUTime(user: 50, system: 0, idle: 150),
            SystemCPUTime(user: 4, system: 5, idle: 10)
        ]
        let cores = try XCTUnwrap(SystemPerformanceMath.perCoreActivity(previous: previous, current: current))
        XCTAssertEqual(cores.count, 3)
        XCTAssertEqual(cores[0], 30.0, accuracy: 0.000_001)
        XCTAssertEqual(cores[1], 0, accuracy: 0.000_001)
        XCTAssertEqual(cores[2], 0, accuracy: 0.000_001)
        XCTAssertNil(SystemPerformanceMath.perCoreActivity(previous: previous, current: Array(current.prefix(2))))
    }

    func testMemoryNormalizationKeepsBreakdownWithinPhysicalMemory() throws {
        let memory = try XCTUnwrap(SystemPerformanceMath.normalizedMemory(
            physical: 8_000,
            used: 6_000,
            wired: 1_000,
            compressed: 500,
            app: 9_000,
            cached: -5,
            swapUsed: 12_000,
            pressure: .warning
        ))
        XCTAssertEqual(memory.app, 8_000)
        XCTAssertEqual(memory.cached, 0)
        XCTAssertEqual(memory.swapUsed, 12_000)
        XCTAssertEqual(memory.pressure, .warning)
        XCTAssertEqual(memory.fraction(memory.wired), 0.125, accuracy: 0.000_001)
    }

    func testNetworkThroughputExcludesTunnelsAndIgnoresResets() throws {
        let previous = [
            SystemNetworkCounters(name: "en0", receivedBytes: 1_000, sentBytes: 500),
            SystemNetworkCounters(name: "utun4", receivedBytes: 100, sentBytes: 100),
            SystemNetworkCounters(name: "en5", receivedBytes: 9_000, sentBytes: 9_000)
        ]
        let current = [
            SystemNetworkCounters(name: "en0", receivedBytes: 5_000, sentBytes: 1_500),
            SystemNetworkCounters(name: "utun4", receivedBytes: 4_100, sentBytes: 1_100),
            SystemNetworkCounters(name: "en5", receivedBytes: 10, sentBytes: 10),
            SystemNetworkCounters(name: "en7", receivedBytes: 1_000_000, sentBytes: 1_000_000)
        ]
        let result = try XCTUnwrap(SystemPerformanceMath.networkThroughput(previous: previous, current: current, elapsed: 2))
        XCTAssertEqual(result.total.receivedBytesPerSecond, 2_000)
        XCTAssertEqual(result.total.sentBytesPerSecond, 500)
        XCTAssertEqual(result.interfaces["utun4"]?.receivedBytesPerSecond, 2_000)
        XCTAssertEqual(result.interfaces["en5"], .zero)
        XCTAssertEqual(result.interfaces["en7"], .zero)
        XCTAssertNil(SystemPerformanceMath.networkThroughput(previous: previous, current: current, elapsed: 0))
        XCTAssertFalse(SystemPerformanceMath.countsTowardNetworkTotal("bridge100"))
        XCTAssertTrue(SystemPerformanceMath.countsTowardNetworkTotal("en0"))
    }

    func testHistoryAppendingIsBoundedAndSanitized() {
        var history: [Double] = []
        for value in 0..<75 { history = SystemPerformanceMath.appending(Double(value), to: history, capacity: 60) }
        XCTAssertEqual(history.count, 60)
        XCTAssertEqual(history.first, 15)
        XCTAssertEqual(history.last, 74)
        XCTAssertEqual(SystemPerformanceMath.appending(.nan, to: [], capacity: 3), [0])
    }

    func testNiceCeilingRoundsToReadableScale() {
        XCTAssertEqual(ActivityFormat.niceCeiling(0), 1)
        XCTAssertEqual(ActivityFormat.niceCeiling(0.7), 1)
        XCTAssertEqual(ActivityFormat.niceCeiling(130), 200)
        XCTAssertEqual(ActivityFormat.niceCeiling(2_100_000), 5_000_000)
        XCTAssertEqual(ActivityFormat.niceCeiling(10), 10)
    }

    func testAppResourcesGroupHelpersAndUseCPUTimeDeltas() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        let samples = [
            ProcessResourceSample(pid: 10, executablePath: chrome, cpuTimeNanoseconds: 3_000_000_000, memoryBytes: 300 * 1_048_576),
            ProcessResourceSample(pid: 11, executablePath: helper, cpuTimeNanoseconds: 1_000_000_000, memoryBytes: 200 * 1_048_576),
            ProcessResourceSample(pid: 12, executablePath: "/usr/libexec/daemon", cpuTimeNanoseconds: 9_000_000_000, memoryBytes: 900 * 1_048_576),
            ProcessResourceSample(pid: 13, executablePath: "/Applications/Notes.app/Contents/MacOS/Notes", cpuTimeNanoseconds: 50, memoryBytes: 1_048_576),
            ProcessResourceSample(pid: 14, executablePath: "/Applications/Reused.app/Contents/MacOS/Reused", cpuTimeNanoseconds: 10, memoryBytes: 200 * 1_048_576)
        ]
        let previous: [Int32: UInt64] = [10: 1_000_000_000, 11: 500_000_000, 12: 0, 14: 5_000_000_000]
        let apps = AppResourceMath.applications(previous: previous, current: samples, elapsedNanoseconds: 2_000_000_000)

        XCTAssertEqual(apps.map(\.name), ["Google Chrome", "Reused"])
        XCTAssertEqual(apps[0].cpuPercent, 125, accuracy: 0.000_001)
        XCTAssertEqual(apps[0].memoryBytes, 500 * 1_048_576)
        XCTAssertEqual(apps[1].cpuPercent, 0, accuracy: 0.000_001)
        XCTAssertNil(AppResourceMath.bundlePath(forExecutable: "/usr/bin/swift"))
        XCTAssertEqual(AppResourceMath.bundlePath(forExecutable: helper), "/Applications/Google Chrome.app")
    }

    func testInterfaceClassificationPrefersSystemTypes() {
        XCTAssertEqual(SystemInterfaceKind.classify(name: "en0", pathType: nil, wifiNames: ["en0"]), .wifi)
        XCTAssertEqual(SystemInterfaceKind.classify(name: "en8", pathType: .wiredEthernet, wifiNames: []), .ethernet)
        XCTAssertEqual(SystemInterfaceKind.classify(name: "utun3", pathType: nil, wifiNames: []), .tunnel)
        XCTAssertEqual(SystemInterfaceKind.classify(name: "awdl0", pathType: nil, wifiNames: []), .wirelessDirect)
        XCTAssertEqual(SystemInterfaceKind.classify(name: "bridge100", pathType: nil, wifiNames: []), .virtual)
    }
}
