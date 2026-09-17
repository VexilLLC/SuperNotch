import Foundation
import Security
import LocalAuthentication
import Darwin

protocol AIUsageProvider: Sendable {
    var id: AIUsageProviderID { get }
    func detect() async -> Bool
    func refresh() async throws -> AIUsageSnapshot
}

struct AIUsageHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data
}

enum AIUsageHTTP {
    static func formBody(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?")
        let encoded = values
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    static func send(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 15
    ) async throws -> AIUsageHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIUsageMappingError.invalidResponse }
        var normalized: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            normalized[String(describing: key).lowercased()] = String(describing: value)
        }
        return AIUsageHTTPResponse(statusCode: http.statusCode, headers: normalized, data: data)
    }
}

enum AIUsageCredentialIO {
    static func expanded(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func readJSONObject(at path: String) throws -> [String: Any]? {
        let expanded = expanded(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        return try decodeObject(data)
    }

    static func decodeObject(_ data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count.isMultiple(of: 2), text.allSatisfy({ $0.isHexDigit }) else {
            throw AIUsageMappingError.invalidResponse
        }
        var decoded = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw AIUsageMappingError.invalidResponse }
            decoded.append(byte)
            index = next
        }
        guard let object = try JSONSerialization.jsonObject(with: decoded) as? [String: Any] else {
            throw AIUsageMappingError.invalidResponse
        }
        return object
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    static func writePrivate(_ data: Data, to path: String) throws {
        let expanded = expanded(path)
        let destination = URL(fileURLWithPath: expanded)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let mode = mode_t(S_IRUSR | S_IWUSR)
        let fd = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode) }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var open = true
        var exists = true
        defer {
            if open { _ = Darwin.close(fd) }
            if exists { temporary.path.withCString { _ = Darwin.unlink($0) } }
        }
        guard Darwin.fchmod(fd, mode) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += result
            }
        }
        guard Darwin.fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard Darwin.close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        open = false
        let renamed = temporary.path.withCString { source in expanded.withCString { target in Darwin.rename(source, target) } }
        guard renamed == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        exists = false
    }

    static func keychainObject(service: String, allowInteraction: Bool) throws -> [String: Any]? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if allowInteraction {
            query[kSecReturnData as String] = true
        } else {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecReturnAttributes as String] = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        guard allowInteraction else { return [:] }
        guard let data = item as? Data else { throw AIUsageMappingError.invalidResponse }
        return try decodeObject(data)
    }

    static func updateKeychain(service: String, object: [String: Any]) throws {
        let data = try encode(object)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func keychainString(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func setKeychainString(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(update))
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
    }

    static func deleteKeychainItem(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while !base64.count.isMultiple(of: 4) { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let epoch = AIUsageMapping.number(payload["exp"]) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }
}

/// Access to another app's Keychain item must be an explicit user choice.
/// Merely detecting or refreshing providers at launch must never display a
/// macOS Keychain authorization dialog.
enum ClaudeKeychainAccess {
    static let defaultsKey = "aiUsage.claudeKeychainAccess"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }
}

enum OpenCodeGoKeySource: String, Sendable {
    case missing
    case openCode = "OpenCode login"
    case custom = "Custom key"
}

/// A SuperNotch-owned override for the OpenCode Go bearer key. The companion
/// CLI login remains the fallback, exactly like OpenUsage's config-over-env
/// API-key precedence, while the custom value itself stays in Keychain.
struct OpenCodeGoAPIKeyStore: Sendable {
    static let service = "org.supernotch.app.aiusage.opencode-go"
    static let account = "api-key"

    static var dataDirectory: String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["OPENCODE_DATA_DIR"], !path.isEmpty { return AIUsageCredentialIO.expanded(path) }
        if let path = environment["XDG_DATA_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("opencode").path
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode").path
    }

    static var authPath: String { URL(fileURLWithPath: dataDirectory).appendingPathComponent("auth.json").path }

    func customKey() throws -> String? {
        try AIUsageCredentialIO.keychainString(service: Self.service, account: Self.account)
    }

