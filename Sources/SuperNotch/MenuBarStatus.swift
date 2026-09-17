import SwiftUI
import AppKit
import Combine
import ChargeLimitCore

// MARK: - Modules

/// Things that can be shown in the SuperNotch menu bar item.
/// Raw values are persisted; keep them stable.
enum MenuBarModuleID: String, CaseIterable, Codable, Identifiable, Sendable {
    case logo
    case cpu
    case memory
    case gpu
    case network
    case disk
    case battery
    case storage
    /// How many ports processes on this Mac listen on.
    case ports
    /// Every enabled AI provider stacked into one item.
    case aiUsage
    case claude
    case codex
    case openCode = "opencode"
    case focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logo: return "SuperNotch icon"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .gpu: return "GPU"
        case .network: return "Network"
        case .disk: return "Disk activity"
        case .battery: return "Battery"
        case .storage: return "Free storage"
        case .ports: return "Open ports"
        case .aiUsage: return "AI usage (combined)"
        case .claude: return "Claude usage"
        case .codex: return "Codex usage"
        case .openCode: return "OpenCode usage"
        case .focus: return "Focus timer"
        }
    }

    var symbol: String {
        switch self {
        case .logo: return "rectangle.topthird.inset.filled"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu: return "square.stack.3d.up.fill"
        case .network: return "arrow.up.arrow.down"
        case .disk: return "internaldrive.fill"
        case .battery: return "battery.75percent"
        case .storage: return "externaldrive.fill"
        case .ports: return "powerplug.fill"
        case .aiUsage: return "line.3.horizontal"
        case .claude, .codex, .openCode: return "chart.bar.fill"
        case .focus: return "timer"
        }
    }

    var tint: Color {
        switch self {
        case .logo: return .gray
        case .cpu: return .blue
        case .memory: return .purple
        case .gpu: return .pink
        case .network: return .cyan
        case .disk: return .green
        case .battery: return .green
        case .storage: return .indigo
        case .ports: return .teal
        case .aiUsage: return .orange
        case .claude: return .orange
        case .codex: return .teal
        case .openCode: return .mint
        case .focus: return .orange
        }
    }

    /// Styles offered in settings, first is the default.
    var styles: [MenuBarModuleStyle] {
        switch self {
        case .cpu, .memory, .gpu: return [.value, .bar, .graph]
        case .network, .disk: return [.value, .graph]
        case .claude, .codex, .openCode: return [.bar, .value]
        case .logo, .battery, .storage, .focus, .aiUsage, .ports: return [.value]
        }
    }

    /// Units or value formats offered in settings, first is the default.
    var formats: [MenuBarValueFormat] {
        switch self {
        case .network, .disk: return [.bytesPerSecond, .bitsPerSecond]
        case .memory: return [.percent, .used, .free]
        case .storage: return [.free, .used, .percent]
        case .battery: return [.percent, .timeRemaining]
        case .aiUsage: return [.onePerApp, .everyLimit]
        default: return []
        }
    }

    var aiProvider: AIUsageProviderID? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .openCode: return .openCode
        default: return nil
        }
    }

    /// Whether showing this module needs the live system sampler running.
    var needsPerformanceSampling: Bool {
        switch self {
        case .cpu, .memory, .gpu, .network, .disk, .storage: return true
        default: return false
        }
    }

    /// Whether showing this module needs the listening-port scanner running.
    var needsPortScanning: Bool { self == .ports }
}

enum MenuBarModuleStyle: String, Codable, Sendable {
    case value
    case bar
    case graph

    var title: String {
        switch self {
        case .value: return "Value"
        case .bar: return "Bar"
        case .graph: return "Graph"
        }
    }
}

enum MenuBarValueFormat: String, Codable, Sendable {
    case bytesPerSecond
    case bitsPerSecond
    case percent
    case used
    case free
    case timeRemaining
    case onePerApp
    case everyLimit

    var title: String {
        switch self {
        case .bytesPerSecond: return "MB/s"
        case .bitsPerSecond: return "Mbps"
        case .percent: return "%"
        case .used: return "Used"
        case .free: return "Free"
        case .timeRemaining: return "Time left"
        case .onePerApp: return "One per app"
        case .everyLimit: return "Every limit"
        }
    }
}

struct MenuBarModuleSetting: Codable, Equatable, Identifiable, Sendable {
    var id: MenuBarModuleID
    var visible: Bool
    var style: MenuBarModuleStyle
    var format: MenuBarValueFormat? = nil

    /// The effective format, falling back to the module's default.
    var resolvedFormat: MenuBarValueFormat? {
        if let format, id.formats.contains(format) { return format }
        return id.formats.first
    }
}

