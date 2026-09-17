import SwiftUI
import AppKit
import Combine
import IOKit
import IOKit.ps
import UserNotifications
import ChargeLimitCore

struct BatterySnapshot: Equatable, Sendable {
    let isPresent: Bool
    let percentage: Int
    let hardwarePercentage: Int?
    let isCharging: Bool
    let isFullyCharged: Bool
    let isConnectedToPower: Bool
    let timeRemainingMinutes: Int?
    let cycleCount: Int?
    let designCycleCount: Int?
    let designCapacity: Int?
    let fullChargeCapacity: Int?
    let temperatureCelsius: Double?
    let adapterWatts: Int?
    let adapterInputWatts: Double?
    let batteryFlowWatts: Double?
    let systemLoadWatts: Double?
    let condition: String

    static let unavailable = BatterySnapshot(
        isPresent: false,
        percentage: 0,
        hardwarePercentage: nil,
        isCharging: false,
        isFullyCharged: false,
        isConnectedToPower: false,
        timeRemainingMinutes: nil,
        cycleCount: nil,
        designCycleCount: nil,
        designCapacity: nil,
        fullChargeCapacity: nil,
        temperatureCelsius: nil,
        adapterWatts: nil,
        adapterInputWatts: nil,
        batteryFlowWatts: nil,
        systemLoadWatts: nil,
        condition: "Unavailable"
    )

    var healthPercent: Int? {
        BatteryInsightsMath.healthPercent(fullChargeCapacity: fullChargeCapacity, designCapacity: designCapacity)
    }
}

struct BatteryPowerApp: Identifiable, Equatable, Sendable {
    let name: String
    let appPath: String
    let cpuPercent: Double
    let memoryBytes: Int64

    var id: String { appPath }
    var impact: BatteryPowerImpact { BatteryInsightsMath.impact(cpuPercent: cpuPercent, memoryBytes: memoryBytes) }
}

enum BatteryPowerImpact: String, Equatable, Sendable {
    case high = "High"
    case elevated = "Elevated"
    case low = "Low"
}

enum BatteryInsightsMath {
    static func healthPercent(fullChargeCapacity: Int?, designCapacity: Int?) -> Int? {
        guard let fullChargeCapacity, let designCapacity, fullChargeCapacity > 0, designCapacity > 0 else { return nil }
        return min(100, max(0, Int((Double(fullChargeCapacity) / Double(designCapacity) * 100).rounded())))
    }

    /// AppleSmartBattery reports temperature in hundredths of a degree Celsius.
    static func temperatureCelsius(raw: Int?) -> Double? {
        guard let raw, raw > 0 else { return nil }
        let celsius = Double(raw) / 100
        return (-20...100).contains(celsius) ? celsius : nil
    }

    static func impact(cpuPercent: Double, memoryBytes: Int64) -> BatteryPowerImpact {
        // CPU is the strongest publicly available, process-level signal. Memory adds
        // a small nudge so a very large app is not described as completely idle.
        let memoryGB = Double(max(0, memoryBytes)) / 1_073_741_824
        let score = max(0, cpuPercent) + min(8, memoryGB * 2)
        if score >= 35 { return .high }
        if score >= 10 { return .elevated }
        return .low
    }

    /// Parses `ps -axo pid=,pcpu=,rss=,command=` and groups helper processes
    /// under the outermost .app bundle. Non-app daemons are intentionally omitted.
    static func powerApplications(fromPSOutput output: String, limit: Int = 6) -> [BatteryPowerApp] {
        struct Aggregate { var cpu = 0.0; var memory: Int64 = 0; var name = "" }
        var apps: [String: Aggregate] = [:]

        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: \Character.isWhitespace)
            guard fields.count == 4,
                  Double(fields[1]).map({ $0.isFinite }) == true,
                  let cpu = Double(fields[1]),
                  let rssKB = Int64(fields[2]) else { continue }

            let command = String(fields[3])
            guard let marker = command.range(of: ".app/") else { continue }
            let bundlePath = String(command[..<marker.lowerBound]) + ".app"
            let rawName = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
            guard !rawName.isEmpty else { continue }

            var aggregate = apps[bundlePath] ?? Aggregate(name: rawName)
            aggregate.cpu += max(0, cpu)
            aggregate.memory += max(0, rssKB) * 1_024
            apps[bundlePath] = aggregate
        }

        return apps.map { path, value in
            BatteryPowerApp(name: value.name, appPath: path, cpuPercent: value.cpu, memoryBytes: value.memory)
        }
        .filter { $0.cpuPercent >= 0.1 || $0.memoryBytes >= 100 * 1_024 * 1_024 }
        .sorted {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return $0.memoryBytes > $1.memoryBytes
        }
        .prefix(max(0, limit))
        .map { $0 }
    }
}

@MainActor
final class BatteryInsightsMonitor: ObservableObject {
    static let shared = BatteryInsightsMonitor()

