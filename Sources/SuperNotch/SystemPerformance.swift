import SwiftUI
import Foundation
import Darwin
import AppKit
import IOKit

/// A single logical processor's cumulative CPU tick counters.
///
/// The counters returned by `host_processor_info` are cumulative since boot,
/// so a useful percentage can only be calculated from two samples.
struct SystemCPUTime: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64

    init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64 = 0) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// CPU percentages over one elapsed sample interval. Values are in 0...100.
struct SystemCPUUsage: Equatable, Sendable {
    let user: Double
    let system: Double
    let idle: Double

    var active: Double { user + system }
    var total: Double { active }

    var userPercentage: Double { user }
    var systemPercentage: Double { system }
    var idlePercentage: Double { idle }
}

/// Startup-volume capacity and free space, in bytes.
struct SystemStorageUsage: Equatable, Sendable {
    let capacity: Int64
    let available: Int64

    var used: Int64 { max(0, capacity - available) }
    var usedFraction: Double {
        guard capacity > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(capacity)))
    }
    var availableFraction: Double { 1 - usedFraction }

    var capacityBytes: Int64 { capacity }
    var availableBytes: Int64 { available }
}

/// The kernel's memory-pressure level, as shown by Activity Monitor.
enum SystemMemoryPressure: Int, Equatable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Elevated"
        case .critical: return "Critical"
        }
    }
}

struct SystemMemoryUsage: Equatable, Sendable {
    let physical: Int64
    /// App + wired + compressed, matching Activity Monitor's "Memory Used".
    let used: Int64
    let wired: Int64
    let compressed: Int64
    var app: Int64 = 0
    var cached: Int64 = 0
    var swapUsed: Int64 = 0
    var pressure: SystemMemoryPressure?

    var available: Int64 { max(0, physical - used) }
    var usedFraction: Double {
        guard physical > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(physical)))
    }
    func fraction(_ bytes: Int64) -> Double {
        guard physical > 0 else { return 0 }
        return min(1, max(0, Double(bytes) / Double(physical)))
    }
}

struct SystemLoadAverages: Equatable, Sendable {
    let oneMinute: Double
    let fiveMinutes: Double
    let fifteenMinutes: Double
}

struct SystemDiskCounters: Equatable, Sendable {
    let readBytes: UInt64
    let writtenBytes: UInt64
}

struct SystemDiskThroughput: Equatable, Sendable {
    let readBytesPerSecond: Double
    let writtenBytesPerSecond: Double
}

/// Cumulative byte counters for one network interface.
struct SystemNetworkCounters: Equatable, Sendable {
    let name: String
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

struct SystemNetworkThroughput: Equatable, Sendable {
    let receivedBytesPerSecond: Double
    let sentBytesPerSecond: Double

    static let zero = SystemNetworkThroughput(receivedBytesPerSecond: 0, sentBytesPerSecond: 0)
}

/// Apple silicon groups logical processors into performance levels. Level 0 is
/// the performance cluster; efficiency cores are enumerated first.
struct SystemCoreLayout: Equatable, Sendable {
    let performance: Int
    let efficiency: Int

