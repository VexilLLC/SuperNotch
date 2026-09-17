import SwiftUI
import AppKit
import Darwin
import Network
import Combine
import CoreWLAN
import IOKit.ps

struct SystemInterface: Identifiable, Equatable {
    let name: String
    let isUp: Bool
    let isRunning: Bool
    let isLoopback: Bool
    let isPointToPoint: Bool
    var id: String { name }
    var isTunnel: Bool { name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("tap") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") }
    var summary: String {
        [isUp ? "Up" : "Down", isRunning ? "Running" : "Inactive", isLoopback ? "Loopback" : nil, isPointToPoint ? "Point-to-point" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

enum SystemInterfaceKind: Equatable, Sendable {
    case wifi, ethernet, cellular, tunnel, loopback, virtual, wirelessDirect, other

    var title: String {
        switch self {
        case .wifi: return "Wi‑Fi"
        case .ethernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .tunnel: return "Tunnel"
        case .loopback: return "Loopback"
        case .virtual: return "Virtual bridge"
        case .wirelessDirect: return "AirDrop & Continuity"
        case .other: return "Network port"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .tunnel: return "lock.shield.fill"
        case .loopback: return "arrow.triangle.2.circlepath"
        case .virtual: return "square.stack.3d.down.right.fill"
        case .wirelessDirect: return "dot.radiowaves.left.and.right"
        case .other: return "network"
        }
    }

    var tint: Color {
        switch self {
        case .wifi: return .blue
        case .ethernet: return .green
        case .cellular: return .mint
        case .tunnel: return .purple
        case .loopback: return .gray
        case .virtual: return .indigo
        case .wirelessDirect: return .teal
        case .other: return .cyan
        }
    }

    /// Classifies an interface by the type Network.framework reports, falling
    /// back to BSD naming conventions for interfaces it does not list.
    static func classify(name: String, pathType: NWInterface.InterfaceType?, wifiNames: Set<String>) -> SystemInterfaceKind {
        if wifiNames.contains(name) { return .wifi }
        switch pathType {
        case .wifi: return .wifi
        case .wiredEthernet: return .ethernet
        case .cellular: return .cellular
        case .loopback: return .loopback
        default: break
        }
        if name.hasPrefix("lo") { return .loopback }
        if ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf"].contains(where: name.hasPrefix) { return .tunnel }
        if name.hasPrefix("bridge") || name.hasPrefix("vmenet") { return .virtual }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return .wirelessDirect }
        if name.hasPrefix("en") { return .ethernet }
        return .other
    }
}

struct SystemNetworkPathInfo: Equatable {
    enum Status: Equatable { case connected, offline, waiting }
    var status: Status = .waiting
    var primaryInterface: String?
    var primaryType: NWInterface.InterfaceType?
    var isExpensive = false
    var isConstrained = false
    var supportsIPv4 = false
    var supportsIPv6 = false
    var supportsDNS = false
    var interfaceTypes: [String: NWInterface.InterfaceType] = [:]

    init() {}

    init(_ path: NWPath) {
        switch path.status {
        case .satisfied: status = .connected
        case .requiresConnection: status = .waiting
        default: status = .offline
        }
        primaryInterface = path.availableInterfaces.first?.name
        primaryType = path.availableInterfaces.first?.type
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        supportsDNS = path.supportsDNS
        interfaceTypes = Dictionary(path.availableInterfaces.map { ($0.name, $0.type) }, uniquingKeysWith: { first, _ in first })
    }
}

struct SystemMountedVolume: Identifiable, Equatable {
    let url: URL
    let name: String
    let removable: Bool
    let ejectable: Bool
    let capacity: Int64?
    let available: Int64?
    var isInternal = true
    var isLocal = true
    var isReadOnly = false
    var isRoot = false
    var format: String?
    var id: String { url.path }

    var canEject: Bool { (ejectable || removable || !isLocal) && !isRoot }
    var usedFraction: Double? {
        guard let capacity, let available, capacity > 0 else { return nil }
        return min(1, max(0, Double(capacity - min(capacity, max(0, available))) / Double(capacity)))
    }
    var symbol: String {
        if !isLocal { return "server.rack" }
        if isRoot { return "internaldrive.fill" }
        if removable || ejectable || !isInternal { return "externaldrive.fill" }
        return "internaldrive.fill"
    }
    var tint: Color {
        if !isLocal { return .teal }
        if isRoot { return .blue }
        return removable || ejectable || !isInternal ? .orange : .indigo
    }
}

enum SystemEventKind: String, CaseIterable, Identifiable {
    case network = "Network"
    case storage = "Storage"
    case power = "Power"
    case keyboard = "Keyboard"
    case system = "System"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .network: return .cyan
        case .storage: return .indigo
        case .power: return .green
        case .keyboard: return .orange
        case .system: return .pink
        }
    }
}

struct SystemObservedEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let message: String
    let icon: String
    var kind: SystemEventKind = .system
}

