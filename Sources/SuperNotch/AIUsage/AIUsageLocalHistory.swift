import Foundation

/// Bounded, read-only local usage scanners inspired by OpenUsage's normalized
/// daily history. They keep prompts and model output out of memory: only the
/// timestamp, token counters, stable message identifiers, and recorded cost
/// fields cross the parsing boundary.
enum AIUsageLocalHistory {
    static let daysBack = 30
    private static let maximumFileBytes: Int64 = 64 * 1_024 * 1_024
    private static let maximumLineBytes = 1_024 * 1_024
    private static let memoryCache = AIUsageHistoryMemoryCache()

    static func codex() async -> [AIUsageHistoryPoint] {
        if let cached = await memoryCache.value(for: "codex") { return cached }
        let result = await Task.detached(priority: .utility) { scanCodex() }.value
        await memoryCache.store(result, for: "codex")
        return result
    }

    static func claude() async -> [AIUsageHistoryPoint] {
        if let cached = await memoryCache.value(for: "claude") { return cached }
        let result = await Task.detached(priority: .utility) { scanClaude() }.value
        await memoryCache.store(result, for: "claude")
        return result
    }

    static func openCode(databasePaths: [String]) async -> [AIUsageHistoryPoint] {
        if let cached = await memoryCache.value(for: "opencode") { return cached }
        let result = await Task.detached(priority: .utility) { scanOpenCode(databasePaths: databasePaths) }.value
        await memoryCache.store(result, for: "opencode")
        return result
    }

    static func summarize(_ history: [AIUsageHistoryPoint], now: Date = Date()) -> [AIUsageMetric] {
        guard !history.isEmpty else { return [] }
        let today = dayKey(now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now).map(dayKey) ?? ""
        let ordered: [(String, String, [AIUsageHistoryPoint])] = [
            ("today", "Today", history.filter { $0.day == today }),
            ("yesterday", "Yesterday", history.filter { $0.day == yesterday }),
            ("last30", "Last 30 days", history)
        ]
        return ordered.compactMap { id, title, points in
            guard !points.isEmpty else { return nil }
            let tokens = points.reduce(0) { $0 + max(0, $1.tokens) }
            let costs = points.compactMap(\.costUSD)
            if !costs.isEmpty {
                return .value(
                    id: id,
                    title: title,
                    value: costs.reduce(0, +),
                    unit: .dollars,
                    detail: "\(AIUsageFormat.compactCount(Double(tokens))) tokens"
                )
            }
            return .value(id: id, title: title, value: Double(tokens), unit: .tokens)
        }
    }

    // MARK: - Codex