    var total: Int { performance + efficiency }
    var summary: String? {
        guard performance > 0, efficiency > 0 else { return nil }
        return "\(performance)P + \(efficiency)E"
    }
}

/// State used by the view to distinguish a first sample from an unavailable
/// native reading.
enum SystemPerformanceReadingState: Equatable {
    case stopped
    case collecting
    case available
    case unavailable
}

/// Pure, deterministic calculations used by the native sampler and tests.
enum SystemPerformanceMath {
    /// Computes aggregate CPU percentages from per-processor cumulative
    /// counters. A nil result means there is no valid elapsed interval: the
    /// first sample, a processor-count change, a counter reset/wrap, or a zero
    /// delta.
    static func cpuPercentages(previous: [SystemCPUTime], current: [SystemCPUTime]) -> SystemCPUUsage? {
        guard !current.isEmpty, previous.count == current.count else { return nil }

        var user: UInt64 = 0
        var system: UInt64 = 0
        var idle: UInt64 = 0
        var nice: UInt64 = 0

        for (old, new) in zip(previous, current) {
            guard let userDelta = checkedDelta(old.user, new.user),
                  let systemDelta = checkedDelta(old.system, new.system),
                  let idleDelta = checkedDelta(old.idle, new.idle),
                  let niceDelta = checkedDelta(old.nice, new.nice),
                  let nextUser = checkedAdd(user, userDelta),
                  let nextSystem = checkedAdd(system, systemDelta),
                  let nextIdle = checkedAdd(idle, idleDelta),
                  let nextNice = checkedAdd(nice, niceDelta) else {
                // Any field moving backwards is treated as a reset rather
                // than producing a misleading spike from unsigned wraparound.
                return nil
            }
            user = nextUser
            system = nextSystem
            idle = nextIdle
            nice = nextNice
        }

        guard let activeWithNice = checkedAdd(user, nice),
              let totalWithoutOverflow = checkedAdd(activeWithNice, system),
              let total = checkedAdd(totalWithoutOverflow, idle),
              total > 0 else {
            return nil
        }

        let scale = 100.0 / Double(total)
        return SystemCPUUsage(
            user: Double(activeWithNice) * scale,
            system: Double(system) * scale,
            idle: Double(idle) * scale
        )
    }

    /// Convenience overload for callers that already aggregate counters.
    static func cpuPercentages(previous: SystemCPUTime, current: SystemCPUTime) -> SystemCPUUsage? {
        cpuPercentages(previous: [previous], current: [current])
    }

    /// Active percentage (user + nice + system) for each logical processor.
    /// A processor whose counters reset or did not advance reports zero.
    static func perCoreActivity(previous: [SystemCPUTime], current: [SystemCPUTime]) -> [Double]? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        return zip(previous, current).map { old, new in
            guard let user = checkedDelta(old.user, new.user),
                  let system = checkedDelta(old.system, new.system),
                  let idle = checkedDelta(old.idle, new.idle),
                  let nice = checkedDelta(old.nice, new.nice) else { return 0 }
            let active = Double(user) + Double(system) + Double(nice)
            let total = active + Double(idle)
            guard total > 0 else { return 0 }
            return min(100, max(0, active / total * 100))
        }
    }

    /// Normalizes resource values into a bounded storage reading. Filesystem
    /// APIs can transiently return values outside their nominal range, so the
    /// available byte count is clamped before deriving the used fraction.
    static func normalizedStorage(capacity: Int64, available: Int64) -> SystemStorageUsage? {
        guard capacity > 0 else { return nil }
        let boundedAvailable = min(capacity, max(0, available))
        return SystemStorageUsage(capacity: capacity, available: boundedAvailable)
    }

    static func normalizedMemory(
        physical: Int64,
        used: Int64,
        wired: Int64,
        compressed: Int64,
        app: Int64 = 0,
        cached: Int64 = 0,
        swapUsed: Int64 = 0,
        pressure: SystemMemoryPressure? = nil
    ) -> SystemMemoryUsage? {
        guard physical > 0 else { return nil }
        func bound(_ value: Int64) -> Int64 { min(physical, max(0, value)) }
        return SystemMemoryUsage(
            physical: physical,
            used: bound(used),
            wired: bound(wired),
            compressed: bound(compressed),
            app: bound(app),
            cached: bound(cached),
            swapUsed: max(0, swapUsed),
            pressure: pressure
        )
    }

    static func diskThroughput(previous: SystemDiskCounters, current: SystemDiskCounters, elapsed: TimeInterval) -> SystemDiskThroughput? {
        guard elapsed > 0,
              let readDelta = checkedDelta(previous.readBytes, current.readBytes),
              let writeDelta = checkedDelta(previous.writtenBytes, current.writtenBytes) else { return nil }
        return SystemDiskThroughput(
            readBytesPerSecond: Double(readDelta) / elapsed,
            writtenBytesPerSecond: Double(writeDelta) / elapsed
        )
    }

