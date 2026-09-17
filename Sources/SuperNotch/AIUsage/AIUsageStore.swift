import Foundation
import Combine

private struct AIUsageCacheDocument: Codable, Sendable {
    var version = 1
    var snapshots: [AIUsageSnapshot]
}

@MainActor
final class AIUsageStore: ObservableObject {
    static let shared = AIUsageStore()
    static let refreshInterval: TimeInterval = 5 * 60

    @Published private(set) var snapshots: [AIUsageProviderID: AIUsageSnapshot] = [:]
    @Published private(set) var statuses: [AIUsageProviderID: AIUsageProviderStatus] = [:]
    @Published private(set) var detectedProviders: Set<AIUsageProviderID> = []
    @Published private(set) var enabledProviders: Set<AIUsageProviderID> = []
    @Published private(set) var openCodeKeySource: OpenCodeGoKeySource = OpenCodeGoAPIKeyStore().source()
    @Published private(set) var claudeKeychainAccessEnabled: Bool

    @Published var showRemaining: Bool {
        didSet { defaults.set(showRemaining, forKey: Keys.showRemaining) }
    }
    @Published var exactResetTimes: Bool {
        didSet { defaults.set(exactResetTimes, forKey: Keys.exactResetTimes) }
    }
    @Published var pinEnabled: Bool {
        didSet { defaults.set(pinEnabled, forKey: Keys.pinEnabled) }
    }
    @Published var pinnedProvider: AIUsageProviderID {
        didSet { defaults.set(pinnedProvider.rawValue, forKey: Keys.pinnedProvider) }
    }
    @Published var usageAlertsEnabled: Bool {
        didSet { defaults.set(usageAlertsEnabled, forKey: Keys.usageAlerts) }
    }

    private enum Keys {
        static let providerPrefix = "aiUsage.provider."
        static let showRemaining = "aiUsage.showRemaining"
        static let exactResetTimes = "aiUsage.exactResetTimes"
        static let pinEnabled = "aiUsage.pinEnabled"
        static let pinnedProvider = "aiUsage.pinnedProvider"
        static let usageAlerts = "aiUsage.alerts"
    }

    private let providers: [AIUsageProviderID: any AIUsageProvider]
    private let defaults: UserDefaults
    private let cacheURL: URL
    private var loop: Task<Void, Never>?
    private var refreshing: Set<AIUsageProviderID> = []

    init(
        providers: [any AIUsageProvider] = [CodexUsageProvider(), ClaudeUsageProvider(), OpenCodeUsageProvider()],
        defaults: UserDefaults = .standard,
        cacheURL: URL? = nil
    ) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.defaults = defaults
        let support = SuperNotchStorage.baseDirectory
        self.cacheURL = cacheURL ?? support.appendingPathComponent("ai-usage-snapshots-v1.json")
        self.showRemaining = defaults.object(forKey: Keys.showRemaining) as? Bool ?? true
        self.exactResetTimes = defaults.bool(forKey: Keys.exactResetTimes)
        self.pinEnabled = defaults.bool(forKey: Keys.pinEnabled)
        self.pinnedProvider = AIUsageProviderID(rawValue: defaults.string(forKey: Keys.pinnedProvider) ?? "") ?? .codex
        self.usageAlertsEnabled = defaults.bool(forKey: Keys.usageAlerts)
        self.claudeKeychainAccessEnabled = ClaudeKeychainAccess.isEnabled(in: defaults)