enum SystemActivityTab: String, CaseIterable, Identifiable {
    case performance = "Performance"
    case battery = "Battery"
    case network = "Network"
    case volumes = "Volumes"
    case events = "Events"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .performance: return "gauge.with.needle.fill"
        case .battery: return "battery.75percent"
        case .network: return "network"
        case .volumes: return "externaldrive.fill"
        case .events: return "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .performance: return .blue
        case .battery: return .green
        case .network: return .cyan
        case .volumes: return .indigo
        case .events: return .orange
        }
    }
}

private struct SystemActivityTabBar: View {
    @Binding var selection: SystemActivityTab
    var showsLabels = true
    var eventCount = 0
    @Namespace private var selectionAnimation
    @State private var hovered: SystemActivityTab?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SystemActivityTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    // Keep animation local to the tab bar. Animating this state
                    // transaction also retained both complete dashboards while
                    // their content cross-faded below.
                    selection = tab
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? tab.tint : .white.opacity(hovered == tab ? 0.8 : 0.5))
                            .frame(width: 16)
                        if showsLabels {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .foregroundStyle(.white.opacity(selected ? 0.95 : hovered == tab ? 0.8 : 0.55))
                        }
                        if tab == .events, eventCount > 0, !selected {
                            Text("\(min(eventCount, 99))")
                                .font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.orange.opacity(0.16), in: Capsule())
                        }
                    }
                    .fixedSize()
                    .padding(.horizontal, showsLabels ? 13 : 10)
                    .frame(height: 32)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.white.opacity(0.1))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(LinearGradient(colors: [tab.tint.opacity(0.55), tab.tint.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                                }
                                .matchedGeometryEffect(id: "activity-tab-selection", in: selectionAnimation)
                        } else if hovered == tab {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.045))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? tab : (hovered == tab ? nil : hovered) }
                .help(tab.rawValue)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.black.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selection)
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

@MainActor final class SystemActivitiesModel: ObservableObject {
    static let shared = SystemActivitiesModel()
    @Published private(set) var interfaces: [SystemInterface] = []
    @Published private(set) var path = SystemNetworkPathInfo()
    @Published private(set) var wifiInterfaceNames: Set<String> = []
    @Published private(set) var volumes: [SystemMountedVolume] = []
    @Published private(set) var isLoadingVolumes = false
    @Published private(set) var capsLock = false
    @Published private(set) var events: [SystemObservedEvent] = []
    @Published var message: String?
    @Published private(set) var ejecting: Set<String> = []
    @Published private(set) var lastChecked: Date?
    /// The last Activity tab shown, restored when the destination is reopened.
    var lastTab: SystemActivityTab = .performance

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var flagsMonitors: [Any] = []
    private var networkMonitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var lastPowerOnAC: Bool?
    private var lastLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var lastThermal = ProcessInfo.processInfo.thermalState
    private var initialized = false
    private var pathInitialized = false
    private var volumeGeneration: UInt64 = 0
    private let volumeQueue = DispatchQueue(label: "SuperNotch.system-volumes", qos: .utility)