    func openCodeKey() throws -> String? {
        guard let object = try AIUsageCredentialIO.readJSONObject(at: Self.authPath),
              let entry = object["opencode-go"] as? [String: Any],
              let raw = entry["key"] as? String else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    func effectiveKey() throws -> String? { try customKey() ?? openCodeKey() }

    func source() -> OpenCodeGoKeySource {
        if (try? customKey()) != nil { return .custom }
        if (try? openCodeKey()) != nil { return .openCode }
        return .missing
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIUsageMappingError.notConnected("Enter an OpenCode Go API key.") }
        try AIUsageCredentialIO.setKeychainString(trimmed, service: Self.service, account: Self.account)
    }

    func deleteCustomKey() throws {
        try AIUsageCredentialIO.deleteKeychainItem(service: Self.service, account: Self.account)
    }
}

struct CodexUsageProvider: AIUsageProvider {
    let id = AIUsageProviderID.codex
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private var authPaths: [String] {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return [URL(fileURLWithPath: home).appendingPathComponent("auth.json").path]
        }
        return ["~/.codex/auth.json", "~/.config/codex/auth.json"]
    }

    func detect() async -> Bool {
        await Task.detached(priority: .utility) {
            authPaths.contains { path in
                guard let object = try? AIUsageCredentialIO.readJSONObject(at: path),
                      let tokens = object["tokens"] as? [String: Any],
                      let access = tokens["access_token"] as? String else { return false }
                return !access.isEmpty
            }
        }.value
    }

    func refresh() async throws -> AIUsageSnapshot {
        var loaded = try await loadAuth()
        var accessToken = try token("access_token", from: loaded.object)
        if let expiry = AIUsageCredentialIO.jwtExpiry(accessToken), expiry.timeIntervalSinceNow <= 300 {
            loaded = try await rotate(loaded)
            accessToken = try token("access_token", from: loaded.object)
        }
        var response = try await usage(accessToken: accessToken, object: loaded.object)
        if [401, 403].contains(response.statusCode), refreshToken(in: loaded.object) != nil {
            loaded = try await rotate(loaded)
            accessToken = try token("access_token", from: loaded.object)
            response = try await usage(accessToken: accessToken, object: loaded.object)
        }
        guard (200..<300).contains(response.statusCode) else { throw AIUsageMappingError.requestFailed(response.statusCode) }
        let mapped = try AIUsageMapping.codex(data: response.data, headers: response.headers)
        let history = await AIUsageLocalHistory.codex()
        return AIUsageSnapshot(
            providerID: id,
            plan: mapped.0,
            metrics: mapped.1 + AIUsageLocalHistory.summarize(history),
            fetchedAt: Date(),
            warning: nil,
            history: history.isEmpty ? nil : history
        )
    }

    private func loadAuth() async throws -> (path: String, object: [String: Any]) {
        try await Task.detached(priority: .utility) {
            for path in authPaths {
                if let object = try AIUsageCredentialIO.readJSONObject(at: path),
                   let tokens = object["tokens"] as? [String: Any],
                   let access = tokens["access_token"] as? String, !access.isEmpty {
                    return (path, object)
                }
            }
            throw AIUsageMappingError.notConnected("Run `codex` and sign in to connect Codex.")
        }.value
    }

    private func usage(accessToken: String, object: [String: Any]) async throws -> AIUsageHTTPResponse {
        var headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json", "User-Agent": "SuperNotch"]
        if let account = (object["tokens"] as? [String: Any])?["account_id"] as? String, !account.isEmpty {
            headers["ChatGPT-Account-Id"] = account
        }
        return try await AIUsageHTTP.send(Self.usageURL, headers: headers, timeout: 15)
    }

    private func rotate(_ loaded: (path: String, object: [String: Any])) async throws -> (path: String, object: [String: Any]) {
        guard let refresh = refreshToken(in: loaded.object) else {
            throw AIUsageMappingError.notConnected("Codex session expired. Run `codex` and sign in again.")
        }
        let response = try await AIUsageHTTP.send(
            Self.refreshURL,
            method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: AIUsageHTTP.formBody([
                "grant_type": "refresh_token",
                "client_id": Self.clientID,
                "refresh_token": refresh
            ]),
            timeout: 20
        )
        guard (200..<300).contains(response.statusCode), let values = AIUsageMapping.jsonObject(response.data),
              let access = values["access_token"] as? String, !access.isEmpty else {
            throw AIUsageMappingError.notConnected("Codex session expired. Run `codex` and sign in again.")
        }
        var object = loaded.object
        var tokens = object["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = access
        if let value = values["refresh_token"] as? String { tokens["refresh_token"] = value }
        if let value = values["id_token"] as? String { tokens["id_token"] = value }
        object["tokens"] = tokens
        object["last_refresh"] = ISO8601DateFormatter.aiUsage.string(from: Date())
        try await Task.detached(priority: .utility) {
            try AIUsageCredentialIO.writePrivate(AIUsageCredentialIO.encode(object), to: loaded.path)
        }.value
        return (loaded.path, object)
    }

    private func token(_ key: String, from object: [String: Any]) throws -> String {
        guard let value = (object["tokens"] as? [String: Any])?[key] as? String, !value.isEmpty else {
            throw AIUsageMappingError.notConnected("Run `codex` and sign in to connect Codex.")
        }
        return value
    }

    private func refreshToken(in object: [String: Any]) -> String? {
        (object["tokens"] as? [String: Any])?["refresh_token"] as? String
    }
}

