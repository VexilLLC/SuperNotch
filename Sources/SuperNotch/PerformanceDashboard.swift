import SwiftUI
import AppKit

/// The Activity › Performance tab.
@MainActor
struct PerformanceDashboardView: View {
    @ObservedObject var monitor: SystemPerformanceMonitor
    @ObservedObject private var apps = AppResourceMonitor.shared
    @State private var width: CGFloat = 1_000

    private var isWide: Bool { width >= 940 }
    private var tileColumns: Int { width >= 940 ? 4 : width >= 420 ? 2 : 1 }

    var body: some View {
        ScrollView {
            // Defer lower cards until they approach the viewport. The complete
            // dashboard is taller than the workspace on most displays.
            LazyVStack(alignment: .leading, spacing: ActivityMetrics.spacing) {
                statusStrip
                adaptivePair(leading: processorCard, trailing: memoryCard, trailingWidth: min(430, width * 0.4))
                tiles
                adaptivePair(leading: storageCard, trailing: appsCard, trailingWidth: width * 0.5)
            }
            .activityWidth($width)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
        .onAppear { monitor.acquireViewLease() }
        .onDisappear { monitor.releaseViewLease() }
    }

    // MARK: Layout

    @ViewBuilder
    private func adaptivePair<Leading: View, Trailing: View>(leading: Leading, trailing: Trailing, trailingWidth: CGFloat) -> some View {
        if isWide {
            HStack(alignment: .top, spacing: ActivityMetrics.spacing) {
                leading
                trailing.frame(width: trailingWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: ActivityMetrics.spacing) {
                leading
                trailing
            }
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ActivityMetrics.spacing, alignment: .top), count: tileColumns), spacing: ActivityMetrics.spacing) {
            gpuTile
            diskTile
            networkTile
            thermalTile
        }
    }

    // MARK: Status