    /// Per-interface and aggregate network rates. Interfaces that appear,
    /// disappear or reset their counters contribute zero for that interval.
    /// Tunnels, bridges and loopback are excluded from the aggregate because
    /// their traffic is already counted on the physical interface.
    static func networkThroughput(
        previous: [SystemNetworkCounters],
        current: [SystemNetworkCounters],
        elapsed: TimeInterval
    ) -> (total: SystemNetworkThroughput, interfaces: [String: SystemNetworkThroughput])? {
        guard elapsed > 0 else { return nil }
        let old = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var received = 0.0
        var sent = 0.0
        var interfaces: [String: SystemNetworkThroughput] = [:]
        for counters in current {
            guard let before = old[counters.name],
                  let receivedDelta = checkedDelta(before.receivedBytes, counters.receivedBytes),
                  let sentDelta = checkedDelta(before.sentBytes, counters.sentBytes) else {
                interfaces[counters.name] = .zero
                continue
            }
            let rate = SystemNetworkThroughput(
                receivedBytesPerSecond: Double(receivedDelta) / elapsed,
                sentBytesPerSecond: Double(sentDelta) / elapsed
            )
            interfaces[counters.name] = rate
            if countsTowardNetworkTotal(counters.name) {
                received += rate.receivedBytesPerSecond
                sent += rate.sentBytesPerSecond
            }
        }
        return (SystemNetworkThroughput(receivedBytesPerSecond: received, sentBytesPerSecond: sent), interfaces)
    }

    static func countsTowardNetworkTotal(_ name: String) -> Bool {
        let excluded = ["lo", "utun", "ipsec", "gif", "stf", "bridge", "vmenet", "anpi", "ppp", "tun", "tap"]
        return !excluded.contains { name.hasPrefix($0) }
    }

    /// Appends a value to a rolling history without letting it grow past `capacity`.
    static func appending(_ value: Double, to history: [Double], capacity: Int = ActivityMetrics.historyCapacity) -> [Double] {
        var next = history
        next.append(value.isFinite ? value : 0)
        if next.count > capacity { next.removeFirst(next.count - capacity) }
        return next
    }

    private static func checkedDelta(_ old: UInt64, _ new: UInt64) -> UInt64? {
        guard new >= old else { return nil }
        let (delta, overflow) = new.subtractingReportingOverflow(old)
        return overflow ? nil : delta
    }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }
}

// Short aliases keep the math surface convenient for focused tests and future
// callers without duplicating the model types.
typealias CPUTimeCounters = SystemCPUTime
typealias CPUUsagePercentages = SystemCPUUsage

/// One complete reading, produced off the main thread.
struct SystemPerformanceSample: Sendable {
    var cpuReadFailed = false
    var processorCount = 0
    var cpu: SystemCPUUsage?
    var cores: [Double] = []
    var memory: SystemMemoryUsage?
    var load: SystemLoadAverages?
    var gpu: Double?
    var disk: SystemDiskThroughput?
    var network: SystemNetworkThroughput?
    var interfaceRates: [String: SystemNetworkThroughput] = [:]
    var interfaceTotals: [String: SystemNetworkCounters] = [:]
    var thermalState: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = 0
}

/// Holds the previous cumulative counters. Only touched on the sampling queue.
private final class SystemPerformanceSampler: @unchecked Sendable {
    private var previousCPU: [SystemCPUTime]?
    private var previousDisk: (counters: SystemDiskCounters, time: TimeInterval)?
    private var previousNetwork: (counters: [SystemNetworkCounters], time: TimeInterval)?

    func reset() {
        previousCPU = nil
        previousDisk = nil
        previousNetwork = nil
    }