/// Sections of the panel that opens when the menu bar item is clicked.
enum MenuBarPanelSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case network
    case ports
    case battery
    case storage
    case aiUsage
    case apps
    case actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "CPU, memory, GPU and disk"
        case .network: return "Network"
        case .ports: return "Open ports"
        case .battery: return "Battery and charge limit"
        case .storage: return "Storage"
        case .aiUsage: return "AI usage"
        case .apps: return "Most active apps"
        case .actions: return "Quick actions"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "cpu"
        case .network: return "network"
        case .ports: return "powerplug.fill"
        case .battery: return "battery.75percent"
        case .storage: return "internaldrive.fill"
        case .aiUsage: return "chart.bar.fill"
        case .apps: return "square.grid.2x2.fill"
        case .actions: return "bolt.fill"
        }
    }

    var tint: Color {
        switch self {
        case .system: return .blue
        case .network: return .cyan
        case .ports: return .teal
        case .battery: return .green
        case .storage: return .indigo
        case .aiUsage: return .orange
        case .apps: return .teal
        case .actions: return .yellow
        }
    }
}

// MARK: - Preferences

@MainActor
final class MenuBarPreferences: ObservableObject {
    static let shared = MenuBarPreferences()

    static let itemsKey = "menuBar.items.v1"
    static let labelsKey = "menuBar.showsLabels"
    static let colorfulKey = "menuBar.colorful"
    static let hiddenSectionsKey = "menuBar.panel.hiddenSections"
    static let portsExpandedKey = "menuBar.panel.portsExpanded"

    /// Every module in display order, visible or not.
    @Published private(set) var items: [MenuBarModuleSetting]
    @Published var showsLabels: Bool {
        didSet { defaults.set(showsLabels, forKey: Self.labelsKey) }
    }
    @Published var colorful: Bool {
        didSet { defaults.set(colorful, forKey: Self.colorfulKey) }
    }
    @Published private(set) var hiddenPanelSections: Set<MenuBarPanelSection>
    /// Whether the open ports list is unfolded. It starts closed and stays the
    /// way it was last left, so the panel is calm until ports are wanted.
    @Published var portsExpanded: Bool {
        didSet { defaults.set(portsExpanded, forKey: Self.portsExpandedKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Self.sanitize(defaults.data(forKey: Self.itemsKey))
        showsLabels = defaults.object(forKey: Self.labelsKey) as? Bool ?? true
        colorful = defaults.object(forKey: Self.colorfulKey) as? Bool ?? true
        hiddenPanelSections = Set((defaults.stringArray(forKey: Self.hiddenSectionsKey) ?? []).compactMap(MenuBarPanelSection.init(rawValue:)))
        portsExpanded = defaults.bool(forKey: Self.portsExpandedKey)
    }

    func showsPanelSection(_ section: MenuBarPanelSection) -> Bool { !hiddenPanelSections.contains(section) }

    func setPanelSection(_ section: MenuBarPanelSection, visible: Bool) {
        if visible { hiddenPanelSections.remove(section) } else { hiddenPanelSections.insert(section) }
        defaults.set(hiddenPanelSections.map(\.rawValue).sorted(), forKey: Self.hiddenSectionsKey)
    }

    func setFormat(_ id: MenuBarModuleID, _ format: MenuBarValueFormat) {
        guard id.formats.contains(format), let index = items.firstIndex(where: { $0.id == id }), items[index].resolvedFormat != format else { return }
        items[index].format = format
        persist()
    }

    static var defaultItems: [MenuBarModuleSetting] {
        MenuBarModuleID.allCases.map { MenuBarModuleSetting(id: $0, visible: $0 == .logo, style: $0.styles[0], format: $0.formats.first) }
    }

    var visibleItems: [MenuBarModuleSetting] { items.filter(\.visible) }

    func setting(for id: MenuBarModuleID) -> MenuBarModuleSetting {
        items.first { $0.id == id } ?? MenuBarModuleSetting(id: id, visible: false, style: id.styles[0], format: id.formats.first)
    }

    func setVisible(_ id: MenuBarModuleID, _ visible: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].visible != visible else { return }
        items[index].visible = visible
        persist()
    }

    func setStyle(_ id: MenuBarModuleID, _ style: MenuBarModuleStyle) {
        guard id.styles.contains(style), let index = items.firstIndex(where: { $0.id == id }), items[index].style != style else { return }
        items[index].style = style
        persist()
    }

    func move(_ id: MenuBarModuleID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index + offset, 0), items.count - 1)
        guard destination != index else { return }
        let item = items.remove(at: index)
        items.insert(item, at: destination)
        persist()
    }

    func reset() {
        items = Self.defaultItems
        showsLabels = true
        colorful = true
        hiddenPanelSections = []
        portsExpanded = false
        defaults.removeObject(forKey: Self.hiddenSectionsKey)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.itemsKey) }
    }

    /// Reads stored settings leniently: unknown modules and styles are
    /// dropped, duplicates keep their first position, and modules added in
    /// newer versions are appended hidden.
    static func sanitize(_ data: Data?) -> [MenuBarModuleSetting] {
        struct Stored: Decodable { var id: String; var visible: Bool?; var style: String?; var format: String? }
        guard let data, let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return defaultItems }
        var result: [MenuBarModuleSetting] = []
        for entry in stored {
            guard let id = MenuBarModuleID(rawValue: entry.id), !result.contains(where: { $0.id == id }) else { continue }
            let style = entry.style.flatMap(MenuBarModuleStyle.init(rawValue:)).flatMap { id.styles.contains($0) ? $0 : nil } ?? id.styles[0]
            let format = entry.format.flatMap(MenuBarValueFormat.init(rawValue:)).flatMap { id.formats.contains($0) ? $0 : nil } ?? id.formats.first
            result.append(MenuBarModuleSetting(id: id, visible: entry.visible ?? false, style: style, format: format))
        }
        for id in MenuBarModuleID.allCases where !result.contains(where: { $0.id == id }) {
            result.append(MenuBarModuleSetting(id: id, visible: false, style: id.styles[0], format: id.formats.first))
        }
        return result
    }
}