        if let cached = Self.loadCache(from: self.cacheURL) {
            self.snapshots = Dictionary(uniqueKeysWithValues: cached.map { ($0.providerID, $0) })
            for snapshot in cached { self.statuses[snapshot.providerID] = .available }
        }
        for id in AIUsageProviderID.allCases {
            if defaults.object(forKey: Keys.providerPrefix + id.rawValue) as? Bool == true {
                enabledProviders.insert(id)
            }
            if statuses[id] == nil { statuses[id] = .idle }
        }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            guard let self else { return }
            await self.detectAndSeedProviders()
            // A cache written by the first usage release has quotas but no
            // local history. Backfill those providers once on launch even if
            // the quota snapshot is still inside its five-minute TTL.
            await withTaskGroup(of: Void.self) { group in
                for id in self.enabledProviders {
                    let needsHistoryBackfill = self.snapshots[id]?.history == nil
                    group.addTask { await self.refresh(id, force: needsHistoryBackfill) }
                }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Self.refreshInterval)) } catch { return }
                await self.refreshAll(force: false)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func isEnabled(_ id: AIUsageProviderID) -> Bool { enabledProviders.contains(id) }

    func setEnabled(_ enabled: Bool, for id: AIUsageProviderID) {
        if enabled { enabledProviders.insert(id) } else { enabledProviders.remove(id) }
        defaults.set(enabled, forKey: Keys.providerPrefix + id.rawValue)
        if enabled {
            Task { await refresh(id, force: true) }
        }
    }

    func status(for id: AIUsageProviderID) -> AIUsageProviderStatus { statuses[id] ?? .idle }
    func snapshot(for id: AIUsageProviderID) -> AIUsageSnapshot? { snapshots[id] }

    func isStale(_ snapshot: AIUsageSnapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.fetchedAt) >= Self.refreshInterval
    }

    func currentOpenCodeCustomKey() -> String? {
        try? OpenCodeGoAPIKeyStore().customKey()
    }

    func saveOpenCodeKey(_ key: String) throws {
        try OpenCodeGoAPIKeyStore().save(key)
        openCodeKeySource = OpenCodeGoAPIKeyStore().source()
        setEnabled(true, for: .openCode)
        detectedProviders.insert(.openCode)
        Task { await refresh(.openCode, force: true) }
    }

    func clearOpenCodeCustomKey() throws {
        try OpenCodeGoAPIKeyStore().deleteCustomKey()
        openCodeKeySource = OpenCodeGoAPIKeyStore().source()
        Task { await refresh(.openCode, force: true) }
    }

    func refreshCredentialStatus() {
        openCodeKeySource = OpenCodeGoAPIKeyStore().source()
    }

    func setClaudeKeychainAccess(_ enabled: Bool) {
        claudeKeychainAccessEnabled = enabled
        defaults.set(enabled, forKey: ClaudeKeychainAccess.defaultsKey)
        if enabled {
            detectedProviders.insert(.claude)
            setEnabled(true, for: .claude)
        } else if snapshots[.claude] == nil {
            statuses[.claude] = .idle
        }
    }

    var attentionItems: [AIUsageAttentionItem] {
        snapshots.values
            .filter { enabledProviders.contains($0.providerID) }
            .flatMap { snapshot in
                snapshot.metrics.compactMap { metric -> AIUsageAttentionItem? in
                    guard let quota = metric.quota else { return nil }
                    return AIUsageAttentionItem(providerID: snapshot.providerID, metric: metric, severity: AIUsageFormat.severity(for: quota))
                }
            }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                return (lhs.metric.quota?.remainingFraction ?? 1) < (rhs.metric.quota?.remainingFraction ?? 1)
            }
    }

    var pinnedMetric: (AIUsageProviderID, AIUsageMetric)? {
        guard pinEnabled, enabledProviders.contains(pinnedProvider),
              let snapshot = snapshots[pinnedProvider],
              let metric = snapshot.metrics.first(where: { $0.quota != nil }) else { return nil }
        return (pinnedProvider, metric)
    }

    var pinnedHeadline: String? {
        guard let (_, metric) = pinnedMetric, let quota = metric.quota else { return nil }
        return AIUsageFormat.quotaHeadline(quota, showRemaining: showRemaining)
            .replacingOccurrences(of: " left", with: "")
            .replacingOccurrences(of: " used", with: "")
    }

    func detectAndSeedProviders() async {
        let results = await withTaskGroup(of: (AIUsageProviderID, Bool).self) { group in
            for provider in providers.values {
                group.addTask { (provider.id, await provider.detect()) }
            }
            var detected: [(AIUsageProviderID, Bool)] = []
            for await result in group { detected.append(result) }
            return detected
        }
        for (id, present) in results where present {
            detectedProviders.insert(id)
            let key = Keys.providerPrefix + id.rawValue
            if defaults.object(forKey: key) == nil {
                enabledProviders.insert(id)
                defaults.set(true, forKey: key)
            }
        }
    }

    func refreshAll(force: Bool) async {
        let ids = enabledProviders
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.refresh(id, force: force) } }
        }
    }

    func refresh(_ id: AIUsageProviderID, force: Bool) async {
        guard enabledProviders.contains(id), let provider = providers[id], !refreshing.contains(id) else { return }
        if !force, let snapshot = snapshots[id], !isStale(snapshot) { return }
        refreshing.insert(id)
        statuses[id] = .refreshing
        defer { refreshing.remove(id) }
        do {
            let fresh = try await Self.withTimeout(seconds: 120) { try await provider.refresh() }
            let previous = snapshots[id]
            snapshots[id] = fresh
            statuses[id] = .available
            persistCache()
            emitAlertIfNeeded(previous: previous, current: fresh)
        } catch is CancellationError {
            statuses[id] = snapshots[id] == nil ? .idle : .available
        } catch {
            statuses[id] = .unavailable(error.localizedDescription)
        }
    }

    private func emitAlertIfNeeded(previous: AIUsageSnapshot?, current: AIUsageSnapshot) {
        guard usageAlertsEnabled, let previous else { return }
        for metric in current.metrics {
            guard let currentQuota = metric.quota,
                  let oldQuota = previous.metrics.first(where: { $0.id == metric.id })?.quota else { continue }
            let oldRemaining = oldQuota.remainingFraction
            let remaining = currentQuota.remainingFraction
            let resetChanged = oldQuota.resetsAt != nil && currentQuota.resetsAt != nil
                && oldQuota.resetsAt != currentQuota.resetsAt && currentQuota.used < oldQuota.used
            if resetChanged {
                IslandActivityController.shared.present(IslandActivity(
                    title: "\(current.providerID.displayName) reset",
                    detail: "\(metric.title) is available again",
                    symbol: current.providerID.fallbackSymbol,
                    kind: .usage,
                    level: remaining
                ))
                return
            }
            if (oldRemaining > 0.10 && remaining <= 0.10) || (oldRemaining > 0.20 && remaining <= 0.20) {
                IslandActivityController.shared.present(IslandActivity(
                    title: "\(current.providerID.displayName) · \(metric.title)",
                    detail: "\(Int((remaining * 100).rounded()))% remaining",
                    symbol: current.providerID.fallbackSymbol,
                    kind: .usage,
                    level: remaining
                ))
                return
            }
        }
    }

    private func persistCache() {
        let values = Array(snapshots.values)
        let url = cacheURL
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                let data = try encoder.encode(AIUsageCacheDocument(snapshots: values))
                try AIUsageCredentialIO.writePrivate(data, to: url.path)
            } catch {
                // Cache persistence is best-effort; live values remain available in memory.
            }
        }
    }

    private static func loadCache(from url: URL) -> [AIUsageSnapshot]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let document = try? decoder.decode(AIUsageCacheDocument.self, from: data), document.version == 1 else { return nil }
        return document.snapshots
    }

    private struct TimeoutError: Error, LocalizedError {
        var errorDescription: String? { "Usage refresh timed out." }
    }

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimeoutError()
            }
            guard let result = try await group.next() else { throw TimeoutError() }
            group.cancelAll()
            return result
        }
    }
}
