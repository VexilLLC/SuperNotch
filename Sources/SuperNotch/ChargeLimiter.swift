import Foundation
import AppKit
import CryptoKit
import ChargeLimitCore

/// Installs and talks to the root charge helper.
///
/// The app never touches the SMC itself. It writes `ChargeLimitConfiguration`
/// into a user-owned settings folder, and the helper daemon enforces it and
/// reports back through a root-owned status file.
@MainActor
final class ChargeLimiter: ObservableObject {
    static let shared = ChargeLimiter()

    enum HelperState: Equatable {
        case checking
        case notInstalled
        case outdated
        case installed
        /// The Mac has no software charge control, or the helper is not bundled.
        case unsupported(String)
    }

    @Published private(set) var helperState: HelperState = .checking
    @Published private(set) var status: ChargeLimitStatus?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private var probedSupport: Bool?
    private var isRefreshing = false
    private let queue = DispatchQueue(label: "SuperNotch.charge-limiter", qos: .utility)

    /// A status older than this means the daemon is not running.
    static let staleStatusInterval: TimeInterval = 120

    var isHelperResponding: Bool {
        guard let status else { return false }
        return Date().timeIntervalSince(status.updatedAt) < Self.staleStatusInterval
    }

    var canInstall: Bool {
        if case .unsupported = helperState { return false }
        return !isWorking && bundledHelperURL != nil
    }

    var bundledHelperURL: URL? {
        Bundle.main.url(forAuxiliaryExecutable: "SuperNotchChargeHelper")
    }

