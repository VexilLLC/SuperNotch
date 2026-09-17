import Foundation

enum AIUsageProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude
    case openCode = "opencode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .openCode: "OpenCode"
        }
    }

    var iconName: String { rawValue }
    var fallbackSymbol: String {
        switch self {
        case .codex: "sparkles"
        case .claude: "sun.max.fill"
        case .openCode: "terminal.fill"
        }
    }
}

enum AIUsageUnit: String, Codable, Sendable {
    case percent
    case dollars
    case credits
    case tokens
    case count
}

struct AIUsageQuota: Codable, Equatable, Sendable {
    var used: Double
    var limit: Double
    var unit: AIUsageUnit
    var resetsAt: Date?
    var windowSeconds: Double?

    var usedFraction: Double {
        guard used.isFinite, limit.isFinite, limit > 0 else { return 0 }
        return min(1, max(0, used / limit))
    }

    var remainingFraction: Double { 1 - usedFraction }
}

struct AIUsageValue: Codable, Equatable, Sendable {
    var value: Double
    var unit: AIUsageUnit
    var detail: String?
    var estimated: Bool

    init(value: Double, unit: AIUsageUnit, detail: String? = nil, estimated: Bool = false) {
        self.value = value
        self.unit = unit
        self.detail = detail
        self.estimated = estimated
    }
}

/// One calendar day of locally observed provider usage. Cost is present only
/// when the provider records an authoritative per-message value (OpenCode
/// Go/Zen); token-only providers remain useful without inventing pricing.
struct AIUsageHistoryPoint: Codable, Equatable, Sendable, Identifiable {
    var day: String
    var tokens: Int
    var costUSD: Double?

    var id: String { day }
    var chartValue: Double { Double(tokens) }
}

enum AIUsageMetricPayload: Codable, Equatable, Sendable {
    case quota(AIUsageQuota)
    case value(AIUsageValue)
    case status(String)
}

struct AIUsageMetric: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let payload: AIUsageMetricPayload

    static func quota(
        id: String,
        title: String,
        used: Double,
        limit: Double = 100,
        unit: AIUsageUnit = .percent,
        resetsAt: Date? = nil,
        windowSeconds: Double? = nil
    ) -> AIUsageMetric {
        AIUsageMetric(
            id: id,
            title: title,
            payload: .quota(AIUsageQuota(
                used: max(0, used),
                limit: max(0, limit),
                unit: unit,
                resetsAt: resetsAt,
                windowSeconds: windowSeconds
            ))
        )
    }

    static func value(
        id: String,
        title: String,
        value: Double,
        unit: AIUsageUnit,
        detail: String? = nil,
        estimated: Bool = false
    ) -> AIUsageMetric {
        AIUsageMetric(
            id: id,
            title: title,
            payload: .value(AIUsageValue(value: value, unit: unit, detail: detail, estimated: estimated))
        )
    }

    static func status(id: String, title: String, text: String) -> AIUsageMetric {
        AIUsageMetric(id: id, title: title, payload: .status(text))
    }

    var quota: AIUsageQuota? {
        guard case .quota(let quota) = payload else { return nil }
        return quota
    }
}

struct AIUsageSnapshot: Codable, Equatable, Sendable, Identifiable {
    let providerID: AIUsageProviderID
    var plan: String?
    var metrics: [AIUsageMetric]
    var fetchedAt: Date
    var warning: String?
    var history: [AIUsageHistoryPoint]?

    init(
        providerID: AIUsageProviderID,
        plan: String?,
        metrics: [AIUsageMetric],
        fetchedAt: Date,
        warning: String?,
        history: [AIUsageHistoryPoint]? = nil
    ) {
        self.providerID = providerID
        self.plan = plan
        self.metrics = metrics
        self.fetchedAt = fetchedAt
        self.warning = warning
        self.history = history
    }

    var id: AIUsageProviderID { providerID }
}

enum AIUsageProviderStatus: Equatable, Sendable {
    case idle
    case refreshing
    case available
    case unavailable(String)

    var errorText: String? {
        guard case .unavailable(let text) = self else { return nil }
        return text
    }
}

enum AIUsageSeverity: Int, Comparable, Sendable {
    case healthy = 0
    case warning = 1
    case critical = 2
    case unavailable = 3