    func sample() -> SystemPerformanceSample {
        var result = SystemPerformanceSample()
        let now = ProcessInfo.processInfo.systemUptime
        result.uptime = now
        result.thermalState = ProcessInfo.processInfo.thermalState

        if let cpu = SystemPerformanceReader.cpuTimes(), !cpu.isEmpty {
            result.processorCount = cpu.count
            if let previousCPU {
                result.cpu = SystemPerformanceMath.cpuPercentages(previous: previousCPU, current: cpu)
                result.cores = SystemPerformanceMath.perCoreActivity(previous: previousCPU, current: cpu) ?? []
            }
            previousCPU = cpu
        } else {
            previousCPU = nil
            result.cpuReadFailed = true
        }

        result.memory = SystemPerformanceReader.memory()
        result.load = SystemPerformanceReader.loadAverages()
        result.gpu = SystemPerformanceReader.gpuUtilization()

        if let disk = SystemPerformanceReader.diskCounters() {
            if let previousDisk {
                result.disk = SystemPerformanceMath.diskThroughput(previous: previousDisk.counters, current: disk, elapsed: now - previousDisk.time)
            }
            previousDisk = (disk, now)
        } else {
            previousDisk = nil
        }

        if let network = SystemPerformanceReader.networkCounters() {
            result.interfaceTotals = Dictionary(network.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            if let previousNetwork,
               let rates = SystemPerformanceMath.networkThroughput(previous: previousNetwork.counters, current: network, elapsed: now - previousNetwork.time) {
                result.network = rates.total
                result.interfaceRates = rates.interfaces
            }
            previousNetwork = (network, now)
        } else {
            previousNetwork = nil
        }
        return result
    }
}

@MainActor
final class SystemPerformanceMonitor: ObservableObject {
    static let shared = SystemPerformanceMonitor()

    @Published private(set) var cpu: SystemCPUUsage?
    @Published private(set) var coreUsage: [Double] = []
    @Published private(set) var logicalProcessorCount: Int
    @Published private(set) var storage: SystemStorageUsage?
    @Published private(set) var memory: SystemMemoryUsage?
    @Published private(set) var loadAverages: SystemLoadAverages?
    @Published private(set) var diskThroughput: SystemDiskThroughput?
    @Published private(set) var networkThroughput: SystemNetworkThroughput?
    @Published private(set) var interfaceThroughput: [String: SystemNetworkThroughput] = [:]
    @Published private(set) var interfaceTotals: [String: SystemNetworkCounters] = [:]
    @Published private(set) var gpuPercentage: Double?
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var cpuSystemHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var diskReadHistory: [Double] = []
    @Published private(set) var diskWriteHistory: [Double] = []
    @Published private(set) var networkReceiveHistory: [Double] = []
    @Published private(set) var networkSendHistory: [Double] = []
    @Published private(set) var uptimeSeconds: TimeInterval = ProcessInfo.processInfo.systemUptime
    @Published private(set) var cpuState: SystemPerformanceReadingState = .stopped
    @Published private(set) var storageState: SystemPerformanceReadingState = .stopped
    @Published private(set) var lastCPUUpdate: Date?
    @Published private(set) var lastStorageUpdate: Date?

    let coreLayout: SystemCoreLayout?

    /// These aliases make the individual values easy to bind in compact UI.
    var cpuUserPercentage: Double? { cpu?.user }
    var cpuSystemPercentage: Double? { cpu?.system }
    var cpuIdlePercentage: Double? { cpu?.idle }
    var cpuActivePercentage: Double? { cpu?.active }
    var storageCapacity: Int64? { storage?.capacity }
    var storageAvailable: Int64? { storage?.available }
    var storageUsedFraction: Double? { storage?.usedFraction }

    var isRunning: Bool { cpuTimer != nil || storageTimer != nil }
    var isCollecting: Bool { cpuState == .collecting || storageState == .collecting }

    /// Sampling cadence for everything except storage.
    static let sampleInterval: TimeInterval = 2

    private let samplingQueue = DispatchQueue(label: "SuperNotch.system-performance", qos: .utility)
    private let sampler = SystemPerformanceSampler()
    private var cpuTimer: DispatchSourceTimer?
    private var storageTimer: DispatchSourceTimer?
    private var viewLeases = 0
    private var manuallyStarted = false
    private var samplingGeneration: UInt64 = 0
    private var lastStorageSampleAt: Date?
    private var lastSampleAt: Date?
    private var pendingStop: DispatchWorkItem?