    // MARK: Status

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let helperURL = bundledHelperURL
        let needsProbe = probedSupport == nil
        queue.async { [weak self] in
            let installed = FileManager.default.fileExists(atPath: ChargeLimitPaths.helperExecutable)
                && FileManager.default.fileExists(atPath: ChargeLimitPaths.launchDaemonPlist)
            let status = Self.readStatus()
            let support = needsProbe ? Self.probeSupport(helperURL) : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                if let support { self.probedSupport = support }
                if self.status != status { self.status = status }
                let state = self.resolveState(installed: installed, status: status, helperURL: helperURL)
                if self.helperState != state { self.helperState = state }
            }
        }
    }

    private func resolveState(installed: Bool, status: ChargeLimitStatus?, helperURL: URL?) -> HelperState {
        if installed {
            if let status, status.helperVersion < ChargeLimitPaths.helperVersion, helperURL != nil { return .outdated }
            return .installed
        }
        guard helperURL != nil else {
            return .unsupported("The charge helper is missing from this build. Build the app with scripts/build-app.sh.")
        }
        if probedSupport == false {
            return .unsupported("This Mac does not let software pause charging.")
        }
        return .notInstalled
    }

    nonisolated private static func readStatus() -> ChargeLimitStatus? {
        guard let data = FileManager.default.contents(atPath: ChargeLimitPaths.statusFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChargeLimitStatus.self, from: data)
    }

    /// Runs the bundled helper unprivileged; reading SMC keys does not need root.
    nonisolated private static func probeSupport(_ helperURL: URL?) -> Bool? {
        guard let helperURL else { return nil }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["probe"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return nil
        }
    }

    // MARK: Configuration

    /// Writes settings for the helper. Returns false if the helper is not installed.
    @discardableResult
    func apply(_ configuration: ChargeLimitConfiguration) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: ChargeLimitPaths.helperExecutable),
              FileManager.default.fileExists(atPath: ChargeLimitPaths.settingsDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        do {
            let data = try JSONEncoder().encode(configuration)
            try data.write(to: URL(fileURLWithPath: ChargeLimitPaths.configurationFile), options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "Could not save the charge limit: \(error.localizedDescription)"
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
        return true
    }

    // MARK: Install and uninstall

    /// Installs or updates the helper. macOS shows its own administrator prompt.
    func install(then configuration: ChargeLimitConfiguration? = nil, completion: ((Bool) -> Void)? = nil) {
        guard !isWorking else { completion?(false); return }
        guard let helperURL = bundledHelperURL else {
            errorMessage = "The charge helper is missing from this build. Build the app with scripts/build-app.sh."
            completion?(false)
            return
        }
        guard let data = try? Data(contentsOf: helperURL) else {
            errorMessage = "Could not read the bundled charge helper."
            completion?(false)
            return
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let script = Self.installScript(source: helperURL.path, sha256: hash, userID: getuid())
        runPrivileged(script, prompt: "SuperNotch wants to install a helper that can pause charging at your charge limit.") { [weak self] success in
            guard let self else { return }
            if success {
                self.helperState = .installed
                if let configuration { self.apply(configuration) }
            }
            self.refresh()
            completion?(success)
        }
    }

    func uninstall(completion: ((Bool) -> Void)? = nil) {
        guard !isWorking else { completion?(false); return }
        runPrivileged(Self.uninstallScript(), prompt: "SuperNotch wants to remove its charge helper and restore normal charging.") { [weak self] success in
            guard let self else { return }
            if success {
                self.status = nil
                self.helperState = .notInstalled
            }
            self.refresh()
            completion?(success)
        }
    }

    private func runPrivileged(_ command: String, prompt: String, completion: @escaping (Bool) -> Void) {
        isWorking = true
        errorMessage = nil
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // Pass the command as an argument so it never needs AppleScript string escaping.
            process.arguments = [
                "-e", "on run argv",
                "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                "-e", "end run",
                command, prompt
            ]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            var output = ""
            var success = false
            do {
                try process.run()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                output = String(decoding: errorData, as: UTF8.self)
                success = process.terminationStatus == 0
            } catch {
                output = error.localizedDescription
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isWorking = false
                if !success {
                    self.errorMessage = output.contains("-128")
                        ? "Cancelled. The charge limit needs the helper to pause charging."
                        : "The helper could not be installed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
                completion(success)
            }
        }
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func installScript(source: String, sha256: String, userID: uid_t) -> String {
        let helper = shellQuote(ChargeLimitPaths.helperExecutable)
        let plist = shellQuote(ChargeLimitPaths.launchDaemonPlist)
        let label = shellQuote("system/" + ChargeLimitPaths.label)
        return """
        set -e
        tmp=$(/usr/bin/mktemp -d /private/var/tmp/supernotch-helper.XXXXXX)
        trap '/bin/rm -rf "$tmp"' EXIT
        /bin/cp \(shellQuote(source)) "$tmp/helper"
        /usr/bin/printf '%s  %s\\n' \(shellQuote(sha256)) "$tmp/helper" | /usr/bin/shasum -a 256 -c - >/dev/null
        /bin/launchctl bootout \(label) 2>/dev/null || true
        for attempt in 1 2 3 4 5 6 7 8 9 10; do /bin/launchctl print \(label) >/dev/null 2>&1 || break; /bin/sleep 0.5; done
        /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        /usr/bin/install -o root -g wheel -m 755 "$tmp/helper" \(helper)
        /usr/bin/install -d -o root -g wheel -m 755 \(shellQuote("/Library/Application Support/SuperNotch")) \(shellQuote(ChargeLimitPaths.stateDirectory))
        /usr/bin/install -d -o \(userID) -g staff -m 755 \(shellQuote(ChargeLimitPaths.settingsDirectory))
        \(helper) write-launchd-plist
        /bin/launchctl bootstrap system \(plist)
        """
    }

    nonisolated static func uninstallScript() -> String {
        let helper = shellQuote(ChargeLimitPaths.helperExecutable)
        return """
        /bin/launchctl bootout \(shellQuote("system/" + ChargeLimitPaths.label)) 2>/dev/null || true
        if [ -x \(helper) ]; then \(helper) restore || true; fi
        /bin/rm -f \(shellQuote(ChargeLimitPaths.launchDaemonPlist)) \(helper)
        /bin/rm -rf \(shellQuote(ChargeLimitPaths.stateDirectory))
        """
    }
}