    private var statusStrip: some View {
        HStack(spacing: 8) {
            ActivityPill(text: health.text, color: health.color)
            ActivityPill(text: "Thermals \(monitor.thermalState.activityTitle.lowercased())", color: monitor.thermalState.activityColor, symbol: "thermometer.medium")
            ActivityPill(text: "Up \(ActivityFormat.uptime(monitor.uptimeSeconds))", color: .blue, symbol: "clock")
            Spacer(minLength: 8)
            if isWide {
                HStack(spacing: 5) {
                    Circle().fill(monitor.cpuState == .available ? Color.green : .gray).frame(width: 5, height: 5)
                    Text(monitor.cpuState == .available ? "Live · updates every 2 seconds" : "Starting sensors…")
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var health: (text: String, color: Color) { monitor.healthSummary }

    // MARK: Processor

    private var processorCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ActivityCardHeader(title: "Processor", symbol: "cpu", tint: .blue, subtitle: coreSummary) {
                Text(loadSummary)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .help("Load average over 1, 5 and 15 minutes")
            }

            HStack(alignment: .center, spacing: 22) {
                ActivityRing(fraction: (monitor.cpu?.active ?? 0) / 100, tint: cpuColor, value: ActivityFormat.percent(monitor.cpu?.active), caption: "CPU")
                    .frame(width: 112, height: 112)
                VStack(spacing: 9) {
                    ActivityLegendRow(label: "User", value: ActivityFormat.percent(monitor.cpu?.user), color: cpuColor)
                    ActivityLegendRow(label: "System", value: ActivityFormat.percent(monitor.cpu?.system), color: .purple)
                    ActivityLegendRow(label: "Idle", value: ActivityFormat.percent(monitor.cpu?.idle), color: .white.opacity(0.25))
                }
                .frame(minWidth: 130, maxWidth: 190)
                if !monitor.coreUsage.isEmpty {
                    CoreActivityGrid(values: monitor.coreUsage, layout: monitor.coreLayout)
                        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
                } else {
                    Spacer(minLength: 0)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Last 2 minutes").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    chartLegend([("User", cpuColor), ("System", .purple)])
                }
                ZStack {
                    ActivityChart(series: [
                        .init(values: monitor.cpuHistory, color: cpuColor),
                        .init(values: monitor.cpuSystemHistory, color: .purple)
                    ], maximum: 100)
                    if monitor.cpuHistory.count < 2 {
                        Text("Collecting samples…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                    }
                }
                .frame(minHeight: 110, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) { axisLabel("100%") }
                .overlay(alignment: .bottomTrailing) { axisLabel("0%") }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .activityCard(tint: .blue)
    }

    private var coreSummary: String {
        let cores = "\(monitor.logicalProcessorCount) cores"
        guard let layout = monitor.coreLayout?.summary else { return cores }
        return "\(cores) · \(layout)"
    }

    private var loadSummary: String {
        guard let load = monitor.loadAverages else { return "Load —" }
        return String(format: "Load %.2f  %.2f  %.2f", load.oneMinute, load.fiveMinutes, load.fifteenMinutes)
    }

    // MARK: Memory

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ActivityCardHeader(title: "Memory", symbol: "memorychip", tint: memoryColor, subtitle: monitor.memory.map { "\(ActivityFormat.memory($0.physical)) installed" }) {
                if let pressure = monitor.memory?.pressure {
                    ActivityPill(text: "Pressure \(pressure.title.lowercased())", color: pressureColor(pressure))
                }
            }

            if let memory = monitor.memory {
                HStack(alignment: .center, spacing: 20) {
                    ActivityRing(fraction: memory.usedFraction, tint: memoryColor, value: ActivityFormat.percent(memory.usedFraction * 100), caption: "Used")
                        .frame(width: 112, height: 112)
                    VStack(spacing: 8) {
                        ActivityLegendRow(label: "App", value: ActivityFormat.memory(memory.app), color: .purple)
                        ActivityLegendRow(label: "Wired", value: ActivityFormat.memory(memory.wired), color: .orange)
                        ActivityLegendRow(label: "Compressed", value: ActivityFormat.memory(memory.compressed), color: .pink)
                        ActivityLegendRow(label: "Cached", value: ActivityFormat.memory(memory.cached), color: .white.opacity(0.25))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ActivityBar(segments: [
                        (memory.fraction(memory.app), .purple),
                        (memory.fraction(memory.wired), .orange),
                        (memory.fraction(memory.compressed), .pink)
                    ], height: 8)
                    HStack {
                        Text("\(ActivityFormat.memory(memory.available)) available")
                        Spacer()
                        Text(memory.swapUsed > 0 ? "Swap \(ActivityFormat.memory(memory.swapUsed))" : "No swap in use")
                    }
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                }
                ActivityChart(series: [.init(values: monitor.memoryHistory, color: memoryColor)], maximum: 100, gridLines: 1)
                    .frame(minHeight: 44, maxHeight: .infinity)
            } else {
                ActivityPlaceholder(text: monitor.cpuState == .stopped ? "Memory monitoring is paused" : "Reading memory…")
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .activityCard(tint: memoryColor)
    }

    // MARK: Tiles

    private var gpuTile: some View {
        ActivityTile(
            title: "Graphics",
            symbol: "square.stack.3d.up.fill",
            tint: .pink,
            value: monitor.gpuPercentage.map { ActivityFormat.percent($0) } ?? "—",
            detail: monitor.gpuPercentage == nil ? "Utilization unavailable" : "GPU utilization"
        ) {
            ActivityChart(series: [.init(values: monitor.gpuHistory, color: .pink)], maximum: 100, showsGrid: false)
                .frame(height: 34)
        }
    }

    private var diskTile: some View {
        ActivityTile(
            title: "Disk activity",
            symbol: "internaldrive.fill",
            tint: .green,
            value: ActivityFormat.rate(monitor.diskThroughput?.readBytesPerSecond),
            detail: "Read · write \(ActivityFormat.rate(monitor.diskThroughput?.writtenBytesPerSecond))"
        ) {
            ActivityChart(series: [
                .init(values: monitor.diskReadHistory, color: .green),
                .init(values: monitor.diskWriteHistory, color: .orange, filled: false)
            ], minimumScale: 1_000_000, showsGrid: false)
            .frame(height: 34)
        }
    }

    private var networkTile: some View {
        ActivityTile(
            title: "Network",
            symbol: "arrow.up.arrow.down",
            tint: .cyan,
            value: ActivityFormat.rate(monitor.networkThroughput?.receivedBytesPerSecond),
            detail: "Down · up \(ActivityFormat.rate(monitor.networkThroughput?.sentBytesPerSecond))"
        ) {
            ActivityChart(series: [
                .init(values: monitor.networkReceiveHistory, color: .cyan),
                .init(values: monitor.networkSendHistory, color: .indigo, filled: false)
            ], minimumScale: 100_000, showsGrid: false)
            .frame(height: 34)
        }
    }

    private var thermalTile: some View {
        ActivityTile(
            title: "Thermals",
            symbol: "thermometer.medium",
            tint: monitor.thermalState.activityColor,
            value: monitor.thermalState.activityTitle,
            detail: thermalDetail
        ) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { level in
                    Capsule()
                        .fill(level <= thermalLevel ? thermalColors[level] : Color.white.opacity(0.08))
                        .frame(height: 6)
                }
            }
            .frame(height: 34, alignment: .bottom)
            .animation(.easeOut(duration: 0.3), value: thermalLevel)
        }
    }

    private var thermalLevel: Int {
        switch monitor.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    private let thermalColors: [Color] = [.green, .yellow, .orange, .red]

    private var thermalDetail: String {
        switch monitor.thermalState {
        case .nominal: return "No thermal limits"
        case .fair: return "Slightly elevated"
        case .serious: return "macOS may reduce performance"
        case .critical: return "Performance is being limited"
        @unknown default: return "Thermal state"
        }
    }

    // MARK: Storage and apps

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ActivityCardHeader(title: "Startup disk", symbol: "internaldrive.fill", tint: storageColor, subtitle: storageAdvice) {
                Button("Manage…") { openStorageSettings() }
                    .buttonStyle(PillButtonStyle())
            }
            if let storage = monitor.storage {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ActivityFormat.bytes(storage.available))
                            .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("available of \(ActivityFormat.bytes(storage.capacity))")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Text(ActivityFormat.percent(storage.usedFraction * 100))
                        .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(storageColor)
                }
                ActivityBar(fraction: storage.usedFraction, color: storageColor, height: 10)
                HStack(spacing: 16) {
                    ActivityLegendRow(label: "Used", value: ActivityFormat.bytes(storage.used), color: storageColor)
                    ActivityLegendRow(label: "Free", value: ActivityFormat.bytes(storage.available), color: .white.opacity(0.25))
                }
                Spacer(minLength: 0)
                Text("Free space includes purgeable files macOS can reclaim.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            } else {
                ActivityPlaceholder(text: monitor.storageState == .unavailable ? "Storage information unavailable" : "Reading startup disk…",
                                    symbol: monitor.storageState == .unavailable ? "exclamationmark.triangle" : nil)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .activityCard(tint: storageColor)
    }

    private var appsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityCardHeader(title: "Most active apps", symbol: "square.grid.2x2.fill", tint: .teal, subtitle: "CPU of one core · memory footprint")
            ActiveAppsList(monitor: apps, maximumRows: 5)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .activityCard()
    }

    // MARK: Helpers

    private func chartLegend(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 5) {
                    Capsule().fill(item.1).frame(width: 10, height: 3)
                    Text(item.0)
                }
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }

    private func axisLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.3)).padding(2)
    }