// MARK: - Status item

/// Hosts SwiftUI content inside the status bar button without swallowing clicks,
/// so the button still opens the SuperNotch menu.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    private(set) var statusItem: NSStatusItem?
    private var hostingView: NSView?
    private var menu: NSMenu?
    private var popover: NSPopover?
    private var cancellables: Set<AnyCancellable> = []
    private var holdsPerformanceLease = false
    private var holdsPortLease = false

    /// Left-click opens the details panel; right-click or Control-click shows `menu`.
    func install(menu: NSMenu) -> NSStatusItem {
        self.menu = menu
        let item = NSStatusBar.system.statusItem(withLength: 26)
        if let button = item.button {
            button.image = nil
            button.title = ""
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("SuperNotch")
            let host = PassthroughHostingView(rootView: MenuBarStatusView(onWidthChange: { [weak self] width in
                self?.updateLength(width)
            }))
            host.sizingOptions = []
            host.frame = button.bounds
            host.autoresizingMask = [.width, .height]
            button.addSubview(host)
            hostingView = host
        }
        statusItem = item

        MenuBarPreferences.shared.$items
            .map { items in items.contains { $0.visible && $0.id.needsPerformanceSampling } }
            .removeDuplicates()
            .sink { [weak self] needed in self?.setSamplingNeeded(needed) }
            .store(in: &cancellables)
        MenuBarPreferences.shared.$items
            .map { items in items.contains { $0.visible && $0.id.needsPortScanning } }
            .removeDuplicates()
            .sink { [weak self] needed in self?.setPortScanningNeeded(needed) }
            .store(in: &cancellables)
        return item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    func showMenu() {
        closePanel()
        guard let statusItem, let menu else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func togglePanel() {
        if popover?.isShown == true {
            closePanel()
            return
        }
        guard let button = statusItem?.button else { return }
        let popover = self.popover ?? {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.appearance = NSAppearance(named: .darkAqua)
            popover.delegate = self
            self.popover = popover
            return popover
        }()
        // A fresh view tree per opening, released on close, so nothing samples while hidden.
        let controller = NSHostingController(rootView: MenuBarPanelView(close: { [weak self] in self?.closePanel() }))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePanel() {
        popover?.performClose(nil)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover?.contentViewController = nil
        }
    }

    private func updateLength(_ width: CGFloat) {
        let length = max(22, (width + 8).rounded(.up))
        guard let statusItem, abs(statusItem.length - length) >= 1 else { return }
        statusItem.length = length
    }

    private func setPortScanningNeeded(_ needed: Bool) {
        guard needed != holdsPortLease else { return }
        holdsPortLease = needed
        if needed {
            OpenPortsMonitor.shared.acquireLease()
        } else {
            OpenPortsMonitor.shared.releaseLease()
        }
    }

    private func setSamplingNeeded(_ needed: Bool) {
        guard needed != holdsPerformanceLease else { return }
        holdsPerformanceLease = needed
        if needed {
            SystemPerformanceMonitor.shared.acquireViewLease()
        } else {
            SystemPerformanceMonitor.shared.releaseViewLease()
        }
    }
}

// MARK: - Rendering

struct MenuBarStatusView: View {
    var onWidthChange: ((CGFloat) -> Void)?
    /// Settings preview draws on a dark surface instead of the menu bar.
    var preview = false

    @ObservedObject private var preferences = MenuBarPreferences.shared
    @ObservedObject private var performance = SystemPerformanceMonitor.shared
    @ObservedObject private var system = SystemMonitor.shared
    @ObservedObject private var usage = AIUsageStore.shared
    @ObservedObject private var focus = ProductivityStore.shared
    @ObservedObject private var limiter = ChargeLimiter.shared
    @ObservedObject private var ports = OpenPortsMonitor.shared

    var body: some View {
        HStack(spacing: 9) {
            let modules = renderableModules
            if modules.isEmpty {
                logo
            } else {
                ForEach(modules) { setting in
                    module(setting)
                }
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onWidthChange?($0) }
        .frame(maxWidth: preview ? nil : .infinity, maxHeight: .infinity)
        .foregroundStyle(preview ? Color.white : Color.primary)
    }

    /// Visible modules that currently have something to show. If none do,
    /// the logo is shown so the menu can always be reached.
    private var renderableModules: [MenuBarModuleSetting] {
        preferences.visibleItems.filter { setting in
            switch setting.id {
            case .battery: return system.hasBattery
            case .focus: return focus.running
            case .claude, .codex, .openCode: return aiQuotas(for: setting.id).isEmpty == false
            case .aiUsage: return combinedQuotas(setting.resolvedFormat).isEmpty == false
            default: return true
            }
        }
    }

    @ViewBuilder
    private func module(_ setting: MenuBarModuleSetting) -> some View {
        switch setting.id {
        case .logo: logo
        case .cpu:
            percentModule(label: "CPU", value: performance.cpu?.active, history: performance.cpuHistory, style: setting.style, color: loadColor(performance.cpu?.active, base: .blue))
        case .memory:
            percentModule(label: "MEM", value: performance.memory.map { $0.usedFraction * 100 }, history: performance.memoryHistory, style: setting.style, color: memoryColor,
                          text: memoryText(setting.resolvedFormat))
        case .gpu:
            percentModule(label: "GPU", value: performance.gpuPercentage, history: performance.gpuHistory, style: setting.style, color: loadColor(performance.gpuPercentage, base: .pink))
        case .network:
            rateModule(up: performance.networkThroughput?.sentBytesPerSecond, down: performance.networkThroughput?.receivedBytesPerSecond,
                       upHistory: performance.networkSendHistory, downHistory: performance.networkReceiveHistory,
                       upColor: .indigo, downColor: .cyan, style: setting.style, bits: setting.resolvedFormat == .bitsPerSecond)
        case .disk:
            rateModule(up: performance.diskThroughput?.writtenBytesPerSecond, down: performance.diskThroughput?.readBytesPerSecond,
                       upHistory: performance.diskWriteHistory, downHistory: performance.diskReadHistory,
                       upColor: .orange, downColor: .green, style: setting.style, bits: setting.resolvedFormat == .bitsPerSecond, upSymbol: "W", downSymbol: "R")
        case .battery: batteryModule(setting.resolvedFormat)
        case .storage:
            labeled(storageLabel(setting.resolvedFormat), storageText(setting.resolvedFormat), color: tint(.indigo))
        case .ports:
            HStack(spacing: 3) {
                Image(systemName: "powerplug.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint(.teal))
                labeled("PORTS", ports.hasScanned ? "\(ports.entries.count)" : "—", color: nil, minWidth: 14)
            }
            .help(portsHelp)
        case .claude, .codex, .openCode: aiModule(setting)
        case .aiUsage: combinedAIModule(setting.resolvedFormat)
        case .focus:
            HStack(spacing: 3) {
                Image(systemName: "timer").font(.system(size: 10, weight: .semibold)).foregroundStyle(tint(.orange))
                Text(focus.focusRemainingText).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
        }
    }

    /// The first listening ports, so the tooltip already answers "what is on 3000?".
    private var portsHelp: String {
        guard ports.hasScanned else { return "Open ports" }
        if ports.entries.isEmpty { return "Nothing is listening on a port" }
        let lines = ports.entries.prefix(8).map { "\($0.port) · \($0.name)" }
        let rest = ports.entries.count - lines.count
        return (lines + (rest > 0 ? ["and \(rest) more"] : [])).joined(separator: "\n")
    }

    private var logo: some View {
        Image(systemName: "rectangle.topthird.inset.filled")
            .font(.system(size: 14, weight: .regular))
            .accessibilityLabel("SuperNotch")
    }

    // MARK: Module builders

    @ViewBuilder
    private func percentModule(label: String, value: Double?, history: [Double], style: MenuBarModuleStyle, color: Color, text customText: String? = nil) -> some View {
        let text = customText ?? value.map { "\(Int($0.rounded()))%" } ?? "—"
        switch style {
        case .value:
            labeled(label, text, color: color, minWidth: 30)
        case .bar:
            HStack(spacing: 4) {
                VerticalMeter(fraction: (value ?? 0) / 100, color: color)
                labeled(label, text, color: nil, minWidth: 30)
            }
        case .graph:
            HStack(spacing: 4) {
                ActivityChart(series: [.init(values: history, color: color)], capacity: 30, maximum: 100, showsGrid: false, lineWidth: 1.2, showsEndDot: false)
                    .frame(width: 30, height: 15)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                labeled(label, text, color: nil, minWidth: 30)
            }
        }
    }

    @ViewBuilder
    private func rateModule(up: Double?, down: Double?, upHistory: [Double], downHistory: [Double], upColor: Color, downColor: Color, style: MenuBarModuleStyle, bits: Bool, upSymbol: String = "↑", downSymbol: String = "↓") -> some View {
        HStack(spacing: 4) {
            if style == .graph {
                ActivityChart(series: [
                    .init(values: downHistory, color: tint(downColor)),
                    .init(values: upHistory, color: tint(upColor), filled: false)
                ], capacity: 30, minimumScale: 50_000, showsGrid: false, lineWidth: 1.1, showsEndDot: false)
                .frame(width: 30, height: 15)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            VStack(alignment: .trailing, spacing: -1) {
                rateLine(upSymbol, up, bits: bits, color: tint(upColor))
                rateLine(downSymbol, down, bits: bits, color: tint(downColor))
            }
        }
    }

    private func rateLine(_ symbol: String, _ value: Double?, bits: Bool, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(MenuBarFormat.rate(value, bits: bits)).monospacedDigit()
            Text(symbol).foregroundStyle(color)
        }
        .font(.system(size: 9, weight: .medium))
        .frame(minWidth: 50, alignment: .trailing)
    }

    private func batteryModule(_ format: MenuBarValueFormat?) -> some View {
        let percent = system.battery
        let status = limiter.isHelperResponding ? limiter.status : nil
        let held = status.map { $0.enabled && $0.chargingInhibited && !$0.discharging && !$0.pausedForSleep } ?? false
        let discharging = status?.discharging ?? false
        let color: Color = percent <= 10 ? .red : percent <= 20 ? .orange : .green
        return HStack(spacing: 4) {
            BatteryGlyph(fraction: Double(percent) / 100, color: preferences.colorful ? color : .primary)
                .overlay {
                    Group {
                        if discharging {
                            Image(systemName: "arrow.down")
                        } else if held {
                            Image(systemName: "pause.fill")
                        } else if system.charging {
                            Image(systemName: "bolt.fill")
                        }
                    }
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.primary)
                    .offset(x: -1)
                }
            Text(batteryText(format, percent: percent)).font(.system(size: 12, weight: .medium)).monospacedDigit()
        }
    }

    private func batteryText(_ format: MenuBarValueFormat?, percent: Int) -> String {
        guard format == .timeRemaining, !system.charging,
              let minutes = BatteryInsightsMonitor.shared.snapshot.timeRemainingMinutes, minutes > 0,
              !BatteryInsightsMonitor.shared.snapshot.isConnectedToPower else { return "\(percent)%" }
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    private func memoryText(_ format: MenuBarValueFormat?) -> String? {
        guard let memory = performance.memory else { return nil }
        switch format {
        case .used: return MenuBarFormat.bytes(memory.used)
        case .free: return MenuBarFormat.bytes(memory.available)
        default: return nil
        }
    }

    private func storageLabel(_ format: MenuBarValueFormat?) -> String {
        switch format {
        case .used: return "SSD USED"
        case .percent: return "SSD"
        default: return "SSD FREE"
        }
    }

    private func storageText(_ format: MenuBarValueFormat?) -> String {
        guard let storage = performance.storage else { return "—" }
        switch format {
        case .used: return MenuBarFormat.bytes(storage.used)
        case .percent: return "\(Int((storage.usedFraction * 100).rounded()))%"
        default: return MenuBarFormat.bytes(storage.available)
        }
    }

    @ViewBuilder
    private func aiModule(_ setting: MenuBarModuleSetting) -> some View {
        let quotas = aiQuotas(for: setting.id)
        if let provider = setting.id.aiProvider {
            HStack(spacing: 4) {
                AIProviderBrandView(provider: provider, size: 13)
                    .foregroundStyle(preferences.colorful ? setting.id.tint : .primary)
                switch setting.style {
                case .bar, .graph:
                    VStack(spacing: 3) {
                        ForEach(Array(quotas.prefix(2).enumerated()), id: \.offset) { _, quota in
                            HorizontalMeter(fraction: displayFraction(quota), color: quotaColor(quota))
                        }
                    }
                    .frame(width: 30)
                case .value:
                    Text(quotas.first.map { "\(Int((displayFraction($0) * 100).rounded()))%" } ?? "—")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
            }
            .help(quotas.isEmpty ? provider.displayName : "\(provider.displayName) · \(usage.showRemaining ? "remaining" : "used")")
        }
    }

    /// All enabled providers as stacked bars, like a tiny equalizer. At most
    /// four bars fit the menu bar height.
    private func combinedAIModule(_ format: MenuBarValueFormat?) -> some View {
        let entries = combinedQuotas(format)
        return VStack(alignment: .leading, spacing: entries.count > 3 ? 1.5 : 2.5) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                StackedUsageBar(fraction: displayFraction(entry.quota), color: quotaColor(entry.quota), height: entries.count > 3 ? 2.5 : 3.5)
            }
        }
        .frame(width: 26)
        .help(entries.map { "\($0.provider.displayName) \($0.title): \(AIUsageFormat.quotaHeadline($0.quota, showRemaining: usage.showRemaining))" }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI usage")
        .accessibilityValue(entries.map { "\($0.provider.displayName) \(Int(($0.quota.usedFraction * 100).rounded())) percent used" }.joined(separator: ", "))
    }

    /// One bar per provider shows its most constrained limit; "every limit" lists them all.
    private func combinedQuotas(_ format: MenuBarValueFormat?) -> [(provider: AIUsageProviderID, title: String, quota: AIUsageQuota)] {
        var entries: [(provider: AIUsageProviderID, title: String, quota: AIUsageQuota)] = []
        for provider in AIUsageProviderID.allCases {
            guard usage.isEnabled(provider), let snapshot = usage.snapshot(for: provider) else { continue }
            let quotas = snapshot.metrics.compactMap { metric in metric.quota.map { (provider: provider, title: metric.title, quota: $0) } }
            if format == .everyLimit {
                entries.append(contentsOf: quotas)
            } else if let tightest = quotas.max(by: { $0.quota.usedFraction < $1.quota.usedFraction }) {
                entries.append(tightest)
            }
        }
        return Array(entries.prefix(4))
    }

    // MARK: Helpers

    @ViewBuilder
    private func labeled(_ label: String, _ value: String, color: Color?, minWidth: CGFloat = 0) -> some View {
        if preferences.showsLabels {
            VStack(alignment: .leading, spacing: -2) {
                Text(label).font(.system(size: 7, weight: .bold)).tracking(0.4).opacity(0.65)
                Text(value).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(color ?? .primary)
            }
            .frame(minWidth: minWidth, alignment: .leading)
        } else {
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(color ?? .primary)
                .frame(minWidth: minWidth, alignment: .trailing)
        }
    }

    private func aiQuotas(for id: MenuBarModuleID) -> [AIUsageQuota] {
        guard let provider = id.aiProvider, usage.isEnabled(provider), let snapshot = usage.snapshot(for: provider) else { return [] }
        return snapshot.metrics.compactMap(\.quota)
    }

    private func displayFraction(_ quota: AIUsageQuota) -> Double {
        usage.showRemaining ? quota.remainingFraction : quota.usedFraction
    }

    private func quotaColor(_ quota: AIUsageQuota) -> Color {
        guard preferences.colorful else { return .primary }
        if quota.usedFraction >= 0.9 { return .red }
        if quota.usedFraction >= 0.7 { return .orange }
        return .green
    }

    private func tint(_ color: Color) -> Color {
        preferences.colorful ? color : .primary
    }

    private func loadColor(_ value: Double?, base: Color) -> Color {
        guard preferences.colorful else { return .primary }
        guard let value else { return base }
        if value >= 85 { return .red }
        if value >= 65 { return .orange }
        return base
    }

    private var memoryColor: Color {
        guard preferences.colorful else { return .primary }
        switch performance.memory?.pressure {
        case .critical: return .red
        case .warning: return .orange
        default: return .purple
        }
    }
}

private struct VerticalMeter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        let clamped = CGFloat(min(1, max(0, fraction.isFinite ? fraction : 0)))
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Color.primary.opacity(0.18))
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(color).frame(height: max(1.5, 15 * clamped))
        }
        .frame(width: 5, height: 15)
    }
}

