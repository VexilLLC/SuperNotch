import SwiftUI
import AppKit

struct AIProviderBrandView: View {
    let provider: AIUsageProviderID
    var size: CGFloat = 22

    private var image: NSImage? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("ProviderIcons/\(provider.iconName).svg"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/ProviderIcons/\(provider.iconName).svg")
        ].compactMap { $0 }
        for url in candidates {
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                return image
            }
        }
        return nil
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: provider.fallbackSymbol).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }
}

/// OpenUsage-style compact trend row: a calm label plus calendar-ordered bars.
/// Hover or click reveals the larger per-day chart without making the notch
/// carry axes and labels all the time.
struct AIUsageTrendRow: View {
    let points: [AIUsageHistoryPoint]
    var title = "Usage Trend"

    @State private var showingDetail = false
    @State private var closeTask: Task<Void, Never>?

    private var visiblePoints: [AIUsageHistoryPoint] { Array(points.suffix(18)) }

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: "chart.bar.xaxis")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
            Spacer(minLength: 8)
            bars
                .frame(width: 150, height: 25)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.white.opacity(showingDetail ? 0.1 : 0.045), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
                .onTapGesture { showingDetail.toggle() }
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        closeTask?.cancel()
                        showingDetail = true
                    case .ended:
                        scheduleClose()
                    }
                }
                .popover(isPresented: $showingDetail, arrowEdge: .top) {
                    AIUsageTrendDetail(points: points) { inside in
                        closeTask?.cancel()
                        if !inside { scheduleClose() }
                    }
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(points.count) days, peak \(peakReadout)")
        .onDisappear { closeTask?.cancel() }
    }

    private var bars: some View {
        let maximum = max(1, visiblePoints.map(\.chartValue).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(visiblePoints) { point in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.blue.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .frame(height: barHeight(point.chartValue, maximum: maximum, height: 25))
            }
        }
    }

    private var peakReadout: String {
        points.max(by: { $0.chartValue < $1.chartValue }).map(AIUsageFormat.historyReadout) ?? "No data"
    }

    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await MainActor.run { showingDetail = false }
        }
    }

    private func barHeight(_ value: Double, maximum: Double, height: CGFloat) -> CGFloat {
        guard value > 0 else { return 2 }
        return max(height * 0.16, height * min(1, value / maximum))
    }
}

private struct AIUsageTrendDetail: View {
    let points: [AIUsageHistoryPoint]
    var onHoverChange: (Bool) -> Void
    @State private var activeIndex: Int?

    private let chartHeight: CGFloat = 82

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage Trend").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(readout).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
            chart
            HStack {
                Text(points.first?.day ?? "")
                Spacer()
                Text(points.last?.day ?? "")
            }
            .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            Label("From local provider logs · last 30 days", systemImage: "lock.fill")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280)
        .onContinuousHover { phase in
            if case .active = phase { onHoverChange(true) }
            else { onHoverChange(false); activeIndex = nil }
        }
    }

    private var chart: some View {
        let maximum = max(1, points.map(\.chartValue).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(points.indices, id: \.self) { index in
                Color.clear.frame(maxWidth: .infinity).frame(height: chartHeight)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.accentColor)
                            .frame(height: height(points[index].chartValue, maximum: maximum))
                            .opacity(activeIndex == nil || activeIndex == index ? 1 : 0.28)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in if case .active = phase { activeIndex = index } }
            }
        }
        .frame(height: chartHeight)
        .animation(.easeOut(duration: 0.12), value: activeIndex)
    }

    private var peakIndex: Int? { points.indices.max { points[$0].chartValue < points[$1].chartValue } }
    private var readout: String {
        let index = activeIndex ?? peakIndex
        guard let index, points.indices.contains(index) else { return "" }
        let prefix = activeIndex == nil ? "Peak" : points[index].day
        return "\(prefix) · \(AIUsageFormat.historyReadout(points[index]))"
    }
    private func height(_ value: Double, maximum: Double) -> CGFloat {
        guard value > 0 else { return 2 }
        return max(chartHeight * 0.07, chartHeight * min(1, value / maximum))
    }
}