    private var cpuColor: Color {
        guard let active = monitor.cpu?.active else { return .blue }
        if active >= 85 { return .red }
        if active >= 65 { return .orange }
        return .blue
    }

    private var memoryColor: Color {
        if let pressure = monitor.memory?.pressure, pressure != .normal { return pressureColor(pressure) }
        return .purple
    }

    private func pressureColor(_ pressure: SystemMemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var storageColor: Color {
        guard let fraction = monitor.storage?.usedFraction else { return .blue }
        if fraction >= 0.95 { return .red }
        if fraction >= 0.85 { return .orange }
        return .blue
    }

    private var storageAdvice: String {
        guard let fraction = monitor.storage?.usedFraction else { return "Startup volume" }
        if fraction >= 0.95 { return "Critically low on space" }
        if fraction >= 0.85 { return "Consider freeing up space" }
        return "Plenty of free space"
    }

    private func openStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension SystemPerformanceMonitor {
    /// A one-line reading of overall system health, most serious first.
    var healthSummary: (text: String, color: Color) {
        if thermalState == .critical { return ("Thermal throttling", .red) }
        if thermalState == .serious { return ("Running hot", .orange) }
        if memory?.pressure == .critical { return ("Memory pressure critical", .red) }
        if memory?.pressure == .warning { return ("Memory pressure elevated", .orange) }
        guard let active = cpu?.active else {
            return cpuState == .unavailable ? ("Processor data unavailable", .orange) : ("Collecting first sample", .gray)
        }
        if active >= 85 { return ("Heavy processor load", .red) }
        if active >= 65 { return ("Elevated processor load", .orange) }
        return ("Running smoothly", .green)
    }
}

/// Per-core activity bars drawn with Core Graphics.
struct CoreActivityGrid: View {
    let values: [Double]
    let layout: SystemCoreLayout?

    var body: some View {
        NativeCoreActivityGrid(grid: self)
        .accessibilityElement()
        .accessibilityLabel("Per-core activity")
        .accessibilityValue(values.map { "\(Int($0.rounded()))%" }.joined(separator: ", "))
    }

    var groups: [(range: Range<Int>, title: String?, shortTitle: String?, efficiency: Bool)] {
        if let layout, layout.total == values.count, layout.efficiency > 0 {
            return [
                (0..<layout.efficiency, "Efficiency", "E", true),
                (layout.efficiency..<values.count, "Performance", "P", false)
            ]
        }
        return [(0..<values.count, "\(values.count) cores", nil, false)]
    }

    func color(_ value: Double, efficiency: Bool) -> Color {
        if value >= 85 { return .red }
        if value >= 65 { return .orange }
        return efficiency ? .teal : .blue
    }
}