    @Published private(set) var snapshot: BatterySnapshot = .unavailable
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var notice: String?
    @Published private(set) var isAtSmartLimit = false
    /// The charge limit. With the helper installed, charging is paused at
    /// `chargeTarget`; without software charge control it falls back to an alert.
    @Published var smartLimitEnabled: Bool {
        didSet {
            UserDefaults.standard.set(smartLimitEnabled, forKey: Self.smartLimitKey)
            if smartLimitEnabled { requestNotificationAccess() }
            else { limitAlerted = false; isAtSmartLimit = false }
            syncChargeLimit(installIfNeeded: smartLimitEnabled)
        }
    }
    @Published var chargeTarget: Int {
        didSet {
            UserDefaults.standard.set(chargeTarget, forKey: Self.chargeTargetKey)
            scheduleChargeLimitSync()
        }
    }
    @Published var sailingRange: Int {
        didSet {
            UserDefaults.standard.set(sailingRange, forKey: Self.sailingRangeKey)
            scheduleChargeLimitSync()
        }
    }
    @Published private(set) var dischargeRequestedAt: Date?
    @Published private(set) var topUpRequestedAt: Date?
    @Published var chargesDuringSleep: Bool {
        didSet {
            UserDefaults.standard.set(chargesDuringSleep, forKey: Self.chargesDuringSleepKey)
            syncChargeLimit(installIfNeeded: false)
        }
    }
    @Published var heatAlertEnabled: Bool {
        didSet {
            UserDefaults.standard.set(heatAlertEnabled, forKey: Self.heatAlertKey)
            if !heatAlertEnabled { heatAlerted = false }
            else { requestNotificationAccess() }
        }
    }
    @Published var heatLimitCelsius: Int {
        didSet { UserDefaults.standard.set(heatLimitCelsius, forKey: Self.heatLimitKey) }
    }

    private static let smartLimitKey = "battery.smart80.enabled"
    private static let chargeTargetKey = "battery.chargeTarget"
    private static let chargesDuringSleepKey = "battery.chargeLimit.chargesDuringSleep"
    private static let sailingRangeKey = "battery.chargeLimit.sailingRange"
    private static let dischargeRequestKey = "battery.chargeLimit.dischargeRequestedAt"
    private static let topUpRequestKey = "battery.chargeLimit.topUpRequestedAt"
    private static let heatAlertKey = "battery.heatAlert.enabled"
    private static let heatLimitKey = "battery.heatAlert.celsius"
    private let readQueue = DispatchQueue(label: "SuperNotch.battery-insights", qos: .utility)
    private var cancellables: Set<AnyCancellable> = []
    private var liveTimer: Timer?
    private var viewLeases = 0
    private var refreshTick = 0
    private var limitAlerted = false
    private var heatAlerted = false
    private var started = false
    private var isReading = false
    private var pendingLimitSync: DispatchWorkItem?
    private var lastLimitStatus: ChargeLimitStatus?

    init(defaults: UserDefaults = .standard) {
        smartLimitEnabled = defaults.bool(forKey: Self.smartLimitKey)
        chargeTarget = defaults.object(forKey: Self.chargeTargetKey) == nil
            ? 80
            : min(100, max(50, defaults.integer(forKey: Self.chargeTargetKey)))
        chargesDuringSleep = defaults.bool(forKey: Self.chargesDuringSleepKey)
        sailingRange = defaults.object(forKey: Self.sailingRangeKey) == nil
            ? ChargeLimitPolicy.resumeHysteresis
            : min(20, max(1, defaults.integer(forKey: Self.sailingRangeKey)))
        dischargeRequestedAt = defaults.object(forKey: Self.dischargeRequestKey) as? Date
        topUpRequestedAt = defaults.object(forKey: Self.topUpRequestKey) as? Date
        heatAlertEnabled = defaults.bool(forKey: Self.heatAlertKey)
        heatLimitCelsius = defaults.object(forKey: Self.heatLimitKey) == nil
            ? 40
            : min(45, max(35, defaults.integer(forKey: Self.heatLimitKey)))
    }