struct ClaudeUsageProvider: AIUsageProvider {
    let id = AIUsageProviderID.claude
    private static let service = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let scopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    private var credentialsPath: String {
        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.claude"
        return URL(fileURLWithPath: AIUsageCredentialIO.expanded(home)).appendingPathComponent(".credentials.json").path
    }

    private enum Source: Sendable { case file(String), keychain(String) }
    private struct Loaded: @unchecked Sendable { var source: Source; var object: [String: Any] }

    func detect() async -> Bool {
        await Task.detached(priority: .utility) {
            if let object = try? AIUsageCredentialIO.readJSONObject(at: credentialsPath),
               Self.oauth(in: object)?["accessToken"] is String { return true }
            guard ClaudeKeychainAccess.isEnabled() else { return false }
            return (try? AIUsageCredentialIO.keychainObject(service: Self.service, allowInteraction: false)) != nil
        }.value
    }

    func refresh() async throws -> AIUsageSnapshot {
        var loaded = try await loadCredentials()
        var oauth = try oauth(from: loaded.object)
        if let expires = AIUsageMapping.number(oauth["expiresAt"]), expires / 1_000 - Date().timeIntervalSince1970 <= 300 {
            loaded = try await rotate(loaded)
            oauth = try self.oauth(from: loaded.object)
        }
        guard let access = oauth["accessToken"] as? String, !access.isEmpty else {
            throw AIUsageMappingError.notConnected("Run `claude` and sign in to connect Claude.")
        }
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty, !scopes.contains("user:profile") {
            throw AIUsageMappingError.notConnected("Run `claude` and sign in again to enable live usage.")
        }
        var response = try await usage(access)
        if [401, 403].contains(response.statusCode), oauth["refreshToken"] as? String != nil {
            loaded = try await rotate(loaded)
            oauth = try self.oauth(from: loaded.object)
            guard let renewed = oauth["accessToken"] as? String else { throw AIUsageMappingError.invalidResponse }
            response = try await usage(renewed)
        }
        guard (200..<300).contains(response.statusCode) else { throw AIUsageMappingError.requestFailed(response.statusCode) }
        let mapped = try AIUsageMapping.claude(
            data: response.data,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
        let history = await AIUsageLocalHistory.claude()
        return AIUsageSnapshot(
            providerID: id,
            plan: mapped.0,
            metrics: mapped.1 + AIUsageLocalHistory.summarize(history),
            fetchedAt: Date(),
            warning: nil,
            history: history.isEmpty ? nil : history
        )
    }

    private func loadCredentials() async throws -> Loaded {
        try await Task.detached(priority: .utility) {
            if let object = try AIUsageCredentialIO.readJSONObject(at: credentialsPath),
               let oauth = Self.oauth(in: object), oauth["accessToken"] is String {
                return Loaded(source: .file(credentialsPath), object: object)
            }
            guard ClaudeKeychainAccess.isEnabled() else {
                throw AIUsageMappingError.notConnected("Claude Keychain access is off. Enable it explicitly in AI Usage settings to load live limits.")
            }
            if let object = try AIUsageCredentialIO.keychainObject(service: Self.service, allowInteraction: true),
               let oauth = Self.oauth(in: object), oauth["accessToken"] is String {
                return Loaded(source: .keychain(Self.service), object: object)
            }
            throw AIUsageMappingError.notConnected("Run `claude` and sign in to connect Claude.")
        }.value
    }

    private func usage(_ access: String) async throws -> AIUsageHTTPResponse {
        try await AIUsageHTTP.send(Self.usageURL, headers: [
            "Authorization": "Bearer \(access.trimmingCharacters(in: .whitespacesAndNewlines))",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.69"
        ])
    }

    private func rotate(_ loaded: Loaded) async throws -> Loaded {
        var oauth = try self.oauth(from: loaded.object)
        guard let refresh = oauth["refreshToken"] as? String, !refresh.isEmpty else {
            throw AIUsageMappingError.notConnected("Claude session expired. Run `claude` and sign in again.")
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": Self.clientID,
            "scope": Self.scopes
        ])
        let response = try await AIUsageHTTP.send(
            Self.refreshURL,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: body,
            timeout: 20
        )
        guard (200..<300).contains(response.statusCode), let values = AIUsageMapping.jsonObject(response.data),
              let access = values["access_token"] as? String else {
            throw AIUsageMappingError.notConnected("Claude session expired. Run `claude` and sign in again.")
        }
        oauth["accessToken"] = access
        if let value = values["refresh_token"] as? String { oauth["refreshToken"] = value }
        if let seconds = AIUsageMapping.number(values["expires_in"]) {
            oauth["expiresAt"] = Date().addingTimeInterval(seconds).timeIntervalSince1970 * 1_000
        }
        var object = loaded.object
        object["claudeAiOauth"] = oauth
        try await Task.detached(priority: .utility) {
            switch loaded.source {
            case .file(let path): try AIUsageCredentialIO.writePrivate(AIUsageCredentialIO.encode(object), to: path)
            case .keychain(let service): try AIUsageCredentialIO.updateKeychain(service: service, object: object)
            }
        }.value
        return Loaded(source: loaded.source, object: object)
    }

