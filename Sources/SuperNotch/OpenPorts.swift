import SwiftUI
import AppKit
import Darwin

// MARK: - Model

/// One listening socket reading, before the IPv4 and IPv6 sockets of the same
/// process and port are merged.
struct OpenPortSample: Equatable, Sendable {
    let port: UInt16
    let pid: Int32
    /// The bound local address, such as `127.0.0.1`, `0.0.0.0` or `::1`.
    let address: String
    /// Kernel process name, used when the executable path is unreadable.
    let processName: String
    let executablePath: String?
    /// Whether the process runs as the current user.
    let isOwnProcess: Bool
}

/// A port something on this Mac is listening on.
struct OpenPortEntry: Identifiable, Equatable, Sendable {
    let port: UInt16
    let pid: Int32
    /// What people recognize the listener as, such as `postgres` or `Code Helper (Plugin)`.
    let name: String
    let executablePath: String?
    /// The application bundle the executable belongs to, used for its icon.
    let appPath: String?
    /// Bound local addresses, IPv4 first. A process on both stacks appears once.
    let addresses: [String]
    /// Whether the process runs as the current user, so it can be asked to quit.
    let isOwnProcess: Bool

    var id: String { "\(pid).\(port)" }

    /// Whether every bound address is reachable only from this Mac.
    var isLocalOnly: Bool { addresses.allSatisfy(OpenPortMath.isLoopback) }

    /// The name of the app the executable lives in, when it differs from `name`.
    var appName: String? {
        guard let appPath else { return nil }
        let app = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        return app == name ? nil : app
    }

    /// Bound addresses and reach, such as "127.0.0.1 · local only".
    var detail: String {
        let reach = isLocalOnly ? "local only" : "on your network"
        return addresses.joined(separator: ", ") + " · " + reach
    }

    /// The address a browser should open. Loopback listeners read better as `localhost`.
    var webURL: URL? { URL(string: "http://\(OpenPortMath.webHost(for: self)):\(port)") }
}

enum OpenPortMath {
    /// Loopback and link-local addresses only this Mac can reach.
    static func isLoopback(_ address: String) -> Bool {
        address == "::1" || address.hasPrefix("127.")
    }

    /// Wildcard binds, which accept connections on every interface.
    static func isWildcard(_ address: String) -> Bool {
        address == "0.0.0.0" || address == "::"
    }

    /// IPv4 before IPv6, each group sorted, so a merged entry reads the same every scan.
    static func sortAddresses(_ addresses: [String]) -> [String] {
        addresses.sorted { first, second in
            let firstIsV6 = first.contains(":")
            let secondIsV6 = second.contains(":")
            if firstIsV6 != secondIsV6 { return secondIsV6 }
            return first < second
        }
    }

    /// The executable's own name, which is what Activity Monitor and `lsof` show.
    /// Helpers keep their own name instead of the parent app's.
    static func displayName(executablePath: String?, processName: String) -> String {
        guard let executablePath, !executablePath.isEmpty else { return processName }
        let last = URL(fileURLWithPath: executablePath).lastPathComponent
        return last.isEmpty ? processName : last
    }

    /// `localhost` for loopback binds, the bound address for anything else, and
    /// `localhost` again for wildcards because that is how they are used locally.
    static func webHost(for entry: OpenPortEntry) -> String {
        guard let address = entry.addresses.first(where: { !isLoopback($0) && !isWildcard($0) }) else { return "localhost" }
        return address.contains(":") ? "[\(address)]" : address
    }

    /// Merges the sockets of one process and port into a single entry, ordered by
    /// port so the list reads like a port map.
    static func entries(from samples: [OpenPortSample]) -> [OpenPortEntry] {
        struct Key: Hashable { let pid: Int32; let port: UInt16 }
        var addresses: [Key: [String]] = [:]
        var firstSample: [Key: OpenPortSample] = [:]
        var order: [Key] = []

        for sample in samples {
            let key = Key(pid: sample.pid, port: sample.port)
            if firstSample[key] == nil {
                firstSample[key] = sample
                order.append(key)
            }
            var bound = addresses[key] ?? []
            if !bound.contains(sample.address) {
                bound.append(sample.address)
                addresses[key] = bound
            }
        }

        return order.compactMap { key -> OpenPortEntry? in
            guard let sample = firstSample[key] else { return nil }
            return OpenPortEntry(
                port: key.port,
                pid: key.pid,
                name: displayName(executablePath: sample.executablePath, processName: sample.processName),
                executablePath: sample.executablePath,
                appPath: sample.executablePath.flatMap(AppResourceMath.bundlePath(forExecutable:)),
                addresses: sortAddresses(addresses[key] ?? [sample.address]),
                isOwnProcess: sample.isOwnProcess
            )
        }
        .sorted {
            if $0.port != $1.port { return $0.port < $1.port }
            if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.pid < $1.pid
        }
    }
}

