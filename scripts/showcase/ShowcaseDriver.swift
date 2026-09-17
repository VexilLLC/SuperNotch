// Drives a running showcase instance of SuperNotch and captures each surface.
//
// The app must have been launched with SUPERNOTCH_SHOWCASE=1 so that it is
// serving fabricated content out of a throwaway container. See
// scripts/capture-showcase.sh, which is the supported entry point.

import AppKit
import CoreGraphics
import Foundation

struct WindowInfo {
    let id: CGWindowID
    let name: String
    let bounds: CGRect
    let onScreen: Bool
}

func windows(for pid: pid_t) -> [WindowInfo] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { entry in
        guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
              let id = entry[kCGWindowNumber as String] as? CGWindowID,
              let raw = entry[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let bounds = CGRect(x: raw["X"] ?? 0, y: raw["Y"] ?? 0, width: raw["Width"] ?? 0, height: raw["Height"] ?? 0)
        return WindowInfo(
            id: id,
            name: entry[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            onScreen: (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
        )
    }
}

func wait(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

func post(_ command: String) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.vexil.supernotch.showcase.command"),
        object: command,
        userInfo: nil,
        deliverImmediately: true
    )
}

@discardableResult
func screencapture(_ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// Captures a single window with its alpha preserved.
func captureWindow(_ window: WindowInfo, to url: URL) {
    screencapture(["-x", "-o", "-l\(window.id)", url.path])
}

/// Captures the screen rectangle a window occupies. Used for surfaces that draw
/// with vibrancy, which a window-targeted capture renders as flat grey.
func captureRegion(_ window: WindowInfo, to url: URL, inset: CGFloat = 0) {
    let rect = window.bounds.insetBy(dx: inset, dy: inset)
    screencapture(["-x", "-o", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", url.path])
}

// MARK: - Arguments

var pid: pid_t = 0
var outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
    arguments.removeFirst()
    switch flag {
    case "--pid":
        pid = pid_t(arguments.removeFirst()) ?? 0
    case "--out":
        outputDirectory = URL(fileURLWithPath: arguments.removeFirst())
    default:
        FileHandle.standardError.write(Data("unknown argument \(flag)\n".utf8))
        exit(2)
    }
}
guard pid > 0 else {
    FileHandle.standardError.write(Data("usage: ShowcaseDriver --pid <pid> --out <dir>\n".utf8))
    exit(2)
}
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func output(_ name: String) -> URL { outputDirectory.appendingPathComponent(name) }

// MARK: - Window predicates

/// The island panel sits flush against the top of a display and is the widest
/// of the app's top-anchored windows.
func islandWindow() -> WindowInfo? {
    windows(for: pid)
        .filter { $0.onScreen && $0.bounds.minY <= 1 && $0.bounds.width > 400 && $0.name.isEmpty }
        .max { $0.bounds.width < $1.bounds.width }
}

func namedWindow(_ needle: String) -> WindowInfo? {
    windows(for: pid).first { $0.onScreen && $0.name.localizedCaseInsensitiveContains(needle) }
}

func largestWindow() -> WindowInfo? {
    windows(for: pid)
        .filter { $0.onScreen && $0.bounds.width > 700 && $0.bounds.height > 500 }
        .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
}

// MARK: - Capture plan

var captured: [String] = []

func requireIsland(_ label: String) -> WindowInfo? {
    for _ in 0..<20 {
        if let window = islandWindow() { return window }
        wait(0.25)
    }
    FileHandle.standardError.write(Data("could not find the island window for \(label)\n".utf8))
    return nil
}

print("waiting for the showcase instance to settle")
wait(4)

// The island, in each of its states.
let islandShots: [(command: String, file: String)] = [
    ("island.collapse", "island-collapsed.png"),
    ("island.0", "island-home.png"),
    ("island.1", "island-tray.png"),
    ("island.2", "island-widgets.png")
]
for shot in islandShots {
    post(shot.command)
    wait(1.6)
    guard let window = requireIsland(shot.file) else { continue }
    captureWindow(window, to: output(shot.file))
    captured.append(shot.file)
}

// The command palette draws with vibrancy, so it is captured from the screen.
post("island.collapse")
wait(0.8)
for shot in [("palette", "palette.png"), ("palette.clipboard", "palette-clipboard.png")] {
    post(shot.0)
    wait(2.0)
    if let window = namedWindow("Command Palette") {
        captureRegion(window, to: output(shot.1))
        captured.append(shot.1)
    } else {
        FileHandle.standardError.write(Data("could not find the command palette for \(shot.1)\n".utf8))
    }
}

// The workspace.
for shot in [("workspace.overview", "workspace-overview.png"), ("workspace.clipboard", "workspace-clipboard.png")] {
    post(shot.0)
    wait(2.5)
    if let window = largestWindow() {
        captureWindow(window, to: output(shot.1))
        captured.append(shot.1)
    } else {
        FileHandle.standardError.write(Data("could not find the workspace window for \(shot.1)\n".utf8))
    }
}

print("captured \(captured.count) surfaces into \(outputDirectory.path)")
for name in captured { print("  \(name)") }
