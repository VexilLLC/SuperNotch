import AppKit
import Combine

/// Comparing observations prevents startup notifications and repeated polling alerts.
struct IslandObservation: Equatable {
    var hasBattery: Bool
    var battery: Int
    var charging: Bool
    var connected: Bool
    var capsLock: Bool
    var shelfIDs: Set<UUID>
    var focusRunning: Bool
    var focusRemaining: Double
}

struct IslandActivityDetector {
    private var previous: IslandObservation?
    mutating func observe(_ value: IslandObservation) -> IslandActivity? {
        defer { previous = value }
        guard let old = previous else { return nil }
        let added = value.shelfIDs.subtracting(old.shelfIDs).count
        if added > 0 {
            return IslandActivity(title: added == 1 ? "File added" : "\(added) files added", detail: "Ready in your tray", symbol: "tray.and.arrow.down.fill", kind: .file)
        }
        if old.focusRunning != value.focusRunning {
            return IslandActivity(title: value.focusRunning ? "Focus started" : (value.focusRemaining <= 0 ? "Focus complete" : "Focus paused"), detail: value.focusRunning ? "Make room for one thing" : (value.focusRemaining <= 0 ? "Time for a break" : "Resume whenever you're ready"), symbol: value.focusRunning ? "timer" : "pause.circle.fill", kind: .focus)
        }
        if old.capsLock != value.capsLock {
            return IslandActivity(title: "Caps Lock", detail: value.capsLock ? "On" : "Off", symbol: "capslock.fill", kind: .capsLock)
        }
        if value.hasBattery && old.hasBattery && old.charging != value.charging {
            return IslandActivity(title: value.charging ? "Charging" : "Charging stopped", detail: "\(value.battery)% battery", symbol: value.charging ? "battery.100percent.bolt" : "battery.100percent", kind: .power, level: Double(value.battery) / 100)
        }
        if value.hasBattery && old.hasBattery && !value.charging && [20, 10, 5].contains(where: { old.battery > $0 && value.battery <= $0 }) {
            return IslandActivity(title: "Low battery", detail: "\(value.battery)% remaining", symbol: "battery.25percent", kind: .power, level: Double(value.battery) / 100)
        }
        if old.connected != value.connected {
            return IslandActivity(title: value.connected ? "Connection restored" : "You're offline", detail: value.connected ? "Network available" : "Check your connection", symbol: value.connected ? "wifi" : "wifi.slash", kind: .network)
        }
        return nil
    }
}

@MainActor final class IslandActivityController: ObservableObject {
    static let shared = IslandActivityController()
    @Published private(set) var current: IslandActivity?
    private let isEnabled: @MainActor () -> Bool
    private let onPresentationChange: @MainActor () -> Void
    init(isEnabled: @escaping @MainActor () -> Bool = { Preferences.shared.liveActivities }, onPresentationChange: @escaping @MainActor () -> Void = { AppDelegate.shared?.reposition() }) {
        self.isEnabled = isEnabled
        self.onPresentationChange = onPresentationChange
    }
    private var detector = IslandActivityDetector()
    private var cancellables: Set<AnyCancellable> = []
    private var flagsMonitors: [Any] = []
    private var started = false
    private var expiration: Task<Void, Never>?
    private var generation = 0
    private var baselineUntil = Date.distantPast

    func start() {
        guard !started else { return }
        started = true
        baselineUntil = Date().addingTimeInterval(2)
        sample()

        let system = SystemMonitor.shared
        let focus = ProductivityStore.shared
        let shelf = FileShelfStore.shared
        let changes: [AnyPublisher<Void, Never>] = [
            system.$hasBattery.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            system.$battery.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            system.$charging.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            system.$connected.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            system.didRefresh.eraseToAnyPublisher(),
            focus.$running.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            shelf.$items.map { Set($0.map(\.id)) }.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
            .sink { [weak self] in self?.sample() }
            .store(in: &cancellables)

        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) { flagsMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in handler(event); return event }) { flagsMonitors.append(monitor) }
    }
    func stop() {
        guard started else { return }
        started = false
        cancellables.removeAll()
        flagsMonitors.forEach { NSEvent.removeMonitor($0) }
        flagsMonitors.removeAll()
        dismiss()
        detector = IslandActivityDetector()
    }
    private func sample() {
        let system = SystemMonitor.shared
        let focus = ProductivityStore.shared
        let snapshot = IslandObservation(hasBattery: system.hasBattery, battery: system.battery, charging: system.charging, connected: system.connected, capsLock: NSEvent.modifierFlags.contains(.capsLock), shelfIDs: Set(FileShelfStore.shared.items.map(\.id)), focusRunning: focus.running, focusRemaining: focus.remaining)
        let activity = detector.observe(snapshot)
        guard Date() >= baselineUntil, isEnabled() else { return }
        if let activity { present(activity) }
    }
    func present(_ activity: IslandActivity, duration: TimeInterval = 3) {
        guard isEnabled() else { return }
        generation += 1
        let token = generation
        expiration?.cancel()
        current = activity
        onPresentationChange()
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, self.generation == token else { return }
            self.dismiss()
        }
    }
    func dismiss() {
        generation += 1
        expiration?.cancel(); expiration = nil
        guard current != nil else { return }
        current = nil
        onPresentationChange()
    }
}