    static func < (lhs: AIUsageSeverity, rhs: AIUsageSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct AIUsagePaceProjection: Equatable, Sendable {
    enum Status: Sendable { case ahead, close, over }
    var status: Status
    var projectedUsedFraction: Double
    var elapsedFraction: Double

    var label: String {
        let remaining = 1 - projectedUsedFraction
        if remaining >= 0 {
            return "~\(Int((remaining * 100).rounded()))% left at reset"
        }
        return "~\(max(1, Int((-remaining * 100).rounded())))% over at reset"
    }

    func markerFraction(showRemaining: Bool) -> Double {
        showRemaining ? 1 - elapsedFraction : elapsedFraction
    }
}

struct AIUsageAttentionItem: Identifiable, Sendable {
    let providerID: AIUsageProviderID
    let metric: AIUsageMetric
    let severity: AIUsageSeverity

    var id: String { "\(providerID.rawValue).\(metric.id)" }
}

enum AIUsageFormat {
    static func compactNumber(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = abs(value) < 10 ? 1 : 0
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? "—"
    }

    static func value(_ value: AIUsageValue) -> String {
        switch value.unit {
        case .dollars:
            return value.value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        case .tokens:
            return "\(compactCount(value.value)) tokens"
        case .credits:
            return "\(compactNumber(value.value)) credits"
        case .percent:
            return "\(Int(value.value.rounded()))%"
        case .count:
            return compactNumber(value.value)
        }
    }

    static func compactCount(_ value: Double) -> String {
        let amount = abs(value)
        if amount >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if amount >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if amount >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return compactNumber(value)
    }

    static func historyReadout(_ point: AIUsageHistoryPoint) -> String {
        return "\(compactCount(Double(point.tokens))) tokens"
    }

    static func quotaHeadline(_ quota: AIUsageQuota, showRemaining: Bool) -> String {
        let fraction = showRemaining ? quota.remainingFraction : quota.usedFraction
        let amount = fraction * quota.limit
        switch quota.unit {
        case .percent:
            return "\(Int((fraction * 100).rounded()))% \(showRemaining ? "left" : "used")"
        case .dollars:
            return amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        case .credits:
            return "\(compactNumber(amount)) credits"
        case .tokens:
            return "\(compactCount(amount)) tokens"
        case .count:
            return compactNumber(amount)
        }
    }

    static func resetText(_ date: Date?, exact: Bool, now: Date = Date()) -> String {
        guard let date else { return "No reset time" }
        if exact {
            return "Resets " + date.formatted(date: .abbreviated, time: .shortened)
        }
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 60 { return "Resets soon" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Resets in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "Resets in \(hours)h \(minutes % 60)m" }
        return "Resets in \(hours / 24)d \(hours % 24)h"
    }

    static func pace(for quota: AIUsageQuota, now: Date = Date()) -> AIUsagePaceProjection? {
        guard quota.limit > 0, quota.used > 0,
              let resetsAt = quota.resetsAt,
              let duration = quota.windowSeconds, duration > 0,
              now < resetsAt else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(windowStart)
        let minimumElapsed = max(60, duration * 0.01)
        guard elapsed >= minimumElapsed else { return nil }
        let usedFraction = quota.usedFraction
        // Whole-percent APIs are too coarse to extrapolate honestly in the
        // first 5% of a window; match OpenUsage's false-alarm guard.
        guard usedFraction >= 0.05 else { return nil }
        let elapsedFraction = min(1, max(0, elapsed / duration))
        guard elapsedFraction > 0 else { return nil }
        let projected = usedFraction / elapsedFraction
        let status: AIUsagePaceProjection.Status
        if projected <= 0.9 { status = .ahead }
        else if projected <= 1 { status = .close }
        else { status = .over }
        return AIUsagePaceProjection(status: status, projectedUsedFraction: projected, elapsedFraction: elapsedFraction)
    }

    static func severity(for quota: AIUsageQuota, now: Date = Date()) -> AIUsageSeverity {
        if let pace = pace(for: quota, now: now) {
            switch pace.status {
            case .ahead: return .healthy
            case .close: return .warning
            case .over: return .critical
            }
        }
        if quota.remainingFraction <= 0.10 { return .critical }
        if quota.remainingFraction <= 0.20 { return .warning }
        return .healthy
    }
}

enum AIUsageMappingError: Error, LocalizedError, Equatable {
    case invalidResponse
    case requestFailed(Int)
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Provider returned an invalid usage response."
        case .requestFailed(let status): "Usage request failed (HTTP \(status))."
        case .notConnected(let message): message
        }
    }
}

enum AIUsageMapping {
    static func codex(data: Data, headers: [String: String] = [:], now: Date = Date()) throws -> (String?, [AIUsageMetric]) {
        guard let body = jsonObject(data) else { throw AIUsageMappingError.invalidResponse }
        var metrics: [AIUsageMetric] = []
        let rateLimit = body["rate_limit"] as? [String: Any]
        let candidates: [(String, String, [String: Any]?, Double?, Double)] = [
            ("session", "Session", rateLimit?["primary_window"] as? [String: Any], number(headers["x-codex-primary-used-percent"]), 18_000),
            ("weekly", "Weekly", rateLimit?["secondary_window"] as? [String: Any], number(headers["x-codex-secondary-used-percent"]), 604_800)
        ]
        for (index, candidate) in candidates.enumerated() {
            let window = candidate.2
            guard let used = number(window?["used_percent"]) ?? candidate.3 else { continue }
            let reportedDuration = number(window?["limit_window_seconds"])
            let duration = reportedDuration ?? candidate.4
            let isWeekly = abs(duration - 604_800) < 3_600
            let id = isWeekly ? "weekly" : (index == 0 ? "session" : candidate.0)
            let title = isWeekly ? "Weekly" : (index == 0 ? "Session" : candidate.1)
            if metrics.contains(where: { $0.id == id }) { continue }
            metrics.append(.quota(
                id: id,
                title: title,
                used: clampPercent(used),
                resetsAt: resetDate(window, now: now),
                windowSeconds: duration
            ))
        }
        if let balance = number((body["credits"] as? [String: Any])?["balance"]) {
            metrics.append(.value(id: "credits", title: "Credits", value: balance, unit: .credits))
        }
        guard !metrics.isEmpty else { throw AIUsageMappingError.invalidResponse }
        return (codexPlan(body["plan_type"] as? String), metrics)
    }