    init() {
        logicalProcessorCount = max(1, ProcessInfo.processInfo.processorCount)
        coreLayout = SystemPerformanceReader.coreLayout(logicalCount: ProcessInfo.processInfo.processorCount)
    }

    /// Starts native sampling. Calling this more than once is safe.
    ///
    /// Processor, memory, GPU, disk and network are sampled every two seconds.
    /// Startup-volume storage is read immediately and then no more often than
    /// every thirty seconds.
    func start() {
        manuallyStarted = true
        beginSamplingIfNeeded()
    }

    /// Stops native sampling and clears the CPU baseline. A later start begins
    /// with a fresh baseline so a pause cannot create a false CPU spike.
    func stop() {
        manuallyStarted = false
        pendingStop?.cancel()
        pendingStop = nil
        stopSamplingIfUnowned()
    }

    /// Lease helpers used by views. They allow the shared monitor to serve the
    /// dashboard, the island and every Activity tab at the same time.
    func acquireViewLease() {
        viewLeases += 1
        pendingStop?.cancel()
        pendingStop = nil
        beginSamplingIfNeeded()
    }

    /// Releasing the last lease stops sampling after a short grace period, so
    /// switching between tabs keeps the charts' history instead of restarting.
    func releaseViewLease() {
        guard viewLeases > 0 else { return }
        viewLeases -= 1
        guard viewLeases == 0, !manuallyStarted else { return }
        pendingStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingStop = nil
                self?.stopSamplingIfUnowned()
            }
        }
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    private func beginSamplingIfNeeded() {
        guard cpuTimer == nil, storageTimer == nil else { return }

        // Keep recent history when sampling resumes quickly; otherwise a gap
        // would be drawn as if it were continuous.
        if let lastSampleAt, Date().timeIntervalSince(lastSampleAt) < 20 {
            // Retained.
        } else {
            clearHistory()
        }
        logicalProcessorCount = max(1, ProcessInfo.processInfo.processorCount)
        cpuState = cpu == nil ? .collecting : .available
        storageState = storage == nil ? .collecting : .available
        samplingGeneration &+= 1
        let generation = samplingGeneration
        let sampler = sampler

        let cpuTimer = DispatchSource.makeTimerSource(queue: samplingQueue)
        cpuTimer.schedule(deadline: .now(), repeating: Self.sampleInterval, leeway: .milliseconds(200))
        cpuTimer.setEventHandler { [weak self] in
            // GPU and disk readers bridge IOKit property dictionaries. Drain
            // those temporary objects at the end of every sample.
            let sample = autoreleasepool { sampler.sample() }
            Task { @MainActor [weak self] in
                self?.apply(sample, generation: generation)
            }
        }

        let storageTimer = DispatchSource.makeTimerSource(queue: samplingQueue)
        let storageDelay = lastStorageSampleAt.map { max(0, 30 - Date().timeIntervalSince($0)) } ?? 0
        storageTimer.schedule(deadline: .now() + storageDelay, repeating: .seconds(30), leeway: .seconds(2))
        storageTimer.setEventHandler { [weak self] in
            let sample = SystemPerformanceReader.startupVolumeStorage()
            Task { @MainActor [weak self] in
                self?.consumeStorage(sample, generation: generation)
            }
        }

        self.cpuTimer = cpuTimer
        self.storageTimer = storageTimer
        cpuTimer.resume()
        storageTimer.resume()
    }

    private func stopSamplingIfUnowned() {
        guard !manuallyStarted, viewLeases == 0 else { return }

        samplingGeneration &+= 1
        cpuTimer?.setEventHandler {}
        cpuTimer?.cancel()
        storageTimer?.setEventHandler {}
        storageTimer?.cancel()
        cpuTimer = nil
        storageTimer = nil
        let sampler = sampler
        samplingQueue.async { sampler.reset() }
        cpuState = .stopped
        storageState = .stopped
    }