    func start() {
        guard !started else { return }
        started = true
        refreshBattery()
        ChargeLimiter.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in self?.chargeLimitStatusChanged(status) }
            .store(in: &cancellables)
        ChargeLimiter.shared.$helperState
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                // Keep the helper's settings in step with the app after launch or an update.
                if state == .installed { self?.syncChargeLimit(installIfNeeded: false) }
            }
            .store(in: &cancellables)
        SystemMonitor.shared.didRefresh
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.systemDidRefresh() }
            .store(in: &cancellables)
    }

    func stop() {
        started = false
        cancellables.removeAll()
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// While a battery view is visible, telemetry refreshes every five seconds
    /// so power flow feels live. Otherwise detailed readings happen once a minute.
    func acquireViewLease() {
        viewLeases += 1
        start()
        refreshBattery()
        guard liveTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBattery() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func releaseViewLease() {
        viewLeases = max(0, viewLeases - 1)
        guard viewLeases == 0 else { return }
        liveTimer?.invalidate()
        liveTimer = nil
    }

    func refreshAll() {
        refreshBattery()
    }

    func clearNotice() { notice = nil }

    func openBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery") else { return }
        NSWorkspace.shared.open(url)
    }

    private func systemDidRefresh() {
        refreshTick += 1
        // SystemMonitor already wakes every three seconds. Reuse that cadence for
        // threshold detection and only re-read detailed registry data once a minute.
        evaluateSmartLimit(percentage: SystemMonitor.shared.battery, charging: SystemMonitor.shared.charging)
        if refreshTick >= 20 {
            refreshTick = 0
            if liveTimer == nil { refreshBattery() }
        }
    }

    /// Registry reads copy a large property dictionary, so they run off the main thread.
    private func refreshBattery() {
        guard !isReading else { return }
        isReading = true
        readQueue.async { [weak self] in
            // IOKit bridges registry dictionaries through Objective-C. Bound
            // their temporary lifetime to this individual telemetry read.
            let snapshot = autoreleasepool { Self.readBatterySnapshot() }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReading = false
                if self.snapshot != snapshot { self.snapshot = snapshot }
                self.lastUpdated = Date()
                ChargeLimiter.shared.refresh()
                self.evaluateSmartLimit(percentage: snapshot.percentage, charging: snapshot.isCharging)
                self.evaluateHeat(snapshot.temperatureCelsius)
            }
        }
    }

    var chargeLimitConfiguration: ChargeLimitConfiguration {
        ChargeLimitConfiguration(
            enabled: smartLimitEnabled,
            limit: chargeTarget,
            chargesDuringSleep: chargesDuringSleep,
            sailingRange: sailingRange,
            dischargeRequestedAt: dischargeRequestedAt,
            topUpRequestedAt: topUpRequestedAt
        )
    }

    /// Runs from the battery while plugged in until it falls to the charge limit.
    func startDischarge() {
        topUpRequestedAt = nil
        dischargeRequestedAt = Date()
        persistRequests()
        syncChargeLimit(installIfNeeded: false)
    }

    func stopDischarge() {
        dischargeRequestedAt = nil
        persistRequests()
        syncChargeLimit(installIfNeeded: false)
    }

    /// Charges to 100% once; the limit applies again afterwards.
    func startTopUp() {
        dischargeRequestedAt = nil
        topUpRequestedAt = Date()
        persistRequests()
        syncChargeLimit(installIfNeeded: false)
    }

    func stopTopUp() {
        topUpRequestedAt = nil
        persistRequests()
        syncChargeLimit(installIfNeeded: false)
    }

    private func persistRequests() {
        let defaults = UserDefaults.standard
        if let dischargeRequestedAt { defaults.set(dischargeRequestedAt, forKey: Self.dischargeRequestKey) } else { defaults.removeObject(forKey: Self.dischargeRequestKey) }
        if let topUpRequestedAt { defaults.set(topUpRequestedAt, forKey: Self.topUpRequestKey) } else { defaults.removeObject(forKey: Self.topUpRequestKey) }
    }

    /// Sends the current settings to the helper, installing it first when the
    /// user turns the limit on and it is not installed yet.
    private func syncChargeLimit(installIfNeeded: Bool) {
        pendingLimitSync?.cancel()
        pendingLimitSync = nil
        let limiter = ChargeLimiter.shared
        if limiter.apply(chargeLimitConfiguration) { return }
        guard installIfNeeded, limiter.canInstall else { return }
        limiter.install(then: chargeLimitConfiguration) { [weak self] success in
            if !success { self?.smartLimitEnabled = false }
        }
    }

    /// Slider drags produce many values; send only the one the user settles on.
    private func scheduleChargeLimitSync() {
        pendingLimitSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.syncChargeLimit(installIfNeeded: false) }
        }
        pendingLimitSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func chargeLimitStatusChanged(_ status: ChargeLimitStatus?) {
        guard let status, ChargeLimiter.shared.isHelperResponding else { return }
        let previous = lastLimitStatus
        lastLimitStatus = status
        // Clear one-shot requests the helper has finished with.
        if let requested = dischargeRequestedAt, !status.discharging, status.updatedAt.timeIntervalSince(requested) > 5 {
            dischargeRequestedAt = nil
            persistRequests()
            if previous?.discharging == true, status.lastError == nil {
                IslandActivityController.shared.present(IslandActivity(
                    title: "Discharged to \(status.limit)%",
                    detail: "Charging is held at your limit",
                    symbol: "battery.75percent",
                    kind: .power,
                    level: Double(status.limit) / 100
                ), duration: 5)
            }
        }
        if let requested = topUpRequestedAt, !status.toppingUp, status.updatedAt.timeIntervalSince(requested) > 5 {
            topUpRequestedAt = nil
            persistRequests()
            if previous?.toppingUp == true {
                IslandActivityController.shared.present(IslandActivity(
                    title: "Topped up to 100%",
                    detail: "Your charge limit applies again",
                    symbol: "battery.100percent",
                    kind: .power,
                    level: 1
                ), duration: 5)
            }
        }
        guard !status.discharging, !status.toppingUp else { return }
        let held = status.enabled && status.chargingInhibited && !status.pausedForSleep
        if isAtSmartLimit != held { isAtSmartLimit = held }
        guard held, status.adapterConnected else {
            if !status.chargingInhibited { limitAlerted = false }
            return
        }
        guard !limitAlerted else { return }
        limitAlerted = true
        IslandActivityController.shared.present(IslandActivity(
            title: "Charging held at \(status.limit)%",
            detail: "Your Mac is running from the adapter",
            symbol: "battery.100percent",
            kind: .power,
            level: Double(status.limit) / 100
        ), duration: 5)
    }

    /// Alert-only fallback for Macs without software charge control.
    private func evaluateSmartLimit(percentage: Int, charging: Bool) {
        guard case .unsupported = ChargeLimiter.shared.helperState else { return }
        guard smartLimitEnabled else { isAtSmartLimit = false; return }
        let reached = snapshot.isConnectedToPower && charging && percentage >= chargeTarget
        if isAtSmartLimit != reached { isAtSmartLimit = reached }
        if percentage < chargeTarget - 2 || !snapshot.isConnectedToPower { limitAlerted = false }
        guard reached, !limitAlerted else { return }
        limitAlerted = true
        notice = "Battery reached \(chargeTarget)%. Unplug when convenient; macOS remains in control of charging."
        IslandActivityController.shared.present(IslandActivity(
            title: "Charge target reached",
            detail: "Unplug to reduce time spent fully charged",
            symbol: "battery.75percent",
            kind: .power,
            level: Double(chargeTarget) / 100
        ), duration: 6)
        let content = UNMutableNotificationContent()
        content.title = "Battery reached \(chargeTarget)%"
        content.body = "Unplug when convenient to reduce time spent at a high charge."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "supernotch-battery-target", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func evaluateHeat(_ temperature: Double?) {
        guard heatAlertEnabled, let temperature else { heatAlerted = false; return }
        if temperature < Double(heatLimitCelsius - 2) { heatAlerted = false }
        guard temperature >= Double(heatLimitCelsius), !heatAlerted else { return }
        heatAlerted = true
        notice = "Battery temperature is \(String(format: "%.1f", temperature))° C. Reduce heavy workloads and improve airflow."
        IslandActivityController.shared.present(IslandActivity(
            title: "Battery is running warm",
            detail: "\(String(format: "%.1f", temperature))° C · reduce heavy workloads",
            symbol: "thermometer.high",
            kind: .power
        ), duration: 6)
        let content = UNMutableNotificationContent()
        content.title = "Battery is running warm"
        content.body = "Temperature reached \(String(format: "%.1f", temperature))° C. Improve airflow and reduce heavy workloads."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "supernotch-battery-heat", content: content, trigger: nil))
    }

    private func requestNotificationAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated private static func readBatterySnapshot() -> BatterySnapshot {
        guard let powerInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(powerInfo)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let description = IOPSGetPowerSourceDescription(powerInfo, source)?.takeUnretainedValue() as? [String: Any] else {
            return .unavailable
        }

        let current = int(description[kIOPSCurrentCapacityKey]) ?? 0
        let maximum = int(description[kIOPSMaxCapacityKey]) ?? 100
        let percentage = maximum > 0 ? min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded()))) : 0
        let charging = bool(description[kIOPSIsChargingKey]) ?? false
        let fullyCharged = bool(description[kIOPSIsChargedKey]) ?? false
        let powerState = description[kIOPSPowerSourceStateKey] as? String
        let connected = powerState == kIOPSACPowerValue || charging || fullyCharged
        let rawTime = int(description[kIOPSTimeToEmptyKey])
        let timeRemaining = rawTime.flatMap { (0...24 * 60).contains($0) ? $0 : nil }

        var registry: [String: Any] = [:]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let values = properties?.takeRetainedValue() as? [String: Any] {
                registry = values
            }
        }

        let cycleCount = int(registry["CycleCount"])
        let designCycles = int(registry["DesignCycleCount9C"])
        let designCapacity = int(registry["DesignCapacity"])
            ?? dictionary(registry["BatteryData"]).flatMap { int($0["DesignCapacity"]) }
        let fullCapacity = int(registry["AppleRawMaxCapacity"]) ?? int(registry["NominalChargeCapacity"])
        let health = BatteryInsightsMath.healthPercent(fullChargeCapacity: fullCapacity, designCapacity: designCapacity)
        let failure = int(registry["PermanentFailureStatus"]) ?? 0
        let condition = failure != 0 || (health.map { $0 < 80 } ?? false) ? "Service Recommended" : "Normal"
        let temperature = BatteryInsightsMath.temperatureCelsius(raw: int(registry["Temperature"]))
        let adapterWatts = dictionary(registry["AdapterDetails"]).flatMap { int($0["Watts"]) }
        let batteryData = dictionary(registry["BatteryData"])
        let hardwarePercentage = batteryData.flatMap { int($0["StateOfCharge"]) }
        let telemetry = dictionary(registry["PowerTelemetryData"])
        let adapterInput = telemetry.flatMap { int($0["SystemPowerIn"]) }.flatMap(wattsFromMilliwatts)
        // Signed: positive while charging the battery, negative while it supplies power.
        let batteryFlow = telemetry.flatMap { int($0["BatteryPower"]) }.flatMap { value -> Double? in
            abs(value) < 1_000_000 ? Double(value) / 1_000 : nil
        }
        let systemLoad = telemetry.flatMap { int($0["SystemLoad"]) }.flatMap(wattsFromMilliwatts)

        return BatterySnapshot(
            isPresent: true,
            percentage: percentage,
            hardwarePercentage: hardwarePercentage,
            isCharging: charging,
            isFullyCharged: fullyCharged,
            isConnectedToPower: connected,
            timeRemainingMinutes: timeRemaining,
            cycleCount: cycleCount,
            designCycleCount: designCycles,
            designCapacity: designCapacity,
            fullChargeCapacity: fullCapacity,
            temperatureCelsius: temperature,
            adapterWatts: adapterWatts,
            adapterInputWatts: adapterInput,
            batteryFlowWatts: batteryFlow,
            systemLoadWatts: systemLoad,
            condition: condition
        )
    }

    nonisolated private static func wattsFromMilliwatts(_ value: Int) -> Double? {
        guard value >= 0, value < 1_000_000 else { return nil }
        return Double(value) / 1_000
    }

    nonisolated private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    nonisolated private static func bool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }

    nonisolated private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}

