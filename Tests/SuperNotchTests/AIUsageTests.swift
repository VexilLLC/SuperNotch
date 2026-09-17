import XCTest
@testable import SuperNotch

final class AIUsageTests: XCTestCase {
    func testClaudeKeychainAccessIsExplicitOptIn() throws {
        let suiteName = "SuperNotchTests.ClaudeKeychain.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(ClaudeKeychainAccess.isEnabled(in: defaults))
        defaults.set(true, forKey: ClaudeKeychainAccess.defaultsKey)
        XCTAssertTrue(ClaudeKeychainAccess.isEnabled(in: defaults))
        defaults.set(false, forKey: ClaudeKeychainAccess.defaultsKey)
        XCTAssertFalse(ClaudeKeychainAccess.isEnabled(in: defaults))
    }

    func testCodexMapsQuotaCreditsPlanAndRelativeReset() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data(#"""
        {
          "plan_type": "prolite",
          "rate_limit": {
            "primary_window": {
              "used_percent": 42.5,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 120
            },
            "secondary_window": {
              "used_percent": 81,
              "limit_window_seconds": 604800,
              "reset_at": 1800003600
            }
          },
          "credits": { "balance": "17.25" }
        }
        """#.utf8)

        let result = try AIUsageMapping.codex(data: data, now: now)
        XCTAssertEqual(result.0, "Pro 5x")
        XCTAssertEqual(result.1.map(\.id), ["session", "weekly", "credits"])
        XCTAssertEqual(result.1[0].quota?.used, 42.5)
        XCTAssertEqual(result.1[0].quota?.resetsAt, now.addingTimeInterval(120))
        XCTAssertEqual(result.1[1].quota?.resetsAt, Date(timeIntervalSince1970: 1_800_003_600))
        guard case .value(let credits) = result.1[2].payload else { return XCTFail("Expected credits") }
        XCTAssertEqual(credits.value, 17.25)
        XCTAssertEqual(credits.unit, .credits)
    }

    func testClaudeMapsSubscriptionWindowsModelAndExtraUsage() throws {
        let data = Data(#"""
        {
          "five_hour": { "utilization": 12, "resets_at": "2026-09-16T04:00:00Z" },
          "seven_day": { "utilization": 67.5, "resets_at": "2026-09-20T12:00:00.250Z" },
          "limits": [{
            "kind": "weekly_scoped",
            "percent": 88,
            "resets_at": "2026-09-21T00:00:00Z",
            "scope": { "model": { "display_name": "Opus" } }
          }],
          "extra_usage": { "is_enabled": true, "used_credits": 1234, "monthly_limit": 5000 }
        }
        """#.utf8)

        let result = try AIUsageMapping.claude(data: data, subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
        XCTAssertEqual(result.0, "Max 20x")
        XCTAssertEqual(result.1.map(\.id), ["session", "weekly", "model-opus", "extra"])
        XCTAssertNotNil(result.1[0].quota?.resetsAt, "Non-fractional ISO dates should parse")
        XCTAssertNotNil(result.1[1].quota?.resetsAt, "Fractional ISO dates should parse")
        XCTAssertEqual(result.1[2].quota?.used, 88)
        XCTAssertEqual(result.1[3].quota?.used, 12.34)
        XCTAssertEqual(result.1[3].quota?.limit, 50)
        XCTAssertEqual(result.1[3].quota?.unit, .dollars)
    }

    func testOpenCodeMapsAllGoWindowsAndClampsPercentages() throws {
        let data = Data(#"""
        {
          "usage": {
            "rolling": { "percent": -2, "resetsAt": "2026-09-16T03:00:00Z" },
            "weekly": { "percent": 45, "resetsAt": 1800000000000 },
            "monthly": { "percent": 130, "resetsAt": "2026-10-01T00:00:00Z" }
          }
        }
        """#.utf8)

        let metrics = try AIUsageMapping.openCode(data: data)
        XCTAssertEqual(metrics.map(\.id), ["session", "weekly", "monthly"])
        XCTAssertEqual(metrics.compactMap(\.quota).map(\.used), [0, 45, 100])
        XCTAssertEqual(metrics[1].quota?.resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testSeverityAndRemainingFormattingUseRemainingQuota() {
        let healthy = AIUsageQuota(used: 70, limit: 100, unit: .percent, resetsAt: nil, windowSeconds: nil)
        let warning = AIUsageQuota(used: 80, limit: 100, unit: .percent, resetsAt: nil, windowSeconds: nil)
        let critical = AIUsageQuota(used: 91, limit: 100, unit: .percent, resetsAt: nil, windowSeconds: nil)

        XCTAssertEqual(AIUsageFormat.severity(for: healthy), .healthy)
        XCTAssertEqual(AIUsageFormat.severity(for: warning), .warning)
        XCTAssertEqual(AIUsageFormat.severity(for: critical), .critical)
        XCTAssertEqual(AIUsageFormat.quotaHeadline(critical, showRemaining: true), "9% left")
        XCTAssertEqual(AIUsageFormat.quotaHeadline(critical, showRemaining: false), "91% used")
    }

    func testLocalHistorySummariesPreferMeasuredCostAndRetainTokenDetail() {
        let now = ISO8601DateFormatter.aiUsageBasic.date(from: "2026-09-16T12:00:00Z")!
        let history = [
            AIUsageHistoryPoint(day: "2026-09-15", tokens: 1_000, costUSD: 1.25),
            AIUsageHistoryPoint(day: "2026-09-16", tokens: 2_500, costUSD: 2.75)
        ]

        let metrics = AIUsageLocalHistory.summarize(history, now: now)
        XCTAssertEqual(metrics.map(\.id), ["today", "yesterday", "last30"])
        guard case .value(let today) = metrics[0].payload,
              case .value(let total) = metrics[2].payload else { return XCTFail("Expected value summaries") }
        XCTAssertEqual(today.value, 2.75)
        XCTAssertEqual(today.unit, .dollars)
        XCTAssertEqual(today.detail, "2.5K tokens")
        XCTAssertEqual(total.value, 4)
        XCTAssertEqual(total.detail, "3.5K tokens")
    }

    func testHistoryRoundTripsWithSnapshotCacheShape() throws {
        let snapshot = AIUsageSnapshot(
            providerID: .openCode,
            plan: "Go",
            metrics: [],
            fetchedAt: Date(timeIntervalSince1970: 123),
            warning: nil,
            history: [AIUsageHistoryPoint(day: "2026-09-16", tokens: 42, costUSD: 0.12)]
        )
        let decoded = try JSONDecoder().decode(AIUsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.history?.first?.tokens, 42)
    }

    func testPaceProjectionLabelsMarkerAndSeverity() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let reset = now.addingTimeInterval(500)
        let ahead = AIUsageQuota(used: 40, limit: 100, unit: .percent, resetsAt: reset, windowSeconds: 1_000)
        let close = AIUsageQuota(used: 46, limit: 100, unit: .percent, resetsAt: reset, windowSeconds: 1_000)
        let over = AIUsageQuota(used: 60, limit: 100, unit: .percent, resetsAt: reset, windowSeconds: 1_000)

        let projection = try XCTUnwrap(AIUsageFormat.pace(for: ahead, now: now))
        XCTAssertEqual(projection.label, "~20% left at reset")
        XCTAssertEqual(projection.markerFraction(showRemaining: true), 0.5, accuracy: 0.0001)
        XCTAssertEqual(projection.markerFraction(showRemaining: false), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AIUsageFormat.severity(for: ahead, now: now), .healthy)
        XCTAssertEqual(AIUsageFormat.severity(for: close, now: now), .warning)
        XCTAssertEqual(AIUsageFormat.severity(for: over, now: now), .critical)
        XCTAssertEqual(AIUsageFormat.pace(for: over, now: now)?.label, "~20% over at reset")
    }
}