    private func clearHistory() {
        cpu = nil
        coreUsage = []
        diskThroughput = nil
        networkThroughput = nil
        interfaceThroughput = [:]
        cpuHistory = []
        cpuSystemHistory = []
        memoryHistory = []
        gpuHistory = []
        diskReadHistory = []
        diskWriteHistory = []
        networkReceiveHistory = []
        networkSendHistory = []
        lastCPUUpdate = nil
    }

    private func apply(_ sample: SystemPerformanceSample, generation: UInt64) {
        guard cpuTimer != nil, generation == samplingGeneration else { return }
        let now = Date()
        lastSampleAt = now
        lastCPUUpdate = now
        uptimeSeconds = sample.uptime
        if thermalState != sample.thermalState { thermalState = sample.thermalState }
        if sample.processorCount > 0, sample.processorCount != logicalProcessorCount { logicalProcessorCount = sample.processorCount }

        if sample.cpuReadFailed {
            cpu = nil
            coreUsage = []
            cpuState = .unavailable
        } else if let usage = sample.cpu {
            cpu = usage
            coreUsage = sample.cores
            cpuHistory = SystemPerformanceMath.appending(usage.active, to: cpuHistory)
            cpuSystemHistory = SystemPerformanceMath.appending(usage.system, to: cpuSystemHistory)
            cpuState = .available
        } else if cpu == nil {
            cpuState = .collecting
        }

        memory = sample.memory
        if let memory = sample.memory {
            memoryHistory = SystemPerformanceMath.appending(memory.usedFraction * 100, to: memoryHistory)
        }
        loadAverages = sample.load
        gpuPercentage = sample.gpu
        if let gpu = sample.gpu { gpuHistory = SystemPerformanceMath.appending(gpu, to: gpuHistory) }

        if let disk = sample.disk {
            diskThroughput = disk
            diskReadHistory = SystemPerformanceMath.appending(disk.readBytesPerSecond, to: diskReadHistory)
            diskWriteHistory = SystemPerformanceMath.appending(disk.writtenBytesPerSecond, to: diskWriteHistory)
        }
        if let network = sample.network {
            networkThroughput = network
            interfaceThroughput = sample.interfaceRates
            networkReceiveHistory = SystemPerformanceMath.appending(network.receivedBytesPerSecond, to: networkReceiveHistory)
            networkSendHistory = SystemPerformanceMath.appending(network.sentBytesPerSecond, to: networkSendHistory)
        }
        if !sample.interfaceTotals.isEmpty { interfaceTotals = sample.interfaceTotals }
    }

    private func consumeStorage(_ sample: SystemStorageUsage?, generation: UInt64) {
        guard storageTimer != nil, generation == samplingGeneration else { return }
        lastStorageSampleAt = Date()
        lastStorageUpdate = Date()
        guard let sample else {
            storage = nil
            storageState = .unavailable
            return
        }
        if storage != sample { storage = sample }
        storageState = .available
    }
}