private struct AIUsageSpendStrip: View {
    let metrics: [AIUsageMetric]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(metrics.prefix(3)) { metric in
                if case .value(let value) = metric.payload {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.title).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.42))
                        Text(AIUsageFormat.value(value)).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                        if let detail = value.detail { Text(detail).font(.system(size: 7)).foregroundStyle(.white.opacity(0.34)).lineLimit(1) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }
}

/// Fades the bottom edge of a short scroll area so clipped rows read as "more below".
struct ScrollFadeMask: View {
    var body: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 14)
        }
    }
}

struct AIUsageWidgetView: View {
    @ObservedObject private var store = AIUsageStore.shared
    @State private var selectedProvider: AIUsageProviderID?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 9) {
                header(now: context.date)
                providerRail
                Group {
                    if let selectedProvider {
                        providerDetail(selectedProvider, now: context.date)
                    } else {
                        overview(now: context.date)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .task { await store.refreshAll(force: false) }
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(IslandMotion.open) { selectedProvider = nil }
            } label: {
                Image(systemName: selectedProvider == nil ? "chart.bar.fill" : "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectedProvider == nil ? "AI Usage overview" : "Back to AI Usage overview")

            Text(selectedProvider?.displayName ?? "AI Usage")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            if let selectedProvider, let plan = store.snapshot(for: selectedProvider)?.plan {
                Text(plan).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.07), in: Capsule())
            }
            Spacer()
            if let latest = store.snapshots.values.map(\.fetchedAt).max() {
                Text(relativeUpdate(latest, now: now))
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.38))
            }
            Button { Task { await store.refreshAll(force: true) } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Refresh AI usage")
        }
    }

    private var providerRail: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(AIUsageProviderID.allCases) { provider in
                    let enabled = store.isEnabled(provider)
                    let selected = selectedProvider == provider
                    Button {
                        guard enabled else { return }
                        withAnimation(IslandMotion.open) { selectedProvider = provider }
                    } label: {
                        HStack(spacing: 5) {
                            AIProviderBrandView(provider: provider, size: 13)
                            Text(provider.displayName).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                            Circle().fill(statusColor(provider)).frame(width: 5, height: 5)
                        }
                        .foregroundStyle(.white.opacity(enabled ? (selected ? 1 : 0.72) : 0.25))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(selected ? Color.white.opacity(0.12) : Color.white.opacity(0.055), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                }
            }
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func overview(now: Date) -> some View {
        let spendHistory = combinedSpendHistory
        // The island is short, so the overview scrolls instead of dropping limits.
        let items = store.attentionItems
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: store.enabledProviders.isEmpty ? "switch.2" : "hourglass")
                    .font(.system(size: 22)).foregroundStyle(.white.opacity(0.35))
                Text(store.enabledProviders.isEmpty ? "Enable a provider in Settings" : "Waiting for usage data")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                Button("Open AI Usage Settings") { SettingsWindowController.shared.show(section: .aiUsage) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
            VStack(spacing: 6) {
                if !spendHistory.isEmpty {
                    HStack(spacing: 9) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("30-day spend").font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.42))
                            Text(totalSpend(spendHistory).formatted(.currency(code: "USD").precision(.fractionLength(2))))
                                .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                        }
                        Spacer()
                        AIUsageTrendRow(points: spendHistory, title: "")
                            .frame(width: 186)
                    }
                }
                ForEach(items) { item in
                    attentionRow(item, now: now)
                }
            }
            .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .mask(ScrollFadeMask())
        }
    }

    private func attentionRow(_ item: AIUsageAttentionItem, now: Date) -> some View {
        let quota = item.metric.quota!
        return Button {
            withAnimation(IslandMotion.open) { selectedProvider = item.providerID }
        } label: {
            HStack(spacing: 9) {
                AIProviderBrandView(provider: item.providerID, size: 18)
                    .foregroundStyle(severityColor(item.severity))
                    .frame(width: 28, height: 28)
                    .background(severityColor(item.severity).opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(item.providerID.displayName).font(.system(size: 10, weight: .semibold))
                        Text(item.metric.title).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Text(AIUsageFormat.quotaHeadline(quota, showRemaining: store.showRemaining))
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.1))
                            Capsule().fill(severityColor(item.severity)).frame(width: geometry.size.width * quota.remainingFraction)
                        }
                        .overlay(alignment: .leading) {
                            if let pace = AIUsageFormat.pace(for: quota, now: now) {
                                paceMarker(track: geometry.size.width, fraction: pace.markerFraction(showRemaining: store.showRemaining))
                            }
                        }
                    }.frame(height: 4)
                    Text(AIUsageFormat.resetText(quota.resetsAt, exact: store.exactResetTimes, now: now))
                        .font(.system(size: 8).monospacedDigit()).foregroundStyle(.white.opacity(0.38))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.providerID.displayName), \(item.metric.title), \(AIUsageFormat.quotaHeadline(quota, showRemaining: store.showRemaining)), \(AIUsageFormat.resetText(quota.resetsAt, exact: store.exactResetTimes, now: now))")
    }

    @ViewBuilder
    private func providerDetail(_ provider: AIUsageProviderID, now: Date) -> some View {
        if let snapshot = store.snapshot(for: provider) {
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(Array(snapshot.metrics.filter { $0.quota != nil }.prefix(3))) { metric in
                        metricRow(metric, provider: provider, now: now)
                    }
                    if let history = snapshot.history, !history.isEmpty {
                        AIUsageTrendRow(points: history)
                    }
                    let periodIDs: Set<String> = ["today", "yesterday", "last30"]
                    let periodValues = snapshot.metrics.filter { periodIDs.contains($0.id) }
                    if !periodValues.isEmpty { AIUsageSpendStrip(metrics: periodValues) }
                    ForEach(snapshot.metrics.filter { metric in
                        guard !periodIDs.contains(metric.id), metric.quota == nil else { return false }
                        if case .value = metric.payload { return true }
                        return false
                    }) { metric in
                        metricRow(metric, provider: provider, now: now)
                    }
                    if let warning = snapshot.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 8)).foregroundStyle(.orange).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if case .unavailable(let error) = store.status(for: provider) {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.system(size: 8)).foregroundStyle(.orange).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .mask(ScrollFadeMask())
        } else {
            VStack(spacing: 8) {
                AIProviderBrandView(provider: provider, size: 28).foregroundStyle(.white.opacity(0.35))
                Text(statusText(provider)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                Button("Refresh") { Task { await store.refresh(provider, force: true) } }
                    .font(.system(size: 10, weight: .semibold)).buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func metricRow(_ metric: AIUsageMetric, provider: AIUsageProviderID, now: Date) -> some View {
        Group {
            switch metric.payload {
            case .quota(let quota):
                let pace = AIUsageFormat.pace(for: quota, now: now)
                let severity = AIUsageFormat.severity(for: quota, now: now)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(metric.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Spacer()
                        if let pace {
                            Text(pace.label)
                                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                .foregroundStyle(severityColor(severity).opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(severityColor(severity)).frame(width: geometry.size.width * quota.remainingFraction)
                    }
                    .overlay(alignment: .leading) {
                        if let pace {
                            paceMarker(track: geometry.size.width, fraction: pace.markerFraction(showRemaining: store.showRemaining))
                        }
                    }
                }.frame(height: 6)
                    HStack(spacing: 8) {
                        Text(AIUsageFormat.quotaHeadline(quota, showRemaining: store.showRemaining))
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                        Spacer()
                        Text(AIUsageFormat.resetText(quota.resetsAt, exact: store.exactResetTimes, now: now))
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
                    }
                }
            case .value(let value):
                HStack(spacing: 10) {
                    Text(metric.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(AIUsageFormat.value(value)).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                        if let detail = value.detail { Text(detail).font(.system(size: 8)).foregroundStyle(.white.opacity(0.4)) }
                    }
                }
            case .status(let text):
                HStack { Text(metric.title).font(.system(size: 10, weight: .medium)); Spacer(); Text(text).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func statusColor(_ provider: AIUsageProviderID) -> Color {
        switch store.status(for: provider) {
        case .refreshing: return .blue
        case .available:
            let worst = store.snapshot(for: provider)?.metrics.compactMap(\.quota).map { AIUsageFormat.severity(for: $0) }.max() ?? .healthy
            return severityColor(worst)
        case .unavailable: return .orange
        case .idle: return .gray
        }
    }

    private func statusText(_ provider: AIUsageProviderID) -> String {
        switch store.status(for: provider) {
        case .refreshing: return "Refreshing \(provider.displayName)…"
        case .available: return "No displayable usage yet."
        case .unavailable(let error): return error
        case .idle: return "Enable and refresh \(provider.displayName) in Settings."
        }
    }

    private func severityColor(_ severity: AIUsageSeverity) -> Color {
        switch severity {
        case .healthy: .blue
        case .warning: .orange
        case .critical: .red
        case .unavailable: .gray
        }
    }

    private func relativeUpdate(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Updated now" }
        return "Updated \(seconds / 60)m ago"
    }

    private var combinedSpendHistory: [AIUsageHistoryPoint] {
        var days: [String: (tokens: Int, cost: Double)] = [:]
        for point in store.snapshots.values.flatMap({ $0.history ?? [] }) {
            guard let cost = point.costUSD else { continue }
            days[point.day, default: (0, 0)].tokens += point.tokens
            days[point.day, default: (0, 0)].cost += cost
        }
        return days.keys.sorted().map { day in
            AIUsageHistoryPoint(day: day, tokens: days[day]?.tokens ?? 0, costUSD: days[day]?.cost)
        }
    }

    private func totalSpend(_ points: [AIUsageHistoryPoint]) -> Double {
        points.compactMap(\.costUSD).reduce(0, +)
    }
}

struct AIUsageSettingsPage: View {
    @ObservedObject private var store = AIUsageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Providers") {
                ForEach(Array(AIUsageProviderID.allCases.enumerated()), id: \.element) { index, provider in
                    SettingsRow(
                        symbol: provider.fallbackSymbol,
                        color: providerColor(provider),
                        title: provider.displayName,
                        detail: providerDetail(provider),
                        divider: index < AIUsageProviderID.allCases.count - 1
                    ) {
                        HStack(spacing: 9) {
                            if case .refreshing = store.status(for: provider) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button { Task { await store.refresh(provider, force: true) } } label: {
                                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                                }.buttonStyle(IslandPressStyle()).disabled(!store.isEnabled(provider))
                            }
                            NotchToggle(isOn: Binding(
                                get: { store.isEnabled(provider) },
                                set: { store.setEnabled($0, for: provider) }
                            ))
                        }
                    }
                }
            }

            SettingsCard(title: "Claude privacy") {
                SettingsRow(
                    symbol: "key.fill",
                    color: .orange,
                    title: "Claude Code Keychain access",
                    detail: "Off by default. Enable only if you want SuperNotch to request Claude's saved login for live limits.",
                    divider: false
                ) {
                    NotchToggle(isOn: Binding(
                        get: { store.claudeKeychainAccessEnabled },
                        set: { store.setClaudeKeychainAccess($0) }
                    ))
                }
            }

            OpenCodeGoKeySettings(store: store)

            SettingsCard(title: "Notch") {
                SettingsRow(symbol: "pin.fill", color: .purple, title: "Pinned usage", detail: "Show one remaining quota in the collapsed notch.") {
                    NotchToggle(isOn: $store.pinEnabled)
                }
                SettingsRow(symbol: "sparkles", color: .blue, title: "Pinned provider", divider: false) {
                    Picker("Pinned provider", selection: $store.pinnedProvider) {
                        ForEach(AIUsageProviderID.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden().frame(width: 130)
                }
            }

            SettingsCard(title: "Display") {
                SettingsRow(symbol: "percent", color: .blue, title: "Quota values") {
                    ChipPicker(options: [(true, "Remaining"), (false, "Used")], selection: $store.showRemaining)
                }
                SettingsRow(symbol: "clock.fill", color: .orange, title: "Reset times", divider: false) {
                    ChipPicker(options: [(false, "Countdown"), (true, "Exact")], selection: $store.exactResetTimes)
                }
            }

            SettingsCard(title: "Alerts & privacy") {
                SettingsRow(symbol: "bell.badge.fill", color: .red, title: "Usage activities", detail: "Show an activity when a quota crosses 20% or 10%, or resets.") {
                    NotchToggle(isOn: $store.usageAlertsEnabled)
                }
                SettingsRow(symbol: "lock.shield.fill", color: .green, title: "Local credentials", detail: "SuperNotch reads local provider files automatically. Access to another app's Keychain login is always opt-in. Only normalized usage snapshots are cached.", divider: false) {
                    EmptyView()
                }
            }
        }
        .task { await store.detectAndSeedProviders() }
    }

    private func providerDetail(_ provider: AIUsageProviderID) -> String {
        let prefix = store.detectedProviders.contains(provider) ? "Detected" : "Not detected"
        switch store.status(for: provider) {
        case .available:
            if let snapshot = store.snapshot(for: provider) {
                return "\(prefix) · Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
            }
            return prefix
        case .refreshing: return "\(prefix) · Refreshing…"
        case .unavailable(let error): return "\(prefix) · \(error)"
        case .idle: return prefix
        }
    }

    private func providerColor(_ provider: AIUsageProviderID) -> Color {
        switch provider {
        case .codex: .green
        case .claude: .orange
        case .openCode: .blue
        }
    }
}

private struct OpenCodeGoKeySettings: View {
    @ObservedObject var store: AIUsageStore
    @State private var editing = false
    @State private var reveal = false
    @State private var key = ""
    @State private var errorText: String?

    var body: some View {
        SettingsCard(title: "OpenCode Go API Key") {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    AIProviderBrandView(provider: .openCode, size: 20).foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenCode Go").font(.system(size: 13, weight: .semibold))
                        Text(sourceDetail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.46))
                    }
                    Spacer()
                    Circle().fill(store.openCodeKeySource == .missing ? Color.red : Color.green).frame(width: 7, height: 7)
                    Button(editing ? "Done" : actionTitle) {
                        if editing { cancelEditing() } else { beginEditing() }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)

                if editing {
                    Divider().overlay(.white.opacity(0.07))
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Group {
                                if reveal { TextField("OpenCode Go key", text: $key) }
                                else { SecureField("OpenCode Go key", text: $key) }
                            }
                            .textFieldStyle(.roundedBorder)
                            Button { reveal.toggle() } label: {
                                Image(systemName: reveal ? "eye.slash" : "eye").frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless).accessibilityLabel(reveal ? "Hide API key" : "Show API key")
                        }
                        HStack(spacing: 10) {
                            Button("Save Key") { save() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if store.openCodeKeySource == .custom {
                                Button("Clear Custom Key", role: .destructive) { clear() }
                                    .buttonStyle(.borderless).controlSize(.small)
                            }
                            Spacer()
                            Link("Open OpenCode dashboard", destination: URL(string: "https://opencode.ai/auth")!)
                                .font(.system(size: 10))
                        }
                        if let errorText {
                            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10)).foregroundStyle(.orange)
                        }
                        Text("A custom key overrides OpenCode's local login. It is stored in your macOS Keychain and sent only to opencode.ai.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.38))
                    }
                    .padding(14)
                    .background(.white.opacity(0.025))
                }
            }
        }
        .onAppear { store.refreshCredentialStatus() }
    }

    private var actionTitle: String {
        switch store.openCodeKeySource {
        case .missing: "Add"
        case .openCode: "Override"
        case .custom: "Edit"
        }
    }

    private var sourceDetail: String {
        switch store.openCodeKeySource {
        case .missing: "No key set · add a Go key to load live limits"
        case .openCode: "Using the key from OpenCode's local login"
        case .custom: "Using a custom key saved in Keychain"
        }
    }

    private func beginEditing() {
        key = store.currentOpenCodeCustomKey() ?? ""
        reveal = false
        errorText = nil
        withAnimation(IslandMotion.open) { editing = true }
    }

    private func cancelEditing() {
        key = ""
        reveal = false
        errorText = nil
        withAnimation(IslandMotion.open) { editing = false }
    }

    private func save() {
        do {
            try store.saveOpenCodeKey(key)
            cancelEditing()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clear() {
        do {
            try store.clearOpenCodeCustomKey()
            cancelEditing()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
