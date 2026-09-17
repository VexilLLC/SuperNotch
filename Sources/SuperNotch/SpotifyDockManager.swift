import AppKit
import Foundation

@MainActor final class SpotifyDockManager: ObservableObject {
    static let shared = SpotifyDockManager()
    nonisolated static let bundleIdentifier = "com.spotify.client"

    enum State: Equatable {
        case unavailable
        case ready
        case preparing
        case prepared
        case restoring
        case failed(String)
    }

    @Published private(set) var state: State = .unavailable
    @Published private(set) var spotifyVersion = ""

    var isPrepared: Bool { state == .prepared }
    var isBusy: Bool { state == .preparing || state == .restoring }

    private init() { refresh() }

    func refresh() {
        guard let appURL = spotifyApplicationURL else {
            spotifyVersion = ""
            state = .unavailable
            return
        }
        spotifyVersion = Self.bundleVersion(at: appURL) ?? "Unknown"
        let binary = Self.mainExecutable(at: appURL)
        let helper = Self.installedHelper(at: appURL)
        state = ((try? SpotifyDockMachO.containsHelper(at: binary)) == true && FileManager.default.fileExists(atPath: helper.path)) ? .prepared : .ready
    }

    func prepare() {
        guard !isBusy, let appURL = spotifyApplicationURL else { return }
        guard let bundledHelper = Self.bundledHelperURL else {
            state = .failed("Build and run the packaged SuperNotch app before enabling Dockless Spotify.")
            return
        }
        state = .preparing
        Task { [weak self] in
            guard let self else { return }
            await self.quitSpotify()
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.prepareFiles(appURL: appURL, bundledHelper: bundledHelper) }
            }.value
            switch result {
            case .success:
                self.state = .prepared
                self.launchSpotify()
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func restore() {
        guard !isBusy, let appURL = spotifyApplicationURL else { return }
        let version = Self.bundleVersion(at: appURL) ?? spotifyVersion
        let backup = Self.backupApplicationURL(version: version)
        guard FileManager.default.fileExists(atPath: backup.path) else {
            state = .failed("The original Spotify backup for version \(version) is missing.")
            return
        }
        state = .restoring
        Task { [weak self] in
            guard let self else { return }
            await self.quitSpotify()
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.restoreFiles(appURL: appURL, backupURL: backup) }
            }.value
            switch result {
            case .success:
                self.state = .ready
                self.launchSpotifyNormally()
            case .failure(let error):
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func focusSpotify() {
        guard isPrepared else {
            launchSpotifyNormally()
            return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty {
            launchSpotify()
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                Self.post("focus")
            }
        } else {
            Self.post("focus")
            bringSpotifyForward()
        }
    }

    /// Shows Spotify, or hides it when it is already the app in front.
    func toggleSpotifyWindow() {
        guard isPrepared else {
            launchSpotifyNormally()
            return
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty {
            launchSpotify()
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                Self.post("focus")
                self.bringSpotifyForward()
            }
            return
        }
        // Spotify has no Dock icon here, so it never owns the menu bar and
        // `frontmostApplication` cannot see it; `isActive` can.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        if Self.toggleAction(spotifyIsFrontmost: running.contains(where: \.isActive)) == "toggle" {
            // Already in front: hide it, like pressing ⌘H in Spotify.
            running.forEach { $0.hide() }
        } else {
            Self.post("focus")
            bringSpotifyForward()
        }
    }

    /// Since macOS 14 a background app cannot activate itself, so the helper's
    /// own activation only orders Spotify's window behind the app in front.
    /// Activating through Launch Services, like a Dock click, is allowed.
    private func bringSpotifyForward() {
        Task {
            // Let the helper unhide and order its windows first.
            try? await Task.sleep(for: .milliseconds(120))
            guard let spotify = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first else { return }
            NowPlayingAppOpener.bringToFront(spotify)
        }
    }

    /// AppKit reports a window on another Space, or covered by other windows,
    /// as visible, so the helper's own toggle could hide a window the user
    /// cannot see. Only ask it to toggle when Spotify is really in front.
    nonisolated static func toggleAction(spotifyIsFrontmost: Bool) -> String {
        spotifyIsFrontmost ? "toggle" : "focus"
    }

    func hideDockIcon() { if isPrepared { Self.post("hide") } }

    private var spotifyApplicationURL: URL? {
        let standard = URL(fileURLWithPath: "/Applications/Spotify.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: standard.path) { return standard }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }

    private func quitSpotify() async {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        applications.forEach { $0.terminate() }
        for _ in 0..<25 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).forEach { $0.forceTerminate() }
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func launchSpotify() {
        guard let appURL = spotifyApplicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.state = .failed("Spotify could not launch: \(error.localizedDescription)") }
        }
    }

    private func launchSpotifyNormally() {
        // Without the Dock helper, treat Spotify like any other player: unhide,
        // restore or reopen its window and bring it forward.
        if NowPlayingAppOpener.open(bundleIdentifier: Self.bundleIdentifier, allowSpotifyHelper: false) { return }
        guard let appURL = spotifyApplicationURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
    }

    private nonisolated static var bundledHelperURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("SpotifyDock/SuperNotchSpotifyDock.dylib")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated static func mainExecutable(at appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/MacOS/Spotify")
    }

    private nonisolated static func installedHelper(at appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/Frameworks/SuperNotchSpotifyDock.dylib")
    }

    private nonisolated static func bundleVersion(at appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private nonisolated static func backupApplicationURL(version: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SuperNotch/SpotifyDock/Backups", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("Spotify.app", isDirectory: true)
    }

    private nonisolated static func prepareFiles(appURL: URL, bundledHelper: URL) throws {
        let manager = FileManager.default
        let version = bundleVersion(at: appURL) ?? "Unknown"
        let backup = backupApplicationURL(version: version)
        if !manager.fileExists(atPath: backup.path) {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
            try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["--rsrc", "--extattr", appURL.path, backup.path])
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", backup.path])
        }

        let temporary = manager.temporaryDirectory.appendingPathComponent("SuperNotch-SpotifyDock-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }

        let originalBinary = mainExecutable(at: appURL)
        let workingBinary = temporary.appendingPathComponent("Spotify")
        try manager.copyItem(at: originalBinary, to: workingBinary)
        _ = try? run("/usr/bin/codesign", ["--remove-signature", workingBinary.path])

        let loadCommands = try run("/usr/bin/otool", ["-l", workingBinary.path])
        if !loadCommands.contains("path @executable_path/../Frameworks") {
            try run("/usr/bin/install_name_tool", ["-add_rpath", "@executable_path/../Frameworks", workingBinary.path])
        }
        try SpotifyDockMachO.insertHelper(into: workingBinary)

        var entitlements = try extractEntitlements(from: appURL)
        entitlements["com.apple.security.cs.allow-dyld-environment-variables"] = true
        entitlements["com.apple.security.cs.disable-library-validation"] = true
        let entitlementsURL = temporary.appendingPathComponent("entitlements.plist")
        let entitlementData = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try entitlementData.write(to: entitlementsURL, options: .atomic)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlementsURL.path, workingBinary.path])

        var changedInstalledApplication = false
        do {
            _ = try manager.replaceItemAt(originalBinary, withItemAt: workingBinary)
            changedInstalledApplication = true
            let helperDestination = installedHelper(at: appURL)
            try manager.createDirectory(at: helperDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: helperDestination.path) { try manager.removeItem(at: helperDestination) }
            try manager.copyItem(at: bundledHelper, to: helperDestination)
            try run("/usr/bin/codesign", ["--force", "--sign", "-", helperDestination.path])
            try run("/usr/bin/codesign", ["--force", "--sign", "-", "--preserve-metadata=entitlements", appURL.path])
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        } catch {
            guard changedInstalledApplication else { throw error }
            let setupError = error
            do {
                try manager.removeItem(at: appURL)
                try run("/usr/bin/ditto", ["--rsrc", "--extattr", backup.path, appURL.path])
                try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
            } catch let recoveryError {
                throw NSError(
                    domain: "SuperNotchSpotifyDock",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Setup failed (\(setupError.localizedDescription)) and Spotify could not be restored automatically (\(recoveryError.localizedDescription)). The verified backup is at \(backup.path)."]
                )
            }
            throw setupError
        }
    }

