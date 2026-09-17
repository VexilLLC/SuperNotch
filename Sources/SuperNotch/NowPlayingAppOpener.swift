import AppKit
import ApplicationServices

/// Brings the app that is playing back to the front, the way clicking its Dock
/// icon does: unhide it, un-minimize a window, raise it, and reopen the app
/// when every window is closed.
@MainActor
enum NowPlayingAppOpener {
    enum Step: Equatable {
        case unhide
        case unminimize
        case raiseWindow
        case activate
        /// Ask the app to open a window, like clicking its Dock icon.
        case reopen
        /// Nothing is running for this app; launch it.
        case launch
    }

    /// The ordered steps for a player in a given state. Pure, so it can be tested.
    static func plan(isRunning: Bool, isHidden: Bool, hasVisibleWindow: Bool, hasMinimizedWindow: Bool) -> [Step] {
        guard isRunning else { return [.launch] }
        var steps: [Step] = []
        if isHidden { steps.append(.unhide) }
        if !hasVisibleWindow, hasMinimizedWindow { steps.append(.unminimize) }
        // A running app with no window at all (common for browsers and Music
        // after closing the window) needs a reopen to get one back.
        if !hasVisibleWindow, !hasMinimizedWindow { steps.append(.reopen) }
        steps.append(.raiseWindow)
        steps.append(.activate)
        return steps
    }

    /// What the island's "open player" button does: Spotify through its Dock
    /// helper, any other player's window, or SuperNotch's music page.
    /// - Parameter showOnly: Always show the player, never hide it (double-click).
    ///   The button instead hides Spotify when it is already in front.
    static func openCurrentPlayer(showOnly: Bool = false) {
        let media = MediaController.shared
        if media.source == "Spotify" || (media.isAutomatic && media.appBundleIdentifier == SpotifyDockManager.bundleIdentifier) {
            if showOnly {
                SpotifyDockManager.shared.focusSpotify()
            } else {
                SpotifyDockManager.shared.toggleSpotifyWindow()
            }
            return
        }
        if open(bundleIdentifier: media.appBundleIdentifier) { return }
        AppState.shared.page = .media
        AppDelegate.shared?.openWorkspace()
    }

    /// Opens the player. Returns false when there is nothing to open, so the
    /// caller can fall back to the SuperNotch music page.
    @discardableResult
    static func open(bundleIdentifier: String?, allowSpotifyHelper: Bool = true) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        if allowSpotifyHelper, bundleIdentifier == SpotifyDockManager.bundleIdentifier {
            SpotifyDockManager.shared.toggleSpotifyWindow()
            return true
        }

        let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        let windows = application.map { Self.windowCounts(pid: $0.processIdentifier) } ?? (visible: 0, minimized: 0)
        let steps = plan(
            isRunning: application != nil,
            isHidden: application?.isHidden ?? false,
            hasVisibleWindow: windows.visible > 0,
            hasMinimizedWindow: windows.minimized > 0
        )

        for step in steps {
            switch step {
            case .unhide:
                application?.unhide()
            case .unminimize:
                if let application { unminimizeFirstWindow(pid: application.processIdentifier) }
            case .raiseWindow:
                if let application { raiseFirstWindow(pid: application.processIdentifier) }
            case .activate:
                if let application { bringToFront(application) }
            case .reopen, .launch:
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return false }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                // Without this, a running app is only activated and keeps its closed window.
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
        }
        return true
    }

    /// Brings another app to the front in response to a user action.
    ///
    /// Since macOS 14 an app may only activate another app it is yielding to,
    /// so SuperNotch activates itself for this click, yields to the target and
    /// then activates it. If that is refused, Launch Services activation (what
    /// a Dock click uses) is tried as a fallback.
    static func bringToFront(_ application: NSRunningApplication) {
        NSApp.activate()
        NSApp.yieldActivation(to: application)
        application.activate(from: .current, options: [.activateAllWindows])
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !application.isActive, !application.isTerminated, let url = application.bundleURL else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
    }

    /// Counts on-screen and minimized windows without needing screen recording
    /// access: only the owner, layer and size of each window are read.
    private static func windowCounts(pid: pid_t) -> (visible: Int, minimized: Int) {
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return (0, 0) }
        var visible = 0
        var minimized = 0
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let height = bounds["Height"] as? Double, let width = bounds["Width"] as? Double,
                  height > 60, width > 60 else { continue }
            if (window[kCGWindowIsOnscreen as String] as? Bool) == true { visible += 1 } else { minimized += 1 }
        }
        return (visible, minimized)
    }

    private static func raiseFirstWindow(pid: pid_t) {
        guard AXIsProcessTrusted(), let window = firstWindow(pid: pid) else { return }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func unminimizeFirstWindow(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for window in windows {
            var minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  (minimized as? Bool) == true else { continue }
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            return
        }
    }

    private static func firstWindow(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first
    }
}