/// Native readers. None of these shell out; all are safe off the main thread.
enum SystemPerformanceReader {
    /// Reads all logical-processor load counters. The Mach-allocated buffer is always released.
    static func cpuTimes() -> [SystemCPUTime]? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }

        var processorCount = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)
        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
        let allocationSize = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        defer {
            if let info, allocationSize > 0 {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), allocationSize)
            }
        }

        guard result == KERN_SUCCESS, let info, processorCount > 0 else { return nil }
        let stride = Int(CPU_STATE_MAX)
        guard stride > 0, infoCount >= mach_msg_type_number_t(Int(processorCount) * stride) else { return nil }

        var counters: [SystemCPUTime] = []
        counters.reserveCapacity(Int(processorCount))
        for processor in 0..<Int(processorCount) {
            let offset = processor * stride
            func value(_ state: Int32) -> UInt64 {
                UInt64(UInt32(bitPattern: info[offset + Int(state)]))
            }
            counters.append(SystemCPUTime(
                user: value(CPU_STATE_USER),
                system: value(CPU_STATE_SYSTEM),
                idle: value(CPU_STATE_IDLE),
                nice: value(CPU_STATE_NICE)
            ))
        }
        return counters
    }

    static func startupVolumeStorage() -> SystemStorageUsage? {
        let startupVolume = URL(fileURLWithPath: "/", isDirectory: true)
        // "Important usage" includes purgeable space macOS can reclaim, matching Finder and System Settings.
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? startupVolume.resourceValues(forKeys: keys),
              let capacity = values.volumeTotalCapacity else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        guard let available = important ?? values.volumeAvailableCapacity.map(Int64.init) else { return nil }
        return SystemPerformanceMath.normalizedStorage(capacity: Int64(capacity), available: available)
    }

    static func memory() -> SystemMemoryUsage? {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let wiredPages = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)
        let cachedPages = UInt64(stats.external_page_count) + purgeable

        let app = boundedBytes(pages: appPages, pageSize: pageSize)
        let wired = boundedBytes(pages: wiredPages, pageSize: pageSize)
        let compressed = boundedBytes(pages: compressedPages, pageSize: pageSize)
        let (used, overflow) = app.addingReportingOverflow(wired)
        return SystemPerformanceMath.normalizedMemory(
            physical: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
            used: overflow ? .max : used.addingReportingOverflow(compressed).partialValue,
            wired: wired,
            compressed: compressed,
            app: app,
            cached: boundedBytes(pages: cachedPages, pageSize: pageSize),
            swapUsed: swapUsed() ?? 0,
            pressure: memoryPressure()
        )
    }

    static func memoryPressure() -> SystemMemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return SystemMemoryPressure(rawValue: Int(level))
    }

    static func swapUsed() -> Int64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Int64(clamping: usage.xsu_used)
    }

    static func loadAverages() -> SystemLoadAverages? {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return nil }
        return SystemLoadAverages(oneMinute: values[0], fiveMinutes: values[1], fifteenMinutes: values[2])
    }

    /// Reads only the `PerformanceStatistics` property instead of copying each
    /// accelerator's whole registry dictionary.
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var readings: [Double] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
                if let number = stats[key] as? NSNumber { readings.append(number.doubleValue) }
            }
        }
        guard let value = readings.max(), value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    static func diskCounters() -> SystemDiskCounters? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0
        var written: UInt64 = 0
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            if let value = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value {
                read = read.addingReportingOverflow(value).overflow ? read : read + value
                found = true
            }
            if let value = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value {
                written = written.addingReportingOverflow(value).overflow ? written : written + value
                found = true
            }
        }
        return found ? SystemDiskCounters(readBytes: read, writtenBytes: written) : nil
    }

    /// 64-bit interface byte counters from the interface MIB. (The routing
    /// socket list reports rounded 32-bit values to unprivileged processes.)
    /// Only counters are read: no addresses, destinations or packet contents.
    static func networkCounters() -> [SystemNetworkCounters]? {
        var countMIB: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        var count: Int32 = 0
        var countSize = MemoryLayout<Int32>.size
        guard sysctl(&countMIB, u_int(countMIB.count), &count, &countSize, nil, 0) == 0, count > 0 else { return nil }

        var counters: [SystemNetworkCounters] = []
        counters.reserveCapacity(Int(count))
        for index in 1...count {
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL]
            var data = ifmibdata()
            var size = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, u_int(mib.count), &data, &size, nil, 0) == 0,
                  Int32(bitPattern: data.ifmd_flags) & IFF_LOOPBACK == 0 else { continue }
            let name = withUnsafeBytes(of: data.ifmd_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard !name.isEmpty else { continue }
            counters.append(SystemNetworkCounters(
                name: name,
                receivedBytes: data.ifmd_data.ifi_ibytes,
                sentBytes: data.ifmd_data.ifi_obytes
            ))
        }
        return counters
    }

    static func coreLayout(logicalCount: Int) -> SystemCoreLayout? {
        func value(_ name: String) -> Int? {
            var result: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &result, &size, nil, 0) == 0 else { return nil }
            return Int(result)
        }
        guard value("hw.nperflevels") == 2,
              let performance = value("hw.perflevel0.logicalcpu"),
              let efficiency = value("hw.perflevel1.logicalcpu"),
              performance + efficiency == logicalCount else { return nil }
        return SystemCoreLayout(performance: performance, efficiency: efficiency)
    }

    private static func boundedBytes(pages: UInt64, pageSize: UInt64) -> Int64 {
        guard pageSize > 0 else { return 0 }
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow || bytes > UInt64(Int64.max) ? Int64.max : Int64(bytes)
    }
}