private struct HorizontalMeter: View {
    let fraction: Double
    let color: Color

    var body: some View {
        let clamped = CGFloat(min(1, max(0, fraction.isFinite ? fraction : 0)))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.2))
            Capsule().fill(color).frame(width: max(2, 30 * clamped))
        }
        .frame(width: 30, height: 4)
    }
}

private struct StackedUsageBar: View {
    let fraction: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        let clamped = CGFloat(min(1, max(0, fraction.isFinite ? fraction : 0)))
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.28))
            Capsule().fill(color).frame(width: max(height, 26 * clamped))
        }
        .frame(width: 26, height: height)
    }
}

private struct BatteryGlyph: View {
    let fraction: Double
    let color: Color

    var body: some View {
        let clamped = CGFloat(min(1, max(0, fraction)))
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                    .fill(color.opacity(0.9))
                    .frame(width: max(1.5, 17 * clamped), height: 7)
                    .padding(.leading, 2)
            }
            .frame(width: 21, height: 11)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.primary.opacity(0.55))
                .frame(width: 1.5, height: 4)
        }
    }
}

enum MenuBarFormat {
    /// Short, fixed-width-friendly rates such as "12K/s", "1.4M/s" or, in bits, "9.6Mbps".
    static func rate(_ bytesPerSecond: Double?, bits: Bool = false) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite else { return "—" }
        if bits {
            let value = max(0, bytesPerSecond) * 8
            if value < 1_000 { return "\(Int(value))bps" }
            if value < 1_000_000 { return "\(Int((value / 1_000).rounded()))Kbps" }
            if value < 10_000_000 { return String(format: "%.1fMbps", value / 1_000_000) }
            if value < 1_000_000_000 { return "\(Int((value / 1_000_000).rounded()))Mbps" }
            return String(format: "%.1fGbps", value / 1_000_000_000)
        }
        let value = max(0, bytesPerSecond)
        if value < 1_000 { return "\(Int(value))B/s" }
        if value < 1_000_000 { return "\(Int((value / 1_000).rounded()))K/s" }
        if value < 10_000_000 { return String(format: "%.1fM/s", value / 1_000_000) }
        if value < 1_000_000_000 { return "\(Int((value / 1_000_000).rounded()))M/s" }
        return String(format: "%.1fG/s", value / 1_000_000_000)
    }

    /// Readable rates for the details panel, such as "1.4 MB/s" or "11.2 Mbps".
    static func detailedRate(_ bytesPerSecond: Double?, bits: Bool) -> String {
        guard bits else { return ActivityFormat.rate(bytesPerSecond) }
        guard let bytesPerSecond, bytesPerSecond.isFinite else { return "—" }
        let value = max(0, bytesPerSecond) * 8
        if value < 1_000 { return "\(Int(value)) bps" }
        if value < 1_000_000 { return String(format: "%.0f Kbps", value / 1_000) }
        if value < 1_000_000_000 { return String(format: "%.1f Mbps", value / 1_000_000) }
        return String(format: "%.2f Gbps", value / 1_000_000_000)
    }

    static func bytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        let value = Double(max(0, bytes))
        if value >= 1_000_000_000_000 { return String(format: "%.1fT", value / 1_000_000_000_000) }
        if value >= 100_000_000_000 { return "\(Int((value / 1_000_000_000).rounded()))G" }
        if value >= 1_000_000_000 { return String(format: "%.1fG", value / 1_000_000_000) }
        return "\(Int((value / 1_000_000).rounded()))M"
    }
}

