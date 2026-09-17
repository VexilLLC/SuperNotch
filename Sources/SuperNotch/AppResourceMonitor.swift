import SwiftUI
import AppKit
import Darwin

/// One process reading used to aggregate app usage.
struct ProcessResourceSample: Equatable, Sendable {
    let pid: Int32
    let executablePath: String
    /// Cumulative user + system CPU time, in nanoseconds.
    let cpuTimeNanoseconds: UInt64
    /// Physical footprint, which is what Activity Monitor reports as Memory.
    let memoryBytes: UInt64
}

enum AppResourceMath {
    /// The outermost `.app` bundle containing an executable, so helpers such as
    /// `Chrome.app/…/Helper.app/…` are attributed to their parent app.
    static func bundlePath(forExecutable path: String) -> String? {
        guard let marker = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<marker.lowerBound]) + ".app"
        let name = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : bundle
    }

    /// Groups process samples by app and converts CPU-time deltas into a
    /// percentage of one core, like Activity Monitor. Processes without a
    /// previous reading, or whose counter went backwards (PID reuse), count as
    /// zero CPU for this interval.
    static func applications(
        previous: [Int32: UInt64],
        current: [ProcessResourceSample],
        elapsedNanoseconds: UInt64,
        limit: Int = 6
    ) -> [BatteryPowerApp] {
        struct Aggregate { var cpu = 0.0; var memory: Int64 = 0 }
        var apps: [String: Aggregate] = [:]
        let elapsed = Double(elapsedNanoseconds)

        for sample in current {
            guard let bundle = bundlePath(forExecutable: sample.executablePath) else { continue }
            var aggregate = apps[bundle] ?? Aggregate()
            if elapsed > 0, let before = previous[sample.pid], sample.cpuTimeNanoseconds >= before {
                aggregate.cpu += Double(sample.cpuTimeNanoseconds - before) / elapsed * 100
            }
            aggregate.memory += Int64(clamping: sample.memoryBytes)
            apps[bundle] = aggregate
        }

        return apps.map { path, value in
            BatteryPowerApp(
                name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                appPath: path,
                cpuPercent: value.cpu,
                memoryBytes: value.memory
            )
        }
        .filter { $0.cpuPercent >= 0.1 || $0.memoryBytes >= 100 * 1_024 * 1_024 }
        .sorted {
            if abs($0.cpuPercent - $1.cpuPercent) >= 0.05 { return $0.cpuPercent > $1.cpuPercent }
            return $0.memoryBytes > $1.memoryBytes
        }
        .prefix(max(0, limit))
        .map { $0 }
    }
}

/// Samples the current user's apps with `proc_pid_rusage`, without spawning
/// processes. Executable paths are cached per PID, and only processes inside
/// an app bundle are measured.
private final class AppResourceSampler: @unchecked Sendable {
    private var paths: [Int32: String?] = [:]
    private var previousCPU: [Int32: UInt64] = [:]
    private var previousTime: UInt64?
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (UInt64(max(1, info.numer)), UInt64(max(1, info.denom)))
    }()

    func reset() {
        previousCPU = [:]
        previousTime = nil
    }

    func sample(limit: Int) -> [BatteryPowerApp]? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let bytes = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return nil }
        let count = min(pids.count, Int(bytes))
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        var samples: [ProcessResourceSample] = []
        var alive: Set<Int32> = []
        alive.reserveCapacity(count)
        for pid in pids.prefix(count) where pid > 0 {
            alive.insert(pid)
            guard let path = executablePath(pid) else { continue }
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { continue }
            let machTime = usage.ri_user_time &+ usage.ri_system_time
            samples.append(ProcessResourceSample(
                pid: pid,
                executablePath: path,
                cpuTimeNanoseconds: machTime.multipliedReportingOverflow(by: timebase.numer).partialValue / timebase.denom,
                memoryBytes: usage.ri_phys_footprint
            ))
        }
        paths = paths.filter { alive.contains($0.key) }

        let elapsed = previousTime.map { now > $0 ? now - $0 : 0 } ?? 0
        let apps = AppResourceMath.applications(previous: previousCPU, current: samples, elapsedNanoseconds: elapsed, limit: limit)
        previousCPU = Dictionary(samples.map { ($0.pid, $0.cpuTimeNanoseconds) }, uniquingKeysWith: { first, _ in first })
        let hadBaseline = previousTime != nil
        previousTime = now
        return hadBaseline ? apps : nil
    }

    private func executablePath(_ pid: Int32) -> String? {
        if let cached = paths[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : nil
        let appPath = path.flatMap { $0.contains(".app/") ? $0 : nil }
        paths[pid] = .some(appPath)
        return appPath
    }
}