    static func claude(data: Data, subscriptionType: String?, rateLimitTier: String?) throws -> (String?, [AIUsageMetric]) {
        guard let body = jsonObject(data) else { throw AIUsageMappingError.invalidResponse }
        var metrics: [AIUsageMetric] = []
        appendClaudeWindow(body["five_hour"], id: "session", title: "Session", window: 18_000, to: &metrics)
        appendClaudeWindow(body["seven_day"], id: "weekly", title: "Weekly", window: 604_800, to: &metrics)
        appendClaudeWindow(body["seven_day_sonnet"], id: "sonnet", title: "Sonnet", window: 604_800, to: &metrics)
        if let limits = body["limits"] as? [Any] {
            for raw in limits {
                guard let entry = raw as? [String: Any], entry["kind"] as? String == "weekly_scoped",
                      let scope = entry["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String,
                      let used = number(entry["percent"]) else { continue }
                metrics.append(.quota(
                    id: "model-\(name.lowercased())",
                    title: name,
                    used: clampPercent(used),
                    resetsAt: date(entry["resets_at"]),
                    windowSeconds: 604_800
                ))
            }
        }
        if let extra = body["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let cents = number(extra["used_credits"]) {
            let used = cents / 100
            if let limitCents = number(extra["monthly_limit"]), limitCents > 0 {
                metrics.append(.quota(id: "extra", title: "Extra usage", used: used, limit: limitCents / 100, unit: .dollars))
            } else if used > 0 {
                metrics.append(.value(id: "extra", title: "Extra usage", value: used, unit: .dollars))
            }
        }
        guard !metrics.isEmpty else { throw AIUsageMappingError.invalidResponse }
        return (claudePlan(subscriptionType, rateLimitTier), metrics)
    }

    static func openCode(data: Data) throws -> [AIUsageMetric] {
        guard let body = jsonObject(data), let usage = body["usage"] as? [String: Any] else {
            throw AIUsageMappingError.invalidResponse
        }
        let definitions: [(String, String, String, Double)] = [
            ("rolling", "session", "Session", 18_000),
            ("weekly", "weekly", "Weekly", 604_800),
            ("monthly", "monthly", "Monthly", 2_592_000)
        ]
        return try definitions.map { key, id, title, duration in
            guard let value = usage[key] as? [String: Any], let percent = number(value["percent"]) else {
                throw AIUsageMappingError.invalidResponse
            }
            return .quota(
                id: id,
                title: title,
                used: clampPercent(percent),
                resetsAt: date(value["resetsAt"]),
                windowSeconds: duration
            )
        }
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let number = number(value), number.isFinite {
            return Date(timeIntervalSince1970: abs(number) > 10_000_000_000 ? number / 1_000 : number)
        }
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter.aiUsage.date(from: text)
            ?? ISO8601DateFormatter.aiUsageBasic.date(from: text)
    }

    private static func resetDate(_ window: [String: Any]?, now: Date) -> Date? {
        if let direct = date(window?["reset_at"]) { return direct }
        if let seconds = number(window?["reset_after_seconds"]) { return now.addingTimeInterval(seconds) }
        return nil
    }

    private static func appendClaudeWindow(_ raw: Any?, id: String, title: String, window: Double, to metrics: inout [AIUsageMetric]) {
        guard let object = raw as? [String: Any], let used = number(object["utilization"]) else { return }
        metrics.append(.quota(
            id: id,
            title: title,
            used: clampPercent(used),
            resetsAt: date(object["resets_at"]),
            windowSeconds: window
        ))
    }

    private static func clampPercent(_ value: Double) -> Double { min(100, max(0, value)) }

    private static func codexPlan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        case "self_serve_business_prolite": return "Business Premium"
        default:
            return raw.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }

    private static func claudePlan(_ subscription: String?, _ tier: String?) -> String? {
        guard let subscription, !subscription.isEmpty else { return nil }
        var result = subscription.capitalized
        if let tier, let match = tier.range(of: #"\d+x"#, options: .regularExpression) {
            result += " \(tier[match])"
        }
        return result
    }
}

extension ISO8601DateFormatter {
    static let aiUsage: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let aiUsageBasic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