// MARK: - Settings

struct MenuBarSettingsPage: View {
    @ObservedObject private var preferences = MenuBarPreferences.shared
    @ObservedObject private var usage = AIUsageStore.shared
    @ObservedObject private var system = SystemMonitor.shared
    @ObservedObject private var performance = SystemPerformanceMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Preview") {
                HStack {
                    Spacer()
                    MenuBarStatusView(preview: true)
                        .frame(height: 22)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.7))
                        .environment(\.colorScheme, .dark)
                    Spacer()
                }
                .padding(.vertical, 16)
            }

            SettingsCard(title: "Items") {
                let items = preferences.items
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    itemRow(item, index: index, count: items.count)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: preferences.items)

            SettingsCard(title: "Appearance") {
                SettingsRow(symbol: "textformat.size.smaller", color: .gray, title: "Labels", detail: "Small CPU, MEM and GPU captions above values.") {
                    NotchToggle(isOn: $preferences.showsLabels)
                }
                SettingsRow(symbol: "paintpalette.fill", color: .pink, title: "Color", detail: "Tint values by load. Off matches the menu bar text color.", divider: false) {
                    NotchToggle(isOn: $preferences.colorful)
                }
            }

            SettingsCard(title: "When clicked") {
                let sections = MenuBarPanelSection.allCases
                ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                    SettingsRow(symbol: section.symbol, color: preferences.showsPanelSection(section) ? section.tint : .gray, title: section.title,
                                detail: index == 0 ? "Left-click opens a details panel. Right-click shows the classic menu." : nil,
                                divider: index < sections.count - 1) {
                        NotchToggle(isOn: Binding(get: { preferences.showsPanelSection(section) }, set: { preferences.setPanelSection(section, visible: $0) }))
                            .accessibilityLabel("Show \(section.title) in the panel")
                    }
                }
            }

            HStack {
                Button { preferences.reset() } label: { Label("Reset menu bar", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(PillButtonStyle())
                Spacer()
                Text("Stats update every 2 seconds and are only sampled while shown.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .onAppear { performance.acquireViewLease() }
        .onDisappear { performance.releaseViewLease() }
    }

    private func itemRow(_ item: MenuBarModuleSetting, index: Int, count: Int) -> some View {
        VStack(spacing: 0) {
            SettingsRow(symbol: item.id.symbol, color: item.visible ? item.id.tint : .gray, title: item.id.title, detail: detail(for: item.id), divider: false) {
                HStack(spacing: 10) {
                    HStack(spacing: 0) {
                        reorder(item.id, "chevron.up", -1, enabled: index > 0)
                        reorder(item.id, "chevron.down", 1, enabled: index < count - 1)
                    }
                    .background(.white.opacity(0.07), in: Capsule())
                    NotchToggle(isOn: Binding(get: { preferences.setting(for: item.id).visible }, set: { preferences.setVisible(item.id, $0) }))
                        .accessibilityLabel("Show \(item.id.title)")
                }
            }
            if item.visible, item.id.styles.count > 1 || item.id.formats.count > 1 {
                HStack(spacing: 14) {
                    if item.id.styles.count > 1 {
                        optionLabel("Style")
                        ChipPicker(options: item.id.styles.map { ($0, $0.title) }, selection: Binding(
                            get: { preferences.setting(for: item.id).style },
                            set: { preferences.setStyle(item.id, $0) }
                        ))
                    }
                    if item.id.formats.count > 1 {
                        optionLabel(item.id == .network || item.id == .disk ? "Units" : item.id == .aiUsage ? "Bars" : "Show")
                        ChipPicker(options: item.id.formats.map { ($0, $0.title) }, selection: Binding(
                            get: { preferences.setting(for: item.id).resolvedFormat ?? item.id.formats[0] },
                            set: { preferences.setFormat(item.id, $0) }
                        ))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 54).padding(.trailing, 14).padding(.bottom, 11)
                .transition(.opacity)
            }
            if index < count - 1 {
                Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 54)
            }
        }
    }

    private func optionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
    }

    private func detail(for id: MenuBarModuleID) -> String {
        if id == .aiUsage {
            let enabled = AIUsageProviderID.allCases.filter { usage.isEnabled($0) }
            if enabled.isEmpty { return "Turn on Claude, Codex or OpenCode in AI Usage to show it." }
            return "\(enabled.map(\.displayName).joined(separator: ", ")) stacked in one item, one bar under another."
        }
        if let provider = id.aiProvider {
            if !usage.isEnabled(provider) { return "Turn on \(provider.displayName) in AI Usage to show it." }
            if usage.snapshot(for: provider) == nil { return "Waiting for \(provider.displayName) usage…" }
            return "Session and weekly limits as bars."
        }
        switch id {
        case .logo: return "Shown automatically when nothing else is."
        case .battery: return system.hasBattery ? "Charge, with charging, held and discharging marks." : "This Mac has no battery."
        case .focus: return "Appears only while a focus session runs."
        case .network: return "Upload and download speed."
        case .disk: return "Read and write speed."
        case .storage: return "Free space on the startup disk."
        case .ports: return "How many ports processes on this Mac listen on."
        default: return "Live usage."
        }
    }

    private func reorder(_ id: MenuBarModuleID, _ symbol: String, _ offset: Int, enabled: Bool) -> some View {
        Button { preferences.move(id, by: offset) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(offset < 0 ? "Move \(id.title) left" : "Move \(id.title) right")
    }
}