// MARK: - Scanner

/// Finds listening TCP sockets with `libproc`, without spawning `lsof` or any
/// other process. Only sockets of processes this user may inspect are visible,
/// which is every process the user owns.
private final class OpenPortScanner: @unchecked Sendable {
    private struct Identity {
        let processName: String
        let executablePath: String?
        let isOwnProcess: Bool
    }

    private var identities: [Int32: Identity] = [:]
    private let ownUID = getuid()

    func reset() { identities = [:] }

    func scan() -> [OpenPortEntry] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(capacity) + 128)
        // The buffer size is in bytes, while both calls answer in PIDs.
        let written = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard written > 0 else { return [] }
        let count = min(pids.count, Int(written))

        var samples: [OpenPortSample] = []
        var alive: Set<Int32> = []
        alive.reserveCapacity(count)

        for pid in pids.prefix(count) where pid > 0 {
            alive.insert(pid)
            let ports = listeningPorts(pid)
            guard !ports.isEmpty else { continue }
            let identity = identity(for: pid)
            for port in ports {
                samples.append(OpenPortSample(
                    port: port.port,
                    pid: pid,
                    address: port.address,
                    processName: identity.processName,
                    executablePath: identity.executablePath,
                    isOwnProcess: identity.isOwnProcess
                ))
            }
        }
        identities = identities.filter { alive.contains($0.key) }
        return OpenPortMath.entries(from: samples)
    }

    /// Every listening TCP socket of one process. Processes owned by another
    /// user return nothing, because their file descriptors are not readable.
    private func listeningPorts(_ pid: Int32) -> [(port: UInt16, address: String)] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let written = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard written > 0 else { return [] }

        var result: [(port: UInt16, address: String)] = []
        for descriptor in descriptors.prefix(Int(written) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let read = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, pointer, Int32(MemoryLayout<socket_fdinfo>.size))
            }
            guard read > 0, info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            guard port > 0, let address = address(family: info.psi.soi_family, socket: tcp.tcpsi_ini) else { continue }
            result.append((port, address))
        }
        return result
    }

    private func address(family: Int32, socket: in_sockinfo) -> String? {
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch family {
        case AF_INET:
            var addr = socket.insi_laddr.ina_46.i46a_addr4
            guard inet_ntop(AF_INET, &addr, &text, socklen_t(text.count)) != nil else { return nil }
        case AF_INET6:
            var addr = socket.insi_laddr.ina_6
            guard inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count)) != nil else { return nil }
        default:
            return nil
        }
        return String(cString: text)
    }

    /// Executable paths and owners are cached per PID; they never change while a process lives.
    private func identity(for pid: Int32) -> Identity {
        if let cached = identities[pid] { return cached }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let named = proc_name(pid, &name, UInt32(name.count))
        var info = proc_bsdinfo()
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        let identity = Identity(
            processName: named > 0 ? String(cString: name) : "Process \(pid)",
            executablePath: length > 0 ? String(cString: path) : nil,
            isOwnProcess: read > 0 ? info.pbi_uid == ownUID : false
        )
        identities[pid] = identity
        return identity
    }

    /// Whether `pid` is still the process the entry was scanned from, so a
    /// reused PID is never signalled by mistake.
    static func matches(_ entry: OpenPortEntry) -> Bool {
        guard let expected = entry.executablePath else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(entry.pid, &path, UInt32(path.count))
        return length > 0 && String(cString: path) == expected
    }
}

// MARK: - Monitor

/// Keeps the listening-port list fresh while something shows it. Scanning costs
/// a few milliseconds, so it only runs while leased or on an explicit refresh.
@MainActor
final class OpenPortsMonitor: ObservableObject {
    static let shared = OpenPortsMonitor()

    @Published private(set) var entries: [OpenPortEntry] = []
    @Published private(set) var hasScanned = false
    @Published private(set) var isScanning = false
    /// The outcome of the last quit or copy, shown under the list.
    @Published var message: String?

