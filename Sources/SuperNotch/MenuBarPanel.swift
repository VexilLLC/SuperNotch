import SwiftUI
import AppKit
import ChargeLimitCore

/// The details panel that opens from the menu bar item.
@MainActor
struct MenuBarPanelView: View {
    let close: () -> Void

    @ObservedObject private var preferences = MenuBarPreferences.shared
    @ObservedObject private var performance = SystemPerformanceMonitor.shared
    @ObservedObject private var system = SystemMonitor.shared
    @ObservedObject private var activities = SystemActivitiesModel.shared
    @ObservedObject private var battery = BatteryInsightsMonitor.shared
    @ObservedObject private var limiter = ChargeLimiter.shared
    @ObservedObject private var usage = AIUsageStore.shared
    @ObservedObject private var apps = AppResourceMonitor.shared

    static let width: CGFloat = 372

    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 40
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if shows(.system) { systemSection }
                if shows(.network) { networkSection }
                if shows(.ports) { OpenPortsSection(close: close) }
                if shows(.battery), system.hasBattery { batterySection }
                if shows(.storage) { storageSection }
                if shows(.aiUsage), !aiProviders.isEmpty { aiSection }
                if shows(.apps) { appsSection }
                if shows(.actions) { actionsSection }
                footer
            }
            .padding(12)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(white: 0.07))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear {
            performance.acquireViewLease()
            if system.hasBattery { battery.acquireViewLease() }
            limiter.refresh()
        }
        .onDisappear {
            performance.releaseViewLease()
            if system.hasBattery { battery.releaseViewLease() }
        }
    }

    private func shows(_ section: MenuBarPanelSection) -> Bool {
        preferences.showsPanelSection(section)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "rectangle.topthird.inset.filled").resizable().scaledToFit().padding(6)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("SuperNotch").font(.system(size: 14, weight: .bold, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(performance.healthSummary.color).frame(width: 6, height: 6)
                    Text("\(performance.healthSummary.text) · up \(ActivityFormat.uptime(performance.uptimeSeconds))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            ActivityIconButton(symbol: "macwindow", help: "Open SuperNotch") { perform { AppDelegate.shared?.openWorkspace() } }
            ActivityIconButton(symbol: "gearshape.fill", help: "Settings") {
                perform {
                    SettingsWindowController.shared.show(section: .menuBar)
                }
            }
        }
        .padding(.horizontal, 4).padding(.bottom, 2)
    }

    // MARK: System

    private var systemSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                statTile("CPU", value: ActivityFormat.percent(performance.cpu?.active),
                         detail: performance.cpu.map { "User \(Int($0.user.rounded()))% · Sys \(Int($0.system.rounded()))%" } ?? "Sampling…",
                         color: loadColor(performance.cpu?.active, base: .blue),
                         series: [.init(values: performance.cpuHistory, color: loadColor(performance.cpu?.active, base: .blue))], maximum: 100)
                statTile("Memory", value: ActivityFormat.percent(performance.memory.map { $0.usedFraction * 100 }),
                         detail: performance.memory.map { "\(ActivityFormat.memory($0.used)) of \(ActivityFormat.memory($0.physical))" } ?? "Sampling…",
                         color: .purple,
                         series: [.init(values: performance.memoryHistory, color: .purple)], maximum: 100)
            }
            HStack(spacing: 8) {
                statTile("GPU", value: ActivityFormat.percent(performance.gpuPercentage),
                         detail: "Graphics processor",
                         color: .pink,
                         series: [.init(values: performance.gpuHistory, color: .pink)], maximum: 100)
                let bits = format(for: .disk) == .bitsPerSecond
                statTile("Disk", value: MenuBarFormat.detailedRate(performance.diskThroughput?.readBytesPerSecond, bits: bits),
                         detail: "Write \(MenuBarFormat.detailedRate(performance.diskThroughput?.writtenBytesPerSecond, bits: bits))",
                         color: .green,
                         series: [
                            .init(values: performance.diskReadHistory, color: .green),
                            .init(values: performance.diskWriteHistory, color: .orange, filled: false)
                         ], maximum: nil, minimumScale: 1_000_000)
            }
            HStack(spacing: 12) {
                caption("thermometer.medium", "Thermals \(performance.thermalState.activityTitle.lowercased())", color: performance.thermalState.activityColor)
                if let load = performance.loadAverages {
                    caption("gauge.with.needle", String(format: "Load %.2f", load.oneMinute), color: .white.opacity(0.5))
                }
                if let pressure = performance.memory?.pressure {
                    caption("memorychip", "Pressure \(pressure.title.lowercased())", color: pressure == .normal ? .green : .orange)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    private func statTile(_ title: String, value: String, detail: String, color: Color, series: [ActivityChart.Series], maximum: Double?, minimumScale: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            Text(value)
                .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color == .purple || color == .pink || color == .green ? .white : color)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(detail).font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            ActivityChart(series: series, capacity: 40, maximum: maximum, minimumScale: minimumScale, showsGrid: false, lineWidth: 1.4, showsEndDot: false)
                .frame(height: 26)
                .padding(.top, 4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.7))
        .accessibilityElement(children: .combine)
    }

    // MARK: Network

    private var networkSection: some View {
        let path = activities.path
        let connected = path.status == .connected
        let kind = path.primaryInterface.map { SystemInterfaceKind.classify(name: $0, pathType: path.primaryType, wifiNames: activities.wifiInterfaceNames) }
        let bits = format(for: .network) == .bitsPerSecond
        return section {
            HStack(spacing: 10) {
                ActivityIcon(symbol: connected ? (kind?.symbol ?? "network") : "wifi.slash", tint: connected ? (kind?.tint ?? .cyan) : .orange, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(connected ? (kind?.title ?? "Connected") : "Offline").font(.system(size: 13, weight: .semibold))
                    Text(connected ? (path.primaryInterface ?? "") + (path.isConstrained ? " · Low Data Mode" : path.isExpensive ? " · Metered" : "") : "No network connection")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    rateText("arrow.down", MenuBarFormat.detailedRate(performance.networkThroughput?.receivedBytesPerSecond, bits: bits), .cyan)
                    rateText("arrow.up", MenuBarFormat.detailedRate(performance.networkThroughput?.sentBytesPerSecond, bits: bits), .indigo)
                }
            }
            ActivityChart(series: [
                .init(values: performance.networkReceiveHistory, color: .cyan),
                .init(values: performance.networkSendHistory, color: .indigo, filled: false)
            ], capacity: 40, minimumScale: 50_000, showsGrid: false, lineWidth: 1.4, showsEndDot: false)
            .frame(height: 34)
        }
    }

    private func rateText(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
        }
    }

    // MARK: Battery

    private var batterySection: some View {
        let snapshot = battery.snapshot
        let status = limiter.isHelperResponding ? limiter.status : nil
        let percent = status?.batteryPercent ?? system.battery
        let tint: Color = percent <= 10 ? .red : percent <= 20 ? .orange : .green
        return section {
            HStack(spacing: 12) {
                ActivityRing(fraction: Double(percent) / 100, tint: tint, value: "\(percent)%", lineWidth: 5)
                    .scaleEffect(0.62)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(batteryTitle(status: status, snapshot: snapshot)).font(.system(size: 13, weight: .semibold))
                    Text(batteryDetail(status: status, snapshot: snapshot)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                }
                Spacer(minLength: 6)
                if limiter.helperState == .installed {
                    VStack(alignment: .trailing, spacing: 4) {
                        NotchToggle(isOn: $battery.smartLimitEnabled).accessibilityLabel("Charge limit")
                        Text("Limit \(battery.chargeTarget)%").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            HStack(spacing: 6) {
                if let health = snapshot.healthPercent { miniPill("heart.fill", "\(health)%", .green) }
                if let cycles = snapshot.cycleCount { miniPill("arrow.triangle.2.circlepath", "\(cycles) cycles", .blue) }
                if let temperature = snapshot.temperatureCelsius { miniPill("thermometer.medium", String(format: "%.0f° C", temperature), .teal) }
                Spacer(minLength: 0)
                if limiter.helperState == .installed, battery.smartLimitEnabled {
                    if status?.discharging == true || battery.dischargeRequestedAt != nil {
                        smallButton("Stop discharge") { battery.stopDischarge() }
                    } else if status?.toppingUp == true || battery.topUpRequestedAt != nil {
                        smallButton("Stop top up") { battery.stopTopUp() }
                    } else if percent > battery.chargeTarget, status?.supportsDischarge == true {
                        smallButton("Discharge") { battery.startDischarge() }
                    } else if percent < 100 {
                        smallButton("Top up") { battery.startTopUp() }
                    }
                }
            }
        }
    }

    private func batteryTitle(status: ChargeLimitStatus?, snapshot: BatterySnapshot) -> String {
        if let status, status.enabled {
            if status.discharging { return "Discharging to \(status.limit)%" }
            if status.toppingUp { return "Topping up to 100%" }
            if status.pausedForSleep { return "Charging paused for sleep" }
            if status.chargingInhibited && status.adapterConnected { return "Held at \(status.limit)%" }
        }
        if snapshot.isFullyCharged { return "Fully charged" }
        if system.charging { return "Charging" }
        if snapshot.isConnectedToPower { return "On power adapter" }
        return "On battery"
    }

    private func batteryDetail(status: ChargeLimitStatus?, snapshot: BatterySnapshot) -> String {
        if let minutes = snapshot.timeRemainingMinutes, minutes > 0, !snapshot.isConnectedToPower {
            return "About \(minutes / 60)h \(minutes % 60)m remaining"
        }
        if let status, status.enabled, status.chargingInhibited, status.adapterConnected, !status.discharging {
            return "Your Mac runs from the adapter · the light is green"
        }
        if let load = snapshot.systemLoadWatts { return String(format: "Using %.1f W", load) }
        return snapshot.condition == "Normal" ? "Battery condition normal" : snapshot.condition
    }

    // MARK: Storage

    private var storageSection: some View {
        section {
            HStack(spacing: 10) {
                ActivityIcon(symbol: "internaldrive.fill", tint: storageColor, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Startup disk").font(.system(size: 13, weight: .semibold))
                    Text(performance.storage.map { "\(ActivityFormat.bytes($0.available)) free of \(ActivityFormat.bytes($0.capacity))" } ?? "Reading…")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text(ActivityFormat.percent(performance.storage.map { $0.usedFraction * 100 }))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(storageColor)
            }
            ActivityBar(fraction: performance.storage?.usedFraction ?? 0, color: storageColor, height: 6)
        }
    }

    private var storageColor: Color {
        guard let fraction = performance.storage?.usedFraction else { return .indigo }
        return fraction >= 0.95 ? .red : fraction >= 0.85 ? .orange : .indigo
    }

    // MARK: AI usage

    private var aiProviders: [(AIUsageProviderID, AIUsageSnapshot)] {
        AIUsageProviderID.allCases.compactMap { provider in
            guard usage.isEnabled(provider), let snapshot = usage.snapshot(for: provider), snapshot.metrics.contains(where: { $0.quota != nil }) else { return nil }
            return (provider, snapshot)
        }
    }

    private var aiSection: some View {
        section {
            ForEach(Array(aiProviders.enumerated()), id: \.element.0) { index, entry in
                if index > 0 { Divider().overlay(Color.white.opacity(0.05)) }
                let (provider, snapshot) = entry
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        AIProviderBrandView(provider: provider, size: 15)
                        Text(provider.displayName).font(.system(size: 13, weight: .semibold))
                        if let plan = snapshot.plan {
                            Text(plan).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                                .padding(.horizontal, 5).padding(.vertical, 1.5).background(.white.opacity(0.08), in: Capsule())
                        }
                        Spacer()
                        Text(usage.showRemaining ? "remaining" : "used").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                    }
                    ForEach(snapshot.metrics.filter { $0.quota != nil }) { metric in
                        if let quota = metric.quota {
                            quotaRow(metric.title, quota)
                        }
                    }
                }
            }
        }
    }

    private func quotaRow(_ title: String, _ quota: AIUsageQuota) -> some View {
        let fraction = usage.showRemaining ? quota.remainingFraction : quota.usedFraction
        let color: Color = quota.usedFraction >= 0.9 ? .red : quota.usedFraction >= 0.7 ? .orange : .green
        let pace = AIUsageFormat.pace(for: quota)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                Spacer()
                Text(AIUsageFormat.quotaHeadline(quota, showRemaining: usage.showRemaining))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            }
            GeometryReader { geometry in
                ActivityBar(fraction: fraction, color: color, height: 5)
                    .overlay(alignment: .leading) {
                        if let pace {
                            paceMarker(
                                track: geometry.size.width,
                                fraction: pace.markerFraction(showRemaining: usage.showRemaining)
                            )
                        }
                    }
            }
            .frame(height: 5)
            if quota.resetsAt != nil {
                HStack(spacing: 8) {
                    Text(AIUsageFormat.resetText(quota.resetsAt, exact: usage.exactResetTimes))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer(minLength: 4)
                    if let pace {
                        Text(pace.label)
                            .foregroundStyle(paceColor(pace.status).opacity(0.9))
                    }
                }
                .font(.system(size: 9).monospacedDigit())
                .lineLimit(1)
            }
        }
    }

    private func paceColor(_ status: AIUsagePaceProjection.Status) -> Color {
        switch status {
        case .ahead: .blue
        case .close: .orange
        case .over: .red
        }
    }

    private func paceMarker(track: CGFloat, fraction: Double) -> some View {
        let width: CGFloat = 2
        let x = min(max(track * fraction - width / 2, 0), max(track - width, 0))
        return RoundedRectangle(cornerRadius: 1)
            .fill(.white.opacity(0.72))
            .frame(width: width, height: 11)
            .offset(x: x)
            .accessibilityHidden(true)
    }

    // MARK: Apps and actions

    private var appsSection: some View {
        section {
            HStack {
                Text("MOST ACTIVE APPS").font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            ActiveAppsList(monitor: apps, maximumRows: 4)
        }
    }

    private var actionsSection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            action("command.square.fill", "Palette", .indigo) { AppDelegate.shared?.openCommandPalette() }
            action("list.clipboard.fill", "Clipboard", .purple) { AppDelegate.shared?.openClipboard() }
            action("basket.fill", "Basket", .orange) { AppDelegate.shared?.openBasket() }
            action("capsule.fill", "Island", .blue) { AppDelegate.shared?.toggleShelf() }
            action("note.text", "Notes", .yellow) { AppDelegate.shared?.openNotesWidget() }
            action("calendar", "Agenda", .red) { AppDelegate.shared?.openAgendaWidget() }
            action("gauge.with.dots.needle.33percent", "Activity", .green) {
                AppState.shared.page = .tools
                AppState.shared.toolGroup = ToolGroup.activity.rawValue
                AppState.shared.toolDetail = ""
                AppDelegate.shared?.openWorkspace()
            }
            action("macwindow", "Open", .gray) { AppDelegate.shared?.openWorkspace() }
        }
    }

    private func action(_ symbol: String, _ title: String, _ tint: Color, run: @escaping () -> Void) -> some View {
        Button { perform(run) } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle())
        .help(title)
    }

    private var footer: some View {
        HStack {
            Text("Right-click the icon for the classic menu")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 4).padding(.top, 2)
    }

    // MARK: Helpers

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.7))
    }

    private func caption(_ symbol: String, _ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .fixedSize()
    }

    private func miniPill(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
            Text(text).font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.white.opacity(0.06), in: Capsule())
        .fixedSize()
    }

    private func smallButton(_ title: String, run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .buttonStyle(PillButtonStyle())
            .controlSize(.small)
    }

    private func format(for id: MenuBarModuleID) -> MenuBarValueFormat? {
        preferences.setting(for: id).resolvedFormat
    }

    private func loadColor(_ value: Double?, base: Color) -> Color {
        guard let value else { return base }
        if value >= 85 { return .red }
        if value >= 65 { return .orange }
        return base
    }

    /// Closes the panel before running an action that opens another window.
    private func perform(_ run: @escaping () -> Void) {
        close()
        DispatchQueue.main.async { run() }
    }
}