    private nonisolated static func restoreFiles(appURL: URL, backupURL: URL) throws {
        let manager = FileManager.default
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", backupURL.path])
        let preserved = backupURL.deletingLastPathComponent().appendingPathComponent("Last Managed Spotify.app", isDirectory: true)
        let managedArchive: URL
        if manager.fileExists(atPath: preserved.path) {
            managedArchive = backupURL.deletingLastPathComponent().appendingPathComponent("Last Managed Spotify \(Int(Date().timeIntervalSince1970)).app", isDirectory: true)
        } else {
            managedArchive = preserved
        }
        try manager.moveItem(at: appURL, to: managedArchive)
        do {
            try run("/usr/bin/ditto", ["--rsrc", "--extattr", backupURL.path, appURL.path])
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appURL.path])
        } catch {
            let restoreError = error
            if manager.fileExists(atPath: appURL.path) { try? manager.removeItem(at: appURL) }
            try? manager.moveItem(at: managedArchive, to: appURL)
            throw restoreError
        }
    }

    private nonisolated static func extractEntitlements(from appURL: URL) throws -> [String: Any] {
        let output = try run("/usr/bin/codesign", ["-d", "--entitlements", ":-", appURL.path], includeStandardError: true)
        guard let start = output.range(of: "<?xml"), let end = output.range(of: "</plist>", range: start.lowerBound..<output.endIndex) else { return [:] }
        let xml = String(output[start.lowerBound..<end.upperBound])
        guard let data = xml.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return plist
    }

    @discardableResult private nonisolated static func run(_ executable: String, _ arguments: [String], includeStandardError: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = includeStandardError ? output : errorPipe
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = includeStandardError ? Data() : errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let errorText = includeStandardError ? "" : String(decoding: errorData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SuperNotchSpotifyDock", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "\(executable) failed." : errorText.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        return text
    }

    private nonisolated static func post(_ action: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("\(bundleIdentifier).supernotch.\(action)"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