extension ProcessInfo.ThermalState {
    var activityTitle: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var activityColor: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
}

// MARK: - Compact view (Home dashboard and island)

@MainActor
struct SystemPerformanceView: View {
    @ObservedObject private var monitor: SystemPerformanceMonitor

    private let chrome: Bool
    private let detailed: Bool

    init(chrome: Bool = true, detailed: Bool = false) {
        self.init(monitor: .shared, chrome: chrome, detailed: detailed)
    }

    init(monitor: SystemPerformanceMonitor, chrome: Bool = true, detailed: Bool = false) {
        self.chrome = chrome
        self.detailed = detailed
        _monitor = ObservedObject(wrappedValue: monitor)
    }

    var body: some View {
        if detailed {
            PerformanceDashboardView(monitor: monitor)
        } else {
            compactDashboard
                .onAppear { monitor.acquireViewLease() }
                .onDisappear { monitor.releaseViewLease() }
        }
    }

    private var compactDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Performance", systemImage: "gauge.with.needle").font(.headline)
                Spacer()
                Text("\(monitor.logicalProcessorCount) logical cores")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 15) {
                if let usage = monitor.cpu {
                    ActivityRing(fraction: usage.active / 100, tint: cpuColor, value: ActivityFormat.percent(usage.active), caption: "CPU", lineWidth: 6)
                        .frame(width: 70, height: 70)
                    VStack(alignment: .leading, spacing: 4) {
                        metricRow("User", usage.user, .blue)
                        metricRow("System", usage.system, .purple)
                        metricRow("Idle", usage.idle, .secondary)
                    }
                    .fixedSize()
                    ActivityChart(series: [.init(values: monitor.cpuHistory, color: cpuColor)], maximum: 100, showsGrid: false)
                        .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48)
                } else {
                    Image(systemName: monitor.cpuState == .unavailable ? "exclamationmark.triangle" : "hourglass")
                        .font(.title2)
                        .foregroundStyle(monitor.cpuState == .unavailable ? .orange : .secondary)
                        .frame(width: 70, height: 70)
                    Text(cpuStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Divider().opacity(0.45)
            compactStorage
        }
        .padding(16)
        .background(chrome ? AnyShapeStyle(.fill.quinary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(chrome ? 0.6 : 0), lineWidth: 0.5))
    }

    private var compactStorage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Startup volume", systemImage: "internaldrive").font(.system(size: 12, weight: .medium))
                Spacer()
                Text(monitor.storage.map { "\(Int(($0.usedFraction * 100).rounded()))% used" } ?? "—")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let storage = monitor.storage {
                ActivityBar(fraction: storage.usedFraction, color: storageColor, height: 6)
                Text("\(ActivityFormat.bytes(storage.available)) available of \(ActivityFormat.bytes(storage.capacity))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(monitor.storageState == .unavailable ? "Storage unavailable." : "Reading startup volume…")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
    }

    private var cpuStatusText: String {
        switch monitor.cpuState {
        case .stopped: return "CPU monitoring is stopped."
        case .collecting: return "Collecting CPU sample…"
        case .available, .unavailable: return "CPU usage unavailable."
        }
    }

    private func metricRow(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
            Text("\(Int(value.rounded()))%").font(.caption2.monospacedDigit())
        }
    }

    private var cpuColor: Color {
        guard let active = monitor.cpu?.active else { return .blue }
        if active >= 85 { return .red }
        if active >= 65 { return .orange }
        return .blue
    }

    private var storageColor: Color {
        guard let fraction = monitor.storage?.usedFraction else { return .blue }
        if fraction >= 0.95 { return .red }
        if fraction >= 0.85 { return .orange }
        return .blue
    }
}