@MainActor
final class AppResourceMonitor: ObservableObject {
    static let shared = AppResourceMonitor()

    @Published private(set) var apps: [BatteryPowerApp] = []
    @Published private(set) var isSampling = false
    @Published private(set) var hasSample = false

    private let queue = DispatchQueue(label: "SuperNotch.app-resources", qos: .utility)
    private let sampler = AppResourceSampler()
    private var timer: DispatchSourceTimer?
    private var leases = 0
    private var generation: UInt64 = 0

    func acquireLease() {
        leases += 1
        guard timer == nil else { return }
        generation &+= 1
        let generation = generation
        let sampler = sampler
        isSampling = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // A quick second reading establishes the CPU baseline, then settle into a relaxed cadence.
        timer.schedule(deadline: .now(), repeating: 4, leeway: .milliseconds(500))
        var primed = false
        timer.setEventHandler { [weak self] in
            let result = autoreleasepool { sampler.sample(limit: 6) }
            if !primed {
                primed = true
                self?.queue.asyncAfter(deadline: .now() + 1) {
                    let next = autoreleasepool { sampler.sample(limit: 6) }
                    Task { @MainActor [weak self] in self?.apply(next, generation: generation) }
                }
            }
            Task { @MainActor [weak self] in self?.apply(result, generation: generation) }
        }
        self.timer = timer
        timer.resume()
    }

    func releaseLease() {
        guard leases > 0 else { return }
        leases -= 1
        guard leases == 0 else { return }
        generation &+= 1
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        isSampling = false
        let sampler = sampler
        queue.async { sampler.reset() }
    }

    func icon(for app: BatteryPowerApp) -> NSImage {
        SmallIconCache.fileIcon(for: app.appPath, pixels: 64)
    }

    private func apply(_ result: [BatteryPowerApp]?, generation: UInt64) {
        guard generation == self.generation, timer != nil, let result else { return }
        if apps != result { apps = result }
        hasSample = true
    }
}

/// A ranked list of the most active apps, shared by Performance and Battery.
struct ActiveAppsList: View {
    @ObservedObject var monitor: AppResourceMonitor
    var showsImpact = false
    var maximumRows = 6

    var body: some View {
        VStack(spacing: 0) {
            if !monitor.hasSample {
                ActivityPlaceholder(text: "Measuring app activity…").frame(minHeight: 120)
            } else if monitor.apps.isEmpty {
                ActivityPlaceholder(text: "No app is using significant resources", symbol: "checkmark.circle").frame(minHeight: 120)
            } else {
                let peak = max(25, monitor.apps.map(\.cpuPercent).max() ?? 0)
                ForEach(Array(monitor.apps.prefix(maximumRows).enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().overlay(Color.white.opacity(0.04)) }
                    row(app, peak: peak)
                }
            }
        }
        .onAppear { monitor.acquireLease() }
        .onDisappear { monitor.releaseLease() }
    }

    private func row(_ app: BatteryPowerApp, peak: Double) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: monitor.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(app.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(String(format: "%.1f%%", app.cpuPercent))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit().fixedSize()
                }
                HStack(spacing: 8) {
                    ActivityBar(fraction: app.cpuPercent / peak, color: color(for: app), height: 4)
                    Text(ActivityFormat.memory(app.memoryBytes))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                        .frame(minWidth: 52, alignment: .trailing).fixedSize()
                }
            }
            if showsImpact {
                Text(app.impact.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold)).tracking(0.5)
                    .foregroundStyle(color(for: app))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(color(for: app).opacity(0.13), in: Capsule())
                    .frame(width: 74, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .help(app.appPath)
        .accessibilityElement(children: .combine)
    }

    private func color(for app: BatteryPowerApp) -> Color {
        switch app.impact {
        case .high: return .red
        case .elevated: return .orange
        case .low: return .green
        }
    }
}