    func start() {
        guard networkMonitor == nil else { return }
        refresh()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observe(workspace, name) { [weak self] note in
                let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                let label = (note.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String) ?? url?.lastPathComponent ?? "Volume"
                let action = name == NSWorkspace.didMountNotification ? "mounted" : name == NSWorkspace.didUnmountNotification ? "unmounted" : "renamed"
                let icon = name == NSWorkspace.didUnmountNotification ? "eject.fill" : "externaldrive.fill.badge.plus"
                self?.record("\(label) \(action)", icon: icon, kind: .storage)
                self?.refreshVolumes()
            }
        }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in
            self?.record("Mac is going to sleep", icon: "moon.fill", kind: .system)
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.record("Mac woke from sleep", icon: "sun.max.fill", kind: .system)
            self?.refresh()
        }
        observe(NotificationCenter.default, ProcessInfo.thermalStateDidChangeNotification) { [weak self] _ in
            self?.thermalStateChanged()
        }
        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] _ in
            self?.lowPowerModeChanged()
        }

        // Only Caps Lock depends on modifier events; interfaces are refreshed by path updates.
        let flagsHandler: (NSEvent) -> Void = { [weak self] event in
            let caps = event.modifierFlags.contains(.capsLock)
            Task { @MainActor in self?.updateCapsLock(caps) }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsHandler) { flagsMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in flagsHandler(event); return event }) { flagsMonitors.append(monitor) }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let info = SystemNetworkPathInfo(path)
            Task { @MainActor in self?.pathChanged(info) }
        }
        monitor.start(queue: DispatchQueue(label: "app.supernotch.system-activities", qos: .utility))
        networkMonitor = monitor

        installPowerSourceNotification()
    }

    func stop() {
        networkMonitor?.cancel(); networkMonitor = nil
        flagsMonitors.forEach { NSEvent.removeMonitor($0) }; flagsMonitors = []
        observers.forEach { $0.0.removeObserver($0.1) }; observers = []
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        initialized = false
        pathInitialized = false
    }

    func refresh() {
        refreshInterfaces()
        updateCapsLock(NSEvent.modifierFlags.contains(.capsLock))
        refreshVolumes()
        wifiInterfaceNames = Set(CWWiFiClient.shared().interfaceNames() ?? [])
    }

    func kind(for interface: SystemInterface) -> SystemInterfaceKind {
        SystemInterfaceKind.classify(name: interface.name, pathType: path.interfaceTypes[interface.name], wifiNames: wifiInterfaceNames)
    }

    // MARK: Network

    private func pathChanged(_ info: SystemNetworkPathInfo) {
        let previous = path
        path = info
        if pathInitialized {
            if previous.status != info.status {
                switch info.status {
                case .connected: record("Connected\(connectionSuffix(info))", icon: "wifi", kind: .network)
                case .offline: record("Network connection lost", icon: "wifi.slash", kind: .network)
                case .waiting: record("Waiting for a network connection", icon: "wifi.exclamationmark", kind: .network)
                }
            } else if info.status == .connected, previous.primaryInterface != info.primaryInterface {
                record("Switched\(connectionSuffix(info))", icon: "arrow.left.arrow.right", kind: .network)
            }
            if previous.isConstrained != info.isConstrained {
                record("Low Data Mode \(info.isConstrained ? "turned on" : "turned off")", icon: "tortoise.fill", kind: .network)
            }
        }
        pathInitialized = true
        refreshInterfaces()
        wifiInterfaceNames = Set(CWWiFiClient.shared().interfaceNames() ?? [])
    }

    private func connectionSuffix(_ info: SystemNetworkPathInfo) -> String {
        guard let name = info.primaryInterface else { return "" }
        let kind = SystemInterfaceKind.classify(name: name, pathType: info.primaryType, wifiNames: wifiInterfaceNames)
        return " via \(kind.title) (\(name))"
    }

    private func refreshInterfaces() {
        do {
            let newInterfaces = try Self.readInterfaces()
            if initialized {
                let previous = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.name, $0) })
                let current = Dictionary(uniqueKeysWithValues: newInterfaces.map { ($0.name, $0) })
                for entry in newInterfaces where !entry.isLoopback {
                    if let old = previous[entry.name] {
                        if old.isUp != entry.isUp { record("\(entry.name) went \(entry.isUp ? "up" : "down")", icon: entry.isTunnel ? "lock.shield" : "network", kind: .network) }
                    } else {
                        record("Interface \(entry.name) appeared", icon: entry.isTunnel ? "lock.shield" : "network", kind: .network)
                    }
                }
                for entry in interfaces where current[entry.name] == nil && !entry.isLoopback {
                    record("Interface \(entry.name) removed", icon: "network.slash", kind: .network)
                }
            }
            if interfaces != newInterfaces { interfaces = newInterfaces }
            initialized = true
            lastChecked = Date()
        } catch {
            message = "Could not read network interfaces: \(error.localizedDescription)"
        }
    }

    static func readInterfaces() throws -> [SystemInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { if let list { freeifaddrs(list) } }
        var entries: [String: SystemInterface] = [:]
        var pointer = list
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let namePointer = current.pointee.ifa_name else { continue }
            let name = String(cString: namePointer)
            let flags = Int32(bitPattern: current.pointee.ifa_flags)
            entries[name] = SystemInterface(name: name, isUp: flags & IFF_UP != 0, isRunning: flags & IFF_RUNNING != 0, isLoopback: flags & IFF_LOOPBACK != 0, isPointToPoint: flags & IFF_POINTOPOINT != 0)
        }
        return entries.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Keyboard, power and thermals

    private func updateCapsLock(_ enabled: Bool) {
        guard enabled != capsLock else { return }
        if initialized { record("Caps Lock \(enabled ? "turned on" : "turned off")", icon: "capslock.fill", kind: .keyboard) }
        capsLock = enabled
    }

    private func installPowerSourceNotification() {
        lastPowerOnAC = Self.isOnACPower()
        let callback: IOPowerSourceCallbackType = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SystemActivitiesModel.shared.powerSourceChanged() }
            }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func powerSourceChanged() {
        let onAC = Self.isOnACPower()
        defer { lastPowerOnAC = onAC }
        guard let onAC, let lastPowerOnAC, onAC != lastPowerOnAC else { return }
        record(onAC ? "Power adapter connected" : "Switched to battery power", icon: onAC ? "powerplug.fill" : "battery.75percent", kind: .power)
    }

    private func lowPowerModeChanged() {
        let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard enabled != lastLowPower else { return }
        lastLowPower = enabled
        record("Low Power Mode \(enabled ? "turned on" : "turned off")", icon: "leaf.fill", kind: .power)
    }

    private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        guard state != lastThermal else { return }
        lastThermal = state
        record("Thermal state is now \(state.activityTitle.lowercased())", icon: "thermometer.medium", kind: .system)
    }

    private static func isOnACPower() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        return type == kIOPSACPowerValue
    }

    // MARK: Volumes

    /// Volume resource values can block on network or sleeping disks, so they
    /// are read off the main thread. Stale results from older reads are dropped.
    func refreshVolumes() {
        volumeGeneration &+= 1
        let generation = volumeGeneration
        isLoadingVolumes = true
        volumeQueue.async { [weak self] in
            let volumes = Self.readVolumes()
            Task { @MainActor [weak self] in
                guard let self, generation == self.volumeGeneration else { return }
                if self.volumes != volumes { self.volumes = volumes }
                self.isLoadingVolumes = false
            }
        }
    }

    nonisolated static func readVolumes() -> [SystemMountedVolume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
            .volumeLocalizedFormatDescriptionKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isLocal = values?.volumeIsLocal ?? true
            let important = isLocal ? values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil } : nil
            return SystemMountedVolume(
                url: url,
                name: values?.volumeLocalizedName ?? values?.volumeName ?? url.lastPathComponent,
                removable: values?.volumeIsRemovable ?? false,
                ejectable: values?.volumeIsEjectable ?? false,
                capacity: values?.volumeTotalCapacity.map(Int64.init),
                available: important ?? values?.volumeAvailableCapacity.map(Int64.init),
                isInternal: values?.volumeIsInternal ?? true,
                isLocal: isLocal,
                isReadOnly: values?.volumeIsReadOnly ?? false,
                isRoot: values?.volumeIsRootFileSystem ?? (url.path == "/"),
                format: values?.volumeLocalizedFormatDescription
            )
        }
        .sorted {
            if $0.isRoot != $1.isRoot { return $0.isRoot }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func eject(_ volume: SystemMountedVolume) {
        guard volume.canEject, !ejecting.contains(volume.id) else { return }
        ejecting.insert(volume.id)
        message = nil
        Task { @MainActor [weak self] in
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url); return nil }
                catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            self.ejecting.remove(volume.id)
            if let error { self.message = "Could not eject \(volume.name): \(error)" }
            else { self.message = "Ejected \(volume.name). It is safe to disconnect." }
            self.refreshVolumes()
        }
    }

    // MARK: Events

    func clearEvents() { events.removeAll() }

    private func record(_ text: String, icon: String, kind: SystemEventKind) {
        events.insert(SystemObservedEvent(message: text, icon: icon, kind: kind), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, handler: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        observers.append((center, token))
    }
}