    private let queue = DispatchQueue(label: "SuperNotch.open-ports", qos: .utility)
    private let scanner = OpenPortScanner()
    private var timer: DispatchSourceTimer?
    private var leases = 0
    private var generation: UInt64 = 0

    func acquireLease() {
        leases += 1
        guard timer == nil else { return }
        generation &+= 1
        let generation = generation
        let scanner = scanner
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            let result = autoreleasepool { scanner.scan() }
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
        isScanning = false
        let scanner = scanner
        queue.async { scanner.reset() }
    }

    /// A one-off scan, used by the refresh button and after a process is asked to quit.
    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        generation &+= 1
        let generation = generation
        let scanner = scanner
        queue.async { [weak self] in
            let result = autoreleasepool { scanner.scan() }
            Task { @MainActor [weak self] in
                self?.isScanning = false
                self?.apply(result, generation: generation, force: true)
            }
        }
    }

    func copyToPasteboard(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = "Copied \(label)."
    }

    /// Asks the listener to quit. `force` sends `SIGKILL`, which does not let it
    /// save anything, so callers confirm first.
    func quit(_ entry: OpenPortEntry, force: Bool) {
        guard entry.pid != getpid() else {
            message = "Port \(entry.port) is SuperNotch's own local sharing server. Turn it off in Tools."
            return
        }
        guard entry.isOwnProcess else {
            message = "\(entry.name) runs as another user. Quit it from a terminal."
            return
        }
        guard OpenPortScanner.matches(entry) else {
            message = "\(entry.name) already stopped."
            refresh()
            return
        }
        guard kill(entry.pid, force ? SIGKILL : SIGTERM) == 0 else {
            message = "Could not quit \(entry.name) (\(String(cString: strerror(errno))))."
            return
        }
        message = force ? "Force quit \(entry.name)." : "Asked \(entry.name) to quit."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.refresh() }
    }

    func icon(for entry: OpenPortEntry) -> NSImage? {
        guard let path = entry.appPath ?? entry.executablePath else { return nil }
        return SmallIconCache.fileIcon(for: path, pixels: 44)
    }

    private func apply(_ result: [OpenPortEntry], generation: UInt64, force: Bool = false) {
        guard force || (generation == self.generation && timer != nil) else { return }
        if entries != result { entries = result }
        hasScanned = true
    }
}

// MARK: - Panel section

/// The open ports list shown in the menu bar panel: every port something on this
/// Mac listens on, with the process behind it and per-port actions.
@MainActor
struct OpenPortsSection: View {
    /// Closes the panel, so an action can open a window or a browser.
    let close: () -> Void

    @ObservedObject private var monitor = OpenPortsMonitor.shared
    @ObservedObject private var preferences = MenuBarPreferences.shared
    @State private var expanded: String?
    @State private var showsAll = false
    /// Whether this view is the one holding the scanner lease, so folding the
    /// section open and closed never unbalances it.
    @State private var holdsLease = false

    private static let collapsedRows = 6