    private static func scanCodex() -> [AIUsageHistoryPoint] {
        let root = environmentPath("CODEX_HOME") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let sessionRoot = URL(fileURLWithPath: root).appendingPathComponent("sessions").path
        var totals: [String: Int] = [:]
        for path in recentJSONLFiles(at: sessionRoot) {
            var previous: TokenCounts?
            scanLines(path, requiredMarker: Data(#""type":"token_count""#.utf8)) { object in
                guard object["type"] as? String == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let rawDate = object["timestamp"] as? String,
                      let date = AIUsageMapping.date(rawDate),
                      date >= cutoffDate(),
                      let info = payload["info"] as? [String: Any] else { return }

                let cumulative = (info["total_token_usage"] as? [String: Any]).map(TokenCounts.init)
                if let cumulative, cumulative == previous { return }
                let delta: TokenCounts
                if let last = info["last_token_usage"] as? [String: Any] {
                    delta = TokenCounts(last)
                } else if let cumulative {
                    delta = cumulative.subtracting(previous)
                } else {
                    return
                }
                if let cumulative { previous = cumulative }
                let tokens = max(0, delta.total)
                guard tokens > 0 else { return }
                totals[dayKey(date), default: 0] += tokens
            }
        }
        return points(tokens: totals)
    }

    private struct TokenCounts: Equatable {
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int

        init(_ object: [String: Any]) {
            input = integer(object["input_tokens"])
            cached = integer(object["cached_input_tokens"])
            output = integer(object["output_tokens"])
            reasoning = integer(object["reasoning_output_tokens"])
            total = integer(object["total_tokens"])
            if total <= 0 { total = max(0, input + output) }
        }

        func subtracting(_ other: TokenCounts?) -> TokenCounts {
            guard let other else { return self }
            return TokenCounts(
                input: max(0, input - other.input),
                cached: max(0, cached - other.cached),
                output: max(0, output - other.output),
                reasoning: max(0, reasoning - other.reasoning),
                total: max(0, total - other.total)
            )
        }

        private init(input: Int, cached: Int, output: Int, reasoning: Int, total: Int) {
            self.input = input; self.cached = cached; self.output = output
            self.reasoning = reasoning; self.total = total
        }
    }

    // MARK: - Claude

    private static func scanClaude() -> [AIUsageHistoryPoint] {
        let root = environmentPath("CLAUDE_CONFIG_DIR") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let projects = URL(fileURLWithPath: root).appendingPathComponent("projects").path
        var entries: [String: (day: String, tokens: Int)] = [:]
        var anonymous: [(String, Int)] = []
        for path in recentJSONLFiles(at: projects) {
            scanLines(path, requiredMarker: Data(#""usage":"#.utf8)) { object in
                guard let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let rawDate = object["timestamp"] as? String,
                      let date = AIUsageMapping.date(rawDate), date >= cutoffDate() else { return }
                let tokens = integer(usage["input_tokens"])
                    + integer(usage["output_tokens"])
                    + integer(usage["cache_creation_input_tokens"])
                    + integer(usage["cache_read_input_tokens"])
                guard tokens > 0 else { return }
                let value = (dayKey(date), tokens)
                if let messageID = message["id"] as? String, !messageID.isEmpty {
                    entries[messageID] = value
                } else {
                    anonymous.append(value)
                }
            }
        }
        var totals: [String: Int] = [:]
        for value in entries.values { totals[value.day, default: 0] += value.tokens }
        for value in anonymous { totals[value.0, default: 0] += value.1 }
        return points(tokens: totals)
    }

    // MARK: - OpenCode

    private static func scanOpenCode(databasePaths: [String]) -> [AIUsageHistoryPoint] {
        let cutoff = Int(cutoffDate().timeIntervalSince1970 * 1_000)
        let sql = """
        SELECT strftime('%Y-%m-%d', time_created / 1000, 'unixepoch', 'localtime'),
               COALESCE(SUM(json_extract(data,'$.cost')),0),
               COALESCE(SUM(json_extract(data,'$.tokens.total')),0)
        FROM message
        WHERE time_created >= \(cutoff)
          AND json_valid(data)
          AND json_extract(data,'$.role') = 'assistant'
          AND json_extract(data,'$.providerID') IN ('opencode-go','opencode')
          AND json_type(data,'$.cost') IN ('integer','real')
        GROUP BY 1 ORDER BY 1;
        """
        var values: [String: (tokens: Int, cost: Double)] = [:]
        for path in databasePaths {
            guard let text = sqlite(path: path, sql: sql) else { continue }
            for line in text.split(separator: "\n") {
                let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                guard fields.count >= 3, !fields[0].isEmpty,
                      let cost = Double(fields[1]), let tokens = Double(fields[2]) else { continue }
                let day = String(fields[0])
                values[day, default: (0, 0)].tokens += Int(max(0, min(tokens, Double(Int.max))))
                values[day, default: (0, 0)].cost += max(0, cost)
            }
        }
        return values.keys.sorted().map { day in
            AIUsageHistoryPoint(day: day, tokens: values[day]?.tokens ?? 0, costUSD: values[day]?.cost)
        }
    }

    // MARK: - Bounded I/O

    private static func recentJSONLFiles(at root: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let cutoff = cutoffDate()
        return enumerator.compactMap { value -> String? in
            guard let url = value as? URL, url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  Int64(values.fileSize ?? 0) <= maximumFileBytes,
                  (values.contentModificationDate ?? .distantPast) >= cutoff else { return nil }
            return url.path
        }
    }

    private static func scanLines(_ path: String, requiredMarker: Data, consume: ([String: Any]) -> Void) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 64 * 1_024)
            guard let chunk, !chunk.isEmpty else { return false }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard line.count <= maximumLineBytes,
                      line.range(of: requiredMarker) != nil,
                      let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                consume(object)
            }
            if buffer.count > maximumLineBytes { buffer.removeAll(keepingCapacity: true) }
            return true
        }) {}
    }

    private static func points(tokens: [String: Int]) -> [AIUsageHistoryPoint] {
        tokens.keys.sorted().map { AIUsageHistoryPoint(day: $0, tokens: tokens[$0] ?? 0, costUSD: nil) }
    }

    private static func cutoffDate(now: Date = Date()) -> Date {
        let start = Calendar.current.startOfDay(for: now)
        return Calendar.current.date(byAdding: .day, value: -daysBack, to: start) ?? start
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func environmentPath(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : AIUsageCredentialIO.expanded($0) }
    }

    private static func integer(_ value: Any?) -> Int {
        let number = AIUsageMapping.number(value) ?? 0
        return Int(max(0, min(number, Double(Int.max))))
    }

    private static func sqlite(path: String, sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-noheader", "-readonly", path, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

private actor AIUsageHistoryMemoryCache {
    private struct Entry { var storedAt: Date; var points: [AIUsageHistoryPoint] }
    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval = 30 * 60

    func value(for provider: String, now: Date = Date()) -> [AIUsageHistoryPoint]? {
        guard let entry = entries[provider], now.timeIntervalSince(entry.storedAt) < lifetime else { return nil }
        return entry.points
    }

    func store(_ points: [AIUsageHistoryPoint], for provider: String, now: Date = Date()) {
        entries[provider] = Entry(storedAt: now, points: points)
    }
}