    private static func oauth(in object: [String: Any]?) -> [String: Any]? { object?["claudeAiOauth"] as? [String: Any] }
    private func oauth(from object: [String: Any]) throws -> [String: Any] {
        guard let oauth = Self.oauth(in: object) else { throw AIUsageMappingError.invalidResponse }
        return oauth
    }
}

struct OpenCodeUsageProvider: AIUsageProvider {
    let id = AIUsageProviderID.openCode
    private static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!

    private var dataDirectory: String { OpenCodeGoAPIKeyStore.dataDirectory }
    private var authPath: String { OpenCodeGoAPIKeyStore.authPath }

    func detect() async -> Bool {
        await Task.detached(priority: .utility) {
            if OpenCodeGoAPIKeyStore().source() != .missing { return true }
            if FileManager.default.fileExists(atPath: authPath) { return true }
            return (try? databasePaths())?.isEmpty == false
        }.value
    }

    func refresh() async throws -> AIUsageSnapshot {
        var metrics: [AIUsageMetric] = []
        var warning: String?
        var plan: String?
        let key = try await Task.detached(priority: .utility) { try OpenCodeGoAPIKeyStore().effectiveKey() }.value
        if let key {
            let response = try await AIUsageHTTP.send(Self.usageURL, headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"])
            if (200..<300).contains(response.statusCode) {
                metrics += try AIUsageMapping.openCode(data: response.data)
                plan = "Go"
            } else if response.statusCode == 403 {
                warning = "No OpenCode Go subscription. Showing local Go/Zen usage."
            } else if response.statusCode == 401 {
                warning = "OpenCode Go key was rejected. Edit the key in AI Usage Settings."
            } else {
                warning = "OpenCode Go refresh failed (HTTP \(response.statusCode))."
            }
        }
        let paths = (try? databasePaths()) ?? []
        let history = await AIUsageLocalHistory.openCode(databasePaths: paths)
        metrics += AIUsageLocalHistory.summarize(history)
        guard !metrics.isEmpty else {
            throw AIUsageMappingError.notConnected("Use OpenCode Go or Zen once to connect OpenCode.")
        }
        return AIUsageSnapshot(
            providerID: id,
            plan: plan,
            metrics: metrics,
            fetchedAt: Date(),
            warning: warning,
            history: history.isEmpty ? nil : history
        )
    }

    private func databasePaths() throws -> [String] {
        guard FileManager.default.fileExists(atPath: dataDirectory) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dataDirectory)
            .filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }
            .sorted()
            .map { URL(fileURLWithPath: dataDirectory).appendingPathComponent($0).path }
    }

}