    private var isOpen: Bool { preferences.portsExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: isOpen ? 9 : 0) {
            header
            if isOpen {
                if !monitor.hasScanned {
                    ActivityPlaceholder(text: "Looking for listening ports…")
                } else if monitor.entries.isEmpty {
                    ActivityPlaceholder(text: "Nothing is listening on a port", symbol: "checkmark.circle")
                } else {
                    list
                }
                if let message = monitor.message {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                        .transition(.opacity)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.7))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: expanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isOpen)
        .onAppear { start() }
        .onChange(of: isOpen) { _, open in
            // A closed section keeps its count but stops sampling.
            setLease(open)
            if open {
                monitor.refresh()
            } else {
                expanded = nil
                showsAll = false
                monitor.message = nil
            }
        }
        .onDisappear {
            setLease(false)
            monitor.message = nil
        }
    }

    /// Open sections sample on a timer; a closed one scans once so its count is honest.
    private func start() {
        if isOpen {
            setLease(true)
        } else {
            monitor.refresh()
        }
    }

    private func setLease(_ needed: Bool) {
        guard needed != holdsLease else { return }
        holdsLease = needed
        if needed {
            monitor.acquireLease()
        } else {
            monitor.releaseLease()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                preferences.portsExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                    Text("OPEN PORTS").font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(.white.opacity(0.45))
                    if monitor.hasScanned, !monitor.entries.isEmpty {
                        Text(verbatim: "\(monitor.entries.count)")
                            .font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandPressStyle())
            .help(isOpen ? "Hide the listening ports" : "Show the listening ports")
            .accessibilityLabel("Open ports")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint(isOpen ? "Hides the port list" : "Shows the port list")
            if isOpen {
                Button {
                    monitor.message = nil
                    monitor.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(monitor.isScanning ? 360 : 0))
                        .animation(monitor.isScanning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: monitor.isScanning)
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(IslandPressStyle())
                .help("Scan for listening ports again")
                .accessibilityLabel("Rescan ports")
            }
        }
    }

    private var list: some View {
        let entries = showsAll ? monitor.entries : Array(monitor.entries.prefix(Self.collapsedRows))
        return VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().overlay(Color.white.opacity(0.05)) }
                OpenPortRow(
                    entry: entry,
                    isExpanded: expanded == entry.id,
                    toggle: { expanded = expanded == entry.id ? nil : entry.id },
                    close: close
                )
            }
            if monitor.entries.count > Self.collapsedRows {
                Divider().overlay(Color.white.opacity(0.05))
                Button { showsAll.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: showsAll ? "Show fewer" : "Show \(monitor.entries.count - Self.collapsedRows) more")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: showsAll ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(IslandPressStyle())
            }
        }
    }
}

/// One port row: the port, the process behind it, and the actions it supports.
@MainActor
private struct OpenPortRow: View {
    let entry: OpenPortEntry
    let isExpanded: Bool
    let toggle: () -> Void
    let close: () -> Void

    @ObservedObject private var monitor = OpenPortsMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 9) {
                    if let icon = monitor.icon(for: entry) {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
                    } else {
                        ActivityIcon(symbol: "powerplug.fill", tint: .teal, size: 18)
                    }
                    Text(verbatim: "\(entry.port)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    Text(entry.name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    if !entry.isLocalOnly {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
                            .help("Reachable from your network")
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(IslandPressStyle())
            .help(rowHelp)
            .accessibilityLabel(Text(verbatim: "Port \(entry.port), \(entry.name)"))
            .accessibilityValue(entry.detail)
            .accessibilityHint("Shows port actions")

            if isExpanded { actions }
        }
    }

    /// Everything about the listener, for people who hover instead of expanding.
    private var rowHelp: String {
        var text = "\(entry.detail) · pid \(entry.pid)"
        if let path = entry.executablePath { text += "\n" + path }
        return text
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(entry.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Text(verbatim: "pid \(entry.pid)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.3))
                if let appName = entry.appName {
                    Text(appName).font(.system(size: 10)).foregroundStyle(.white.opacity(0.3)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                action("number", "Port", .teal) { monitor.copyToPasteboard("\(entry.port)", label: "port \(entry.port)") }
                if let url = entry.webURL {
                    action("link", "Address", .indigo) { monitor.copyToPasteboard(url.absoluteString, label: url.absoluteString) }
                    action("safari", "Open", .blue) { perform { NSWorkspace.shared.open(url) } }
                }
                if let path = entry.appPath ?? entry.executablePath {
                    action("folder", "Reveal", .gray) {
                        perform { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    }
                }
                Spacer(minLength: 0)
            }
            if entry.isOwnProcess, entry.pid != getpid() {
                HStack(spacing: 6) {
                    action("stop.circle", "Quit", .orange) { monitor.quit(entry, force: false) }
                    action("xmark.octagon", "Force quit", .red) { confirmForceQuit() }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private func action(_ symbol: String, _ title: String, _ tint: Color, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(IslandPressStyle())
        .help(title)
    }

    /// Force quitting loses unsaved work, so it is confirmed. The panel closes
    /// first because a transient popover cannot keep focus behind an alert.
    /// Closes the panel before an action opens a window, a browser or an alert,
    /// matching how the rest of the panel behaves.
    private func perform(_ run: @escaping () -> Void) {
        close()
        DispatchQueue.main.async { run() }
    }

    private func confirmForceQuit() {
        let entry = entry
        perform {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Force quit \(entry.name)?"
            alert.informativeText = "Port \(entry.port) is released immediately and \(entry.name) cannot save anything first."
            alert.addButton(withTitle: "Force Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            OpenPortsMonitor.shared.quit(entry, force: true)
        }
    }
}