@MainActor
struct BatteryInsightsView: View {
    @ObservedObject private var monitor: BatteryInsightsMonitor
    @ObservedObject private var apps = AppResourceMonitor.shared
    @ObservedObject private var limiter = ChargeLimiter.shared
    @State private var width: CGFloat = 1_000
    @State private var confirmUninstall = false

    init() {
        _monitor = ObservedObject(wrappedValue: .shared)
    }

    init(monitor: BatteryInsightsMonitor) {
        _monitor = ObservedObject(wrappedValue: monitor)
    }

    private var snapshot: BatterySnapshot { monitor.snapshot }
    private var isWide: Bool { width >= 900 }

    var body: some View {
        ScrollView {
            // Avoid constructing offscreen controls and text layout until the
            // user scrolls their independent cards toward the viewport.
            LazyVStack(alignment: .leading, spacing: ActivityMetrics.spacing) {
                if let notice = monitor.notice {
                    InlineMessage(text: notice, tone: .orange) { monitor.clearNotice() }
                }
                if snapshot.isPresent {
                    hero
                    healthTiles
                    pair(smartCharging, maintenanceCard)
                    heatProtection
                    appsCard
                    toolkit
                } else if monitor.lastUpdated == nil {
                    ActivityPlaceholder(text: "Reading battery…").frame(minHeight: 320)
                } else {
                    noBattery
                }
                if let updated = monitor.lastUpdated, snapshot.isPresent {
                    Text("Battery details updated \(updated.formatted(date: .omitted, time: .standard)) · refreshes every 5 seconds while open")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                }
            }
            .activityWidth($width)
            .padding(.bottom, 12)
        }
        .onAppear {
            monitor.acquireViewLease()
            limiter.refresh()
        }
        .onDisappear { monitor.releaseViewLease() }
        .alert("Remove the charge helper?", isPresented: $confirmUninstall) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                limiter.uninstall { success in if success { monitor.smartLimitEnabled = false } }
            }
        } message: {
            Text("Charging returns to normal and the MagSafe light goes back to macOS. You can reinstall it any time.")
        }
    }

    /// True when the helper is actively holding charge at the limit.
    private var isHoldingCharge: Bool {
        guard let status = liveStatus else { return false }
        return status.enabled && status.chargingInhibited && !status.pausedForSleep && !status.discharging
    }

    private var liveStatus: ChargeLimitStatus? {
        limiter.isHelperResponding ? limiter.status : nil
    }

    private var isDischarging: Bool { liveStatus?.discharging == true }
    private var isToppingUp: Bool { liveStatus?.toppingUp == true }

    @ViewBuilder
    private func pair<A: View, B: View>(_ leading: A, _ trailing: B) -> some View {
        if isWide {
            HStack(alignment: .top, spacing: ActivityMetrics.spacing) { leading; trailing }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: ActivityMetrics.spacing) { leading; trailing }
        }
    }

    // MARK: Hero

    private var hero: some View {
        let layout = isWide ? AnyLayout(HStackLayout(alignment: .center, spacing: 28)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        return layout {
            HStack(spacing: 22) {
                ActivityRing(fraction: Double(snapshot.percentage) / 100, tint: chargeColor, value: "\(snapshot.percentage)%", caption: snapshot.isCharging ? "Charging" : "Battery", lineWidth: 11)
                    .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: statusSymbol).foregroundStyle(chargeColor)
                        Text(powerTitle)
                    }
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(powerDetail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                    HStack(spacing: 6) {
                        ActivityPill(text: snapshot.condition, color: snapshot.condition == "Normal" ? .green : .orange, symbol: "heart.fill")
                        if let watts = snapshot.adapterWatts, watts > 0 {
                            ActivityPill(text: "\(watts) W adapter", color: .yellow, symbol: "powerplug.fill")
                        }
                        if isDischarging {
                            ActivityPill(text: "Discharging to \(monitor.chargeTarget)%", color: .orange, symbol: "arrow.down.circle.fill")
                        } else if isToppingUp {
                            ActivityPill(text: "Topping up to 100%", color: .blue, symbol: "arrow.up.circle.fill")
                        } else if isHoldingCharge {
                            ActivityPill(text: "Held at \(monitor.chargeTarget)%", color: .green, symbol: "pause.circle.fill")
                        } else if monitor.isAtSmartLimit {
                            ActivityPill(text: "\(monitor.chargeTarget)% target reached", color: .orange, symbol: "bell.badge.fill")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            if isWide { Spacer(minLength: 0) }
            powerFlow
        }
        .activityCard(padding: 22, tint: chargeColor)
    }

    private var powerFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("POWER FLOW").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.4))
                Text("sensor estimate").font(.system(size: 10)).foregroundStyle(.white.opacity(0.25))
            }
            HStack(spacing: 0) {
                let flow = snapshot.batteryFlowWatts ?? 0
                if snapshot.isConnectedToPower {
                    flowNode("Adapter", watts: snapshot.adapterInputWatts, symbol: "powerplug.fill", color: .yellow)
                    connector(color: .yellow)
                    flowNode("This Mac", watts: snapshot.systemLoadWatts, symbol: "laptopcomputer", color: .blue)
                    if flow > 0.5 {
                        connector(color: .green)
                        flowNode("Charging", watts: flow, symbol: "battery.100percent.bolt", color: .green)
                    } else if flow < -0.5 {
                        connector(color: .orange, reversed: true)
                        flowNode("Assisting", watts: -flow, symbol: "battery.75percent", color: .orange)
                    }
                } else {
                    flowNode("Battery", watts: snapshot.batteryFlowWatts.map(abs) ?? snapshot.systemLoadWatts, symbol: "battery.75percent", color: .orange)
                    connector(color: .orange)
                    flowNode("This Mac", watts: snapshot.systemLoadWatts, symbol: "laptopcomputer", color: .blue)
                }
            }
        }
        .fixedSize()
    }

    private func flowNode(_ title: String, watts: Double?, symbol: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.14), in: Circle())
                .overlay(Circle().strokeBorder(color.opacity(0.3), lineWidth: 0.7))
            Text(watts.map { String(format: "%.1f W", $0) } ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        }
        .frame(width: 78)
    }

    private func connector(color: Color, reversed: Bool = false) -> some View {
        HStack(spacing: 0) {
            if reversed {
                Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold)).foregroundStyle(color.opacity(0.8))
            }
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0.15), color.opacity(0.6)], startPoint: reversed ? .trailing : .leading, endPoint: reversed ? .leading : .trailing))
                .frame(height: 2)
            if !reversed {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(color.opacity(0.8))
            }
        }
        .frame(width: 34)
        .offset(y: -17)
        .accessibilityHidden(true)
    }

    // MARK: Health

    private var healthTiles: some View {
        let columns = width >= 900 ? 4 : width >= 420 ? 2 : 1
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ActivityMetrics.spacing, alignment: .top), count: columns), spacing: ActivityMetrics.spacing) {
            ActivityTile(title: "Health", symbol: "heart.fill", tint: healthColor, value: snapshot.healthPercent.map { "\($0)%" } ?? "—", detail: "Maximum capacity vs. new") {
                ActivityBar(fraction: Double(snapshot.healthPercent ?? 0) / 100, color: healthColor, height: 6)
            }
            ActivityTile(title: "Cycle count", symbol: "arrow.triangle.2.circlepath", tint: .blue, value: snapshot.cycleCount.map(String.init) ?? "—", detail: cycleDetail) {
                ActivityBar(fraction: cycleFraction, color: .blue, height: 6)
            }
            ActivityTile(title: "Temperature", symbol: "thermometer.medium", tint: temperatureColor, value: snapshot.temperatureCelsius.map { String(format: "%.1f° C", $0) } ?? "—", detail: temperatureDetail) {
                ActivityBar(fraction: ((snapshot.temperatureCelsius ?? 20) - 20) / 30, color: temperatureColor, height: 6)
            }
            ActivityTile(title: "Full charge capacity", symbol: "battery.100percent", tint: .mint, value: snapshot.fullChargeCapacity.map { "\($0) mAh" } ?? "—", detail: capacityDetail) {
                ActivityBar(fraction: capacityFraction, color: .mint, height: 6)
            }
        }
    }

    // MARK: Controls

    private var smartCharging: some View {
        controlCard(
            title: "Charge limit",
            detail: hardLimitAvailable
                ? "Stops charging at your limit, even while plugged in. The MagSafe light turns green while charging is held."
                : "Get a notice when charging reaches your target so you can unplug.",
            symbol: "leaf.fill",
            tint: .green,
            isOn: $monitor.smartLimitEnabled
        ) {
            sliderRow(
                value: Binding(get: { Double(monitor.chargeTarget) }, set: { monitor.chargeTarget = Int($0.rounded()) }),
                range: 50...100, step: 5, minimum: "50%", label: "\(monitor.chargeTarget)%", enabled: monitor.smartLimitEnabled
            )
            HStack(spacing: 8) {
                limiterStatusPill
                Spacer(minLength: 8)
                limiterActions
            }
            if hardLimitAvailable {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep charging while asleep").font(.system(size: 12, weight: .medium))
                        Text("Off: charging pauses during sleep so it can never pass your limit.")
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    NotchToggle(isOn: $monitor.chargesDuringSleep).accessibilityLabel("Keep charging while asleep")
                }
                .disabled(!monitor.smartLimitEnabled)
                .opacity(monitor.smartLimitEnabled ? 1 : 0.45)
            }
            if let error = limiter.errorMessage ?? limiter.status?.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.4))
                Text(hardLimitAvailable
                     ? "Turn off Optimized Battery Charging so macOS doesn’t also hold charge on its own."
                     : "This Mac can’t pause charging from software. Optimized Battery Charging is the built-in alternative.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Battery Settings") { monitor.openBatterySettings() }.buttonStyle(PillButtonStyle())
            }
        }
    }

    private var hardLimitAvailable: Bool {
        if case .unsupported = limiter.helperState { return false }
        return true
    }

    @ViewBuilder
    private var limiterStatusPill: some View {
        switch limiter.helperState {
        case .checking:
            ActivityPill(text: "Checking charge control…", color: .gray)
        case .notInstalled:
            ActivityPill(text: "Helper not installed", color: .orange, symbol: "exclamationmark.circle.fill")
        case .outdated:
            ActivityPill(text: "Helper update available", color: .orange, symbol: "arrow.down.circle.fill")
        case .unsupported:
            ActivityPill(text: "Alert only on this Mac", color: .gray, symbol: "bell.fill")
        case .installed:
            if limiter.isWorking {
                ActivityPill(text: "Working…", color: .gray)
            } else if !limiter.isHelperResponding {
                ActivityPill(text: "Helper not responding", color: .red, symbol: "exclamationmark.triangle.fill")
            } else if let status = limiter.status {
                if !status.enabled {
                    ActivityPill(text: "Off · charging normally", color: .gray)
                } else if status.discharging {
                    ActivityPill(text: "Discharging to \(status.limit)%", color: .orange, symbol: "arrow.down.circle.fill")
                } else if status.toppingUp {
                    ActivityPill(text: "Topping up to 100%", color: .blue, symbol: "arrow.up.circle.fill")
                } else if status.pausedForSleep {
                    ActivityPill(text: "Paused for sleep", color: .indigo, symbol: "moon.fill")
                } else if status.chargingInhibited {
                    ActivityPill(text: status.adapterConnected ? "Holding at \(status.limit)% · light green" : "Charging paused · limit \(status.limit)%", color: .green, symbol: "pause.circle.fill")
                } else if status.adapterConnected {
                    ActivityPill(text: "Charging to \(status.limit)%", color: .blue, symbol: "bolt.fill")
                } else {
                    ActivityPill(text: "On battery · limit \(status.limit)%", color: .gray, symbol: "battery.75percent")
                }
            } else {
                ActivityPill(text: "Starting helper…", color: .gray)
            }
        }
    }

    @ViewBuilder
    private var limiterActions: some View {
        if limiter.isWorking {
            ProgressView().controlSize(.small)
        } else {
            switch limiter.helperState {
            case .notInstalled:
                Button("Install Helper…") {
                    limiter.install(then: monitor.chargeLimitConfiguration)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            case .outdated:
                Button("Update Helper…") {
                    limiter.install(then: monitor.chargeLimitConfiguration)
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            case .installed:
                Button("Remove Helper…") { confirmUninstall = true }
                    .buttonStyle(PillButtonStyle())
            case .checking, .unsupported:
                EmptyView()
            }
        }
    }

    // MARK: Discharge, sailing and top up

    private var supportsDischarge: Bool {
        guard hardLimitAvailable else { return false }
        return limiter.status?.supportsDischarge ?? true
    }

    /// Discharge and top up need a current helper and the limit turned on.
    private var maintenanceUnavailableReason: String? {
        switch limiter.helperState {
        case .unsupported: return "This Mac can’t control charging from software."
        case .notInstalled: return "Install the helper from the Charge limit card to use these."
        case .outdated: return "Update the helper from the Charge limit card to use these."
        case .checking: return "Checking charge control…"
        case .installed: break
        }
        if !monitor.smartLimitEnabled { return "Turn on Charge limit to use these." }
        if !limiter.isHelperResponding { return "Waiting for the helper to respond…" }
        return nil
    }

    private var maintenanceCard: some View {
        let unavailable = maintenanceUnavailableReason
        let percent = liveStatus?.batteryPercent ?? snapshot.percentage
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ActivityIcon(symbol: "sailboat.fill", tint: .teal, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Discharge & sailing").font(.system(size: 14, weight: .semibold))
                    Text("Let the charge drift before topping back up, drain to your limit while plugged in, or charge fully once.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sailing range").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("Resume charging at \(max(0, monitor.chargeTarget - monitor.sailingRange))%")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                }
                sliderRow(
                    value: Binding(get: { Double(monitor.sailingRange) }, set: { monitor.sailingRange = Int($0.rounded()) }),
                    range: 1...20, step: 1, minimum: "1%", label: "\(monitor.sailingRange)%", enabled: monitor.smartLimitEnabled
                )
            }

            Divider().overlay(Color.white.opacity(0.05))

            maintenanceAction(
                title: "Discharge to \(monitor.chargeTarget)%",
                detail: dischargeDetail(percent: percent),
                symbol: "arrow.down.circle.fill",
                tint: .orange,
                isActive: isDischarging || monitor.dischargeRequestedAt != nil,
                startTitle: "Discharge",
                canStart: unavailable == nil && supportsDischarge && percent > monitor.chargeTarget,
                start: { monitor.startDischarge() },
                stop: { monitor.stopDischarge() }
            )
            maintenanceAction(
                title: "Top up to 100%",
                detail: isToppingUp ? "Charging to full · \(percent)% now" : "Charge fully once, like before a trip. Your limit applies again afterward.",
                symbol: "arrow.up.circle.fill",
                tint: .blue,
                isActive: isToppingUp || monitor.topUpRequestedAt != nil,
                startTitle: "Top Up",
                canStart: unavailable == nil && percent < 100,
                start: { monitor.startTopUp() },
                stop: { monitor.stopTopUp() }
            )

            if let unavailable {
                Label(unavailable, systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .activityCard(tint: isDischarging ? .orange : isToppingUp ? .blue : nil)
    }

    private func dischargeDetail(percent: Int) -> String {
        if isDischarging {
            return liveStatus?.adapterConnected == true
                ? "Running from battery while plugged in · \(percent)% now"
                : "Unplugged · the adapter turns back on at \(monitor.chargeTarget)%"
        }
        if !supportsDischarge { return "This Mac can’t switch off its adapter from software." }
        if percent <= monitor.chargeTarget { return "The battery is already at or below your limit." }
        return "Run from the battery until it falls to your limit, even while plugged in."
    }

    private func maintenanceAction(title: String, detail: String, symbol: String, tint: Color, isActive: Bool, startTitle: String, canStart: Bool, start: @escaping () -> Void, stop: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(isActive ? tint : .white.opacity(0.4))
                .symbolEffect(.pulse, isActive: isActive)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isActive {
                Button("Stop", action: stop).buttonStyle(PillButtonStyle())
            } else {
                Button(startTitle, action: start)
                    .buttonStyle(PillButtonStyle(prominent: canStart))
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.45)
            }
        }
    }

    private var heatProtection: some View {
        controlCard(
            title: "Heat guard",
            detail: "Warns when the battery crosses your temperature threshold. Charging is never interrupted.",
            symbol: "thermometer.high",
            tint: .orange,
            isOn: $monitor.heatAlertEnabled
        ) {
            sliderRow(
                value: Binding(get: { Double(monitor.heatLimitCelsius) }, set: { monitor.heatLimitCelsius = Int($0.rounded()) }),
                range: 35...45, step: 1, minimum: "35°", label: "\(monitor.heatLimitCelsius)° C", enabled: monitor.heatAlertEnabled
            )
            if let temperature = snapshot.temperatureCelsius {
                Text("Currently \(String(format: "%.1f", temperature))° C")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func controlCard<Content: View>(title: String, detail: String, symbol: String, tint: Color, isOn: Binding<Bool>, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ActivityIcon(symbol: symbol, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                NotchToggle(isOn: isOn).accessibilityLabel(title)
            }
            content()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .activityCard()
    }

    private func sliderRow(value: Binding<Double>, range: ClosedRange<Double>, step: Double, minimum: String, label: String, enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Text(minimum).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            Slider(value: value, in: range, step: step)
            Text(label).font(.system(size: 13, weight: .semibold)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: Apps and toolkit

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityCardHeader(title: "Energy-hungry apps", symbol: "bolt.fill", tint: .yellow, subtitle: "Estimated from CPU and memory use · helpers grouped with their app")
            ActiveAppsList(monitor: apps, showsImpact: true)
            Text("Impact is an estimate, not macOS Energy Impact. Background daemons are excluded.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
        }
        .activityCard()
    }

    private var toolkit: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityCardHeader(title: "Battery toolkit", symbol: "wrench.and.screwdriver.fill", tint: .gray, subtitle: "What SuperNotch can do on this Mac")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
                feature("Charge limit", "Pauses charging at 50–100%, even plugged in", "battery.75percent", hardLimitAvailable)
                feature("Heat guard", "Temperature threshold warnings", "thermometer.high", true)
                feature("Power flow", "Adapter, Mac and battery telemetry", "arrow.left.arrow.right", true)
                feature("Health & cycles", "Capacity, condition and cycle budget", "heart.fill", true)
                feature("App impact", "Native CPU and memory sampling", "bolt.horizontal.fill", true)
                feature("Discharge & sailing", "Drain to the limit while plugged in", "sailboat.fill", supportsDischarge)
                feature("Top up", "Charge to 100% once, then limit again", "arrow.up.circle.fill", hardLimitAvailable)
                feature("MagSafe light", "Turns green while charge is held", "light.beacon.max.fill", limiter.status?.supportsLED ?? hardLimitAvailable)
                feature("Sleep protection", "Pauses charging before sleep", "moon.fill", hardLimitAvailable)
            }
        }
        .activityCard()
    }

    private func feature(_ title: String, _ detail: String, _ symbol: String, _ available: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(available ? .green : .white.opacity(0.35)).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(available ? 0.9 : 0.55))
                Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: available ? "checkmark.circle.fill" : "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(available ? .green : .white.opacity(0.3))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var noBattery: some View {
        VStack(spacing: 12) {
            Image(systemName: "powerplug.fill").font(.system(size: 34)).foregroundStyle(.yellow)
                .frame(width: 72, height: 72).background(.yellow.opacity(0.12), in: Circle())
            Text("This Mac runs on wall power").font(.system(size: 17, weight: .semibold))
            Text("Battery health, charge alerts and power flow appear here on Mac notebooks.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .activityCard()
    }

    // MARK: Derived values

    private var statusSymbol: String {
        if isDischarging { return "arrow.down.circle.fill" }
        if isToppingUp { return "bolt.fill" }
        if isHoldingCharge && snapshot.isConnectedToPower { return "pause.circle.fill" }
        if snapshot.isFullyCharged { return "battery.100percent" }
        if snapshot.isCharging { return "bolt.fill" }
        if snapshot.isConnectedToPower { return "powerplug.fill" }
        return "battery.75percent"
    }

    private var powerTitle: String {
        if isDischarging { return "Discharging to \(monitor.chargeTarget)%" }
        if isToppingUp { return "Topping up to 100%" }
        if isHoldingCharge && snapshot.isConnectedToPower { return "Charge limit reached" }
        if snapshot.isFullyCharged { return "Fully charged" }
        if snapshot.isCharging { return "Charging" }
        if snapshot.isConnectedToPower { return "On power adapter" }
        return "On battery"
    }

    private var powerDetail: String {
        if let minutes = snapshot.timeRemainingMinutes, minutes > 0, !snapshot.isConnectedToPower {
            return "About \(minutes / 60)h \(minutes % 60)m remaining"
        }
        if snapshot.isConnectedToPower, let flow = snapshot.batteryFlowWatts, flow < -1 {
            return "The adapter can’t keep up — the battery is covering \(String(format: "%.0f", -flow)) W"
        }
        if isDischarging {
            return liveStatus?.adapterConnected == true
                ? "Running from the battery while plugged in"
                : "Running from the battery · the adapter turns back on at your limit"
        }
        if isToppingUp { return "Charging fully once · your limit applies again at 100%" }
        if isHoldingCharge && snapshot.isConnectedToPower { return "Charging is held at \(monitor.chargeTarget)% · your Mac runs from the adapter" }
        if snapshot.isCharging { return "macOS is managing the charging rate" }
        if snapshot.isConnectedToPower { return snapshot.isFullyCharged ? "Running from the adapter" : "Charging is paused by macOS" }
        return "Estimating time remaining…"
    }

    private var cycleDetail: String {
        guard let design = snapshot.designCycleCount else { return "charge cycles" }
        return "of \(design) design cycles"
    }

    private var cycleFraction: Double {
        guard let cycles = snapshot.cycleCount, let design = snapshot.designCycleCount, design > 0 else { return 0 }
        return Double(cycles) / Double(design)
    }

    private var capacityDetail: String {
        guard let design = snapshot.designCapacity else { return "current maximum" }
        return "\(design) mAh when new"
    }

    private var capacityFraction: Double {
        guard let full = snapshot.fullChargeCapacity, let design = snapshot.designCapacity, design > 0 else { return 0 }
        return Double(full) / Double(design)
    }

    private var temperatureDetail: String {
        guard let temperature = snapshot.temperatureCelsius else { return "sensor unavailable" }
        if temperature >= 40 { return "Warm — improve airflow" }
        if temperature >= 35 { return "A little warm" }
        return "Normal range"
    }

    private var chargeColor: Color {
        if snapshot.isCharging || snapshot.isFullyCharged { return .green }
        if snapshot.percentage <= 10 { return .red }
        if snapshot.percentage <= 20 { return .orange }
        return .green
    }

    private var healthColor: Color {
        guard let health = snapshot.healthPercent else { return .gray }
        return health < 80 ? .orange : .green
    }

    private var temperatureColor: Color {
        guard let temperature = snapshot.temperatureCelsius else { return .gray }
        if temperature >= 40 { return .red }
        if temperature >= 35 { return .orange }
        return .teal
    }
}