// MARK: - Views

@MainActor struct SystemActivitiesView: View {
    @ObservedObject private var model = SystemActivitiesModel.shared
    @State private var tab: SystemActivityTab
    @State private var pendingEject: SystemMountedVolume?

    init(initialTab: String = "") {
        let requested = SystemActivityTab(rawValue: initialTab)
        _tab = State(initialValue: requested ?? SystemActivitiesModel.shared.lastTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    SystemActivityTabBar(selection: $tab, eventCount: model.events.count)
                    SystemActivityTabBar(selection: $tab, showsLabels: false, eventCount: model.events.count)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                if model.capsLock {
                    ActivityPill(text: "Caps Lock", color: .orange, symbol: "capslock.fill")
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                ActivityIconButton(symbol: "arrow.clockwise", help: "Refresh system state") { model.refresh() }
            }
            .animation(.easeOut(duration: 0.2), value: model.capsLock)

            if let message = model.message {
                InlineMessage(text: message) { model.message = nil }
            }

            Group {
                switch tab {
                case .performance: SystemPerformanceView(detailed: true)
                case .battery: BatteryInsightsView()
                case .network: SystemNetworkView(model: model)
                case .volumes: SystemVolumesView(model: model, pendingEject: $pendingEject)
                case .events: SystemEventsView(model: model)
                }
            }
            .id(tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .onAppear { model.start() }
        .onChange(of: tab) { _, newValue in model.lastTab = newValue }
        .alert("Eject \(pendingEject?.name ?? "volume")?", isPresented: Binding(get: { pendingEject != nil }, set: { if !$0 { pendingEject = nil } })) {
            Button("Cancel", role: .cancel) { pendingEject = nil }
            Button("Eject") { if let volume = pendingEject { model.eject(volume) }; pendingEject = nil }
        } message: {
            Text("macOS will safely unmount and eject this device. Close files on it first; other volumes on the same device may also be unmounted.")
        }
    }
}

// MARK: Network

@MainActor private struct SystemNetworkView: View {
    @ObservedObject var model: SystemActivitiesModel
    @ObservedObject private var performance = SystemPerformanceMonitor.shared
    @State private var showInactive = false
    @State private var width: CGFloat = 1_000

    private var isWide: Bool { width >= 900 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ActivityMetrics.spacing) {
                if isWide {
                    HStack(alignment: .top, spacing: ActivityMetrics.spacing) {
                        connectionCard.frame(width: min(420, width * 0.4))
                        throughputCard
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    connectionCard
                    throughputCard
                }
                interfacesCard
                Text("SuperNotch reads interface byte counters and link state only — never addresses, destinations or packet contents. Tunnel interfaces can belong to VPNs or system services; their presence does not confirm a VPN is protecting traffic.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .activityWidth($width)
            .padding(.bottom, 12)
        }
        .onAppear { performance.acquireViewLease() }
        .onDisappear { performance.releaseViewLease() }
    }

    private var primaryKind: SystemInterfaceKind? {
        guard let name = model.path.primaryInterface else { return nil }
        return SystemInterfaceKind.classify(name: name, pathType: model.path.primaryType, wifiNames: model.wifiInterfaceNames)
    }

    private var connectionCard: some View {
        let connected = model.path.status == .connected
        let kind = primaryKind
        let tint: Color = connected ? (kind?.tint ?? .cyan) : .orange
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                ActivityIcon(symbol: connected ? (kind?.symbol ?? "network") : "wifi.slash", tint: tint, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connected ? (kind?.title ?? "Connected") : model.path.status == .waiting ? "Waiting for network" : "Offline")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(connected ? "Connected\(model.path.primaryInterface.map { " · \($0)" } ?? "")" : "No usable network connection")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                rateReadout("Download", symbol: "arrow.down", value: performance.networkThroughput?.receivedBytesPerSecond, color: .cyan)
                rateReadout("Upload", symbol: "arrow.up", value: performance.networkThroughput?.sentBytesPerSecond, color: .indigo)
            }
            if connected {
                FlowPills(items: capabilityPills)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .activityCard(tint: tint)
    }

    private var capabilityPills: [(String, Color, String?)] {
        var pills: [(String, Color, String?)] = []
        if model.path.supportsIPv4 { pills.append(("IPv4", .green, nil)) }
        if model.path.supportsIPv6 { pills.append(("IPv6", .green, nil)) }
        if model.path.supportsDNS { pills.append(("DNS", .green, nil)) }
        if model.path.isExpensive { pills.append(("Metered", .orange, "dollarsign.circle.fill")) }
        if model.path.isConstrained { pills.append(("Low Data Mode", .orange, "tortoise.fill")) }
        return pills
    }

    private func rateReadout(_ title: String, symbol: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            Text(ActivityFormat.rate(value))
                .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var throughputCard: some View {
        let chart = ActivityChart(series: [
            .init(values: performance.networkReceiveHistory, color: .cyan),
            .init(values: performance.networkSendHistory, color: .indigo)
        ], minimumScale: 100_000)
        let totals = performance.interfaceTotals.values.filter { SystemPerformanceMath.countsTowardNetworkTotal($0.name) }
        let received = totals.reduce(UInt64(0)) { $0 &+ $1.receivedBytes }
        let sent = totals.reduce(UInt64(0)) { $0 &+ $1.sentBytes }
        return VStack(alignment: .leading, spacing: 12) {
            ActivityCardHeader(title: "Throughput", symbol: "chart.xyaxis.line", tint: .cyan, subtitle: "Last 2 minutes · physical interfaces") {
                HStack(spacing: 12) {
                    legend("Download", .cyan)
                    legend("Upload", .indigo)
                }
            }
            ZStack {
                chart
                if performance.networkReceiveHistory.count < 2 {
                    Text("Collecting samples…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(minHeight: 150, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Text(ActivityFormat.rate(chart.resolvedMaximum))
                    .font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.3))
            }
            HStack(spacing: 16) {
                ActivityLegendRow(label: "Received since startup", value: ActivityFormat.bytes(Int64(clamping: received)), color: .cyan, symbol: "arrow.down")
                ActivityLegendRow(label: "Sent", value: ActivityFormat.bytes(Int64(clamping: sent)), color: .indigo, symbol: "arrow.up")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .activityCard()
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(title)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }

    /// An interface is worth showing by default when it is up and either
    /// usable according to Network.framework or has carried traffic.
    private func isActive(_ interface: SystemInterface) -> Bool {
        guard interface.isUp, interface.isRunning, !interface.isLoopback else { return false }
        if model.path.interfaceTypes[interface.name] != nil { return true }
        guard let totals = performance.interfaceTotals[interface.name] else { return false }
        return totals.receivedBytes > 0 || totals.sentBytes > 0
    }

    private var visibleInterfaces: [SystemInterface] {
        let primary = model.path.primaryInterface
        return model.interfaces
            .filter { showInactive || isActive($0) }
            .sorted { lhs, rhs in
                if (lhs.name == primary) != (rhs.name == primary) { return lhs.name == primary }
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private var interfacesCard: some View {
        let visible = visibleInterfaces
        let activeCount = model.interfaces.filter(isActive).count
        return VStack(alignment: .leading, spacing: 8) {
            ActivityCardHeader(title: "Interfaces", symbol: "point.3.connected.trianglepath.dotted", tint: .teal, subtitle: "\(activeCount) in use · \(model.interfaces.count) total") {
                HStack(spacing: 8) {
                    Text("Show all").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    NotchToggle(isOn: $showInactive).accessibilityLabel("Show inactive interfaces")
                }
            }
            .padding(.bottom, 4)
            if visible.isEmpty {
                ActivityPlaceholder(text: "No active interfaces", symbol: "network.slash")
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, interface in
                    if index > 0 { Divider().overlay(Color.white.opacity(0.04)) }
                    interfaceRow(interface)
                }
            }
        }
        .activityCard()
        .animation(.easeOut(duration: 0.2), value: showInactive)
    }

    private func interfaceRow(_ interface: SystemInterface) -> some View {
        let kind = model.kind(for: interface)
        let rate = performance.interfaceThroughput[interface.name]
        let active = interface.isUp && interface.isRunning
        return HStack(spacing: 12) {
            ActivityIcon(symbol: kind.symbol, tint: active ? kind.tint : .gray, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.system(size: 13, weight: .semibold))
                    Text(interface.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                    if interface.name == model.path.primaryInterface {
                        Text("PRIMARY").font(.system(size: 8, weight: .bold)).tracking(0.5).foregroundStyle(.green)
                            .padding(.horizontal, 5).padding(.vertical, 2).background(.green.opacity(0.14), in: Capsule())
                    }
                }
                Text(interface.summary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            Spacer(minLength: 12)
            if active, !interface.isLoopback {
                HStack(spacing: 14) {
                    rateLabel("arrow.down", rate?.receivedBytesPerSecond, .cyan)
                    rateLabel("arrow.up", rate?.sentBytesPerSecond, .indigo)
                }
            }
            Circle().fill(active ? Color.green : .white.opacity(0.2)).frame(width: 7, height: 7)
                .accessibilityLabel(active ? "Active" : "Inactive")
        }
        .padding(.vertical, 7)
        .opacity(active ? 1 : 0.6)
    }

    private func rateLabel(_ symbol: String, _ value: Double?, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(ActivityFormat.rate(value)).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .frame(minWidth: 84, alignment: .trailing)
        .fixedSize()
    }
}

/// Pills that wrap onto multiple lines.
private struct FlowPills: View {
    let items: [(String, Color, String?)]

    var body: some View {
        WrapLayout(spacing: 6) {
            ForEach(items, id: \.0) { item in
                ActivityPill(text: item.0, color: item.1, symbol: item.2)
            }
        }
    }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if proposed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], proposed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: Volumes

@MainActor private struct SystemVolumesView: View {
    @ObservedObject var model: SystemActivitiesModel
    @Binding var pendingEject: SystemMountedVolume?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ActivityMetrics.spacing) {
                summary
                if model.volumes.isEmpty {
                    ActivityPlaceholder(
                        text: model.isLoadingVolumes ? "Reading volumes…" : "No volumes found",
                        symbol: model.isLoadingVolumes ? nil : "externaldrive.badge.questionmark"
                    )
                    .frame(minHeight: 220)
                    .activityCard()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: ActivityMetrics.spacing, alignment: .top)], spacing: ActivityMetrics.spacing) {
                        ForEach(model.volumes) { volume in
                            volumeCard(volume)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var summary: some View {
        let free = model.volumes.filter(\.isLocal).compactMap(\.available).reduce(Int64(0), +)
        let external = model.volumes.filter { $0.canEject }.count
        return HStack(spacing: 8) {
            ActivityPill(text: "\(model.volumes.count) \(model.volumes.count == 1 ? "volume" : "volumes") mounted", color: .indigo, symbol: "externaldrive.fill")
            if external > 0 {
                ActivityPill(text: "\(external) ejectable", color: .orange, symbol: "eject.fill")
            }
            ActivityPill(text: "\(ActivityFormat.bytes(free)) free on local disks", color: .green, symbol: "square.stack.3d.up.fill")
            Spacer(minLength: 8)
            if model.isLoadingVolumes { ProgressView().controlSize(.small) }
            Button("Storage Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(PillButtonStyle())
        }
    }

    private func volumeCard(_ volume: SystemMountedVolume) -> some View {
        let fraction = volume.usedFraction
        let barColor: Color = (fraction ?? 0) >= 0.95 ? .red : (fraction ?? 0) >= 0.85 ? .orange : volume.tint
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ActivityIcon(symbol: volume.symbol, tint: volume.tint, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(volume.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(volume.url.path).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                ActivityIconButton(symbol: "folder", help: "Show \(volume.name) in Finder") { NSWorkspace.shared.open(volume.url) }
                if volume.canEject {
                    if model.ejecting.contains(volume.id) {
                        ProgressView().controlSize(.small).frame(width: 30, height: 30)
                    } else {
                        ActivityIconButton(symbol: "eject.fill", help: "Safely eject \(volume.name)") { pendingEject = volume }
                    }
                }
            }
            HStack(spacing: 5) {
                ForEach(badges(for: volume), id: \.self) { badge in
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold)).tracking(0.3)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.white.opacity(0.07), in: Capsule())
                        .fixedSize()
                }
            }
            if let fraction, let capacity = volume.capacity, let available = volume.available {
                VStack(alignment: .leading, spacing: 7) {
                    ActivityBar(fraction: fraction, color: barColor, height: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(ActivityFormat.bytes(available)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text("free of \(ActivityFormat.bytes(capacity))").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Text("\(ActivityFormat.percent(fraction * 100)) used").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(barColor)
                    }
                }
            } else {
                Text("Capacity unavailable").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(minHeight: 150, alignment: .top)
        .activityCard(tint: volume.tint)
    }

    private func badges(for volume: SystemMountedVolume) -> [String] {
        var badges: [String] = []
        if volume.isRoot { badges.append("STARTUP") }
        if !volume.isLocal { badges.append("NETWORK") }
        else { badges.append(volume.isInternal && !volume.removable ? "INTERNAL" : "EXTERNAL") }
        if volume.isReadOnly { badges.append("READ-ONLY") }
        if let format = volume.format, !format.isEmpty { badges.append(format.uppercased()) }
        return badges
    }
}

// MARK: Events

@MainActor private struct SystemEventsView: View {
    @ObservedObject var model: SystemActivitiesModel
    @State private var filter: SystemEventKind?

    private var filtered: [SystemObservedEvent] {
        guard let filter else { return model.events }
        return model.events.filter { $0.kind == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ActivityMetrics.spacing) {
            HStack(spacing: 6) {
                chip(nil, title: "All", count: model.events.count, tint: .white)
                ForEach(SystemEventKind.allCases) { kind in
                    let count = model.events.filter { $0.kind == kind }.count
                    if count > 0 || filter == kind {
                        chip(kind, title: kind.rawValue, count: count, tint: kind.tint)
                    }
                }
                Spacer(minLength: 8)
                Button("Clear") {
                    withAnimation(.easeOut(duration: 0.2)) { model.clearEvents(); filter = nil }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(model.events.isEmpty)
                .opacity(model.events.isEmpty ? 0.4 : 1)
            }

            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 26, weight: .medium)).foregroundStyle(.orange)
                        .frame(width: 60, height: 60).background(.orange.opacity(0.12), in: Circle())
                    Text(model.events.isEmpty ? "Nothing has changed yet" : "No \(filter?.rawValue.lowercased() ?? "") events")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Network changes, drives, power, sleep and Caps Lock appear here as they happen during this session.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .activityCard()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let items = filtered
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, event in
                            eventRow(event, isLast: index == items.count - 1)
                        }
                    }
                    .activityCard(padding: 14)
                    .padding(.bottom, 12)
                }
            }
            Text("Observed by SuperNotch during this session only. Changes that happen between samples may be missed; this is not the system log.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.3))
        }
    }

    private func chip(_ kind: SystemEventKind?, title: String, count: Int, tint: Color) -> some View {
        let selected = filter == kind
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { filter = kind }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .medium))
                Text("\(count)").font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(selected ? tint : .white.opacity(0.4))
            }
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.6))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? tint.opacity(0.16) : .white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? tint.opacity(0.35) : .clear, lineWidth: 0.7))
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private func eventRow(_ event: SystemObservedEvent, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ActivityIcon(symbol: event.icon, tint: event.kind.tint, size: 30)
                if !isLast {
                    Rectangle().fill(.white.opacity(0.07)).frame(width: 1.5).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(event.message).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(event.kind.rawValue).foregroundStyle(event.kind.tint)
                    Text("·")
                    RelativeTimeText(date: event.date)
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.top, 5)
            .padding(.bottom, isLast ? 0 : 16)
            Spacer(minLength: 8)
            Text(event.date.formatted(date: .omitted, time: .standard))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 8)
        }
        .accessibilityElement(children: .combine)
    }
}
