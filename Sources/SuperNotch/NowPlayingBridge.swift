import AppKit
import Foundation

/// One system-wide Now Playing snapshot from the helper.
struct NowPlayingSnapshot: Decodable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsed: Double?
    var rate: Double?
    var timestamp: Double?
    var playing: Bool
    var bundle: String?
    var parentBundle: String?
    var artwork: String?
    var artworkKey: String?

    /// Browsers report web media from a helper process; the parent is the app people recognize.
    var appBundleIdentifier: String? { parentBundle ?? bundle }

    static func decode(line: Data) -> NowPlayingSnapshot? {
        try? JSONDecoder().decode(NowPlayingSnapshot.self, from: line)
    }
}

/// Runs the bundled Now Playing helper inside `/usr/bin/perl` and relays its JSON line stream.
///
/// macOS 15.4 and later only share MediaRemote state with Apple-identified processes, so the helper
/// library is hosted by the system interpreter. Commands are written to the helper's stdin; the helper
/// exits when that pipe closes, so it never outlives SuperNotch.
final class NowPlayingBridge: @unchecked Sendable {
    typealias SnapshotHandler = @Sendable (NowPlayingSnapshot) -> Void
    typealias FailureHandler = @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "app.supernotch.nowplaying.bridge")
    private let onSnapshot: SnapshotHandler
    private let onFailure: FailureHandler
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stopped = true
    private var recentFailures: [Date] = []
    private static let maximumLineBytes = 8 * 1024 * 1024

    init(onSnapshot: @escaping SnapshotHandler, onFailure: @escaping FailureHandler) {
        self.onSnapshot = onSnapshot
        self.onFailure = onFailure
    }

    static var helperFiles: (script: URL, library: URL)? {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("NowPlaying", isDirectory: true) else { return nil }
        let script = resources.appendingPathComponent("now-playing.pl")
        let library = resources.appendingPathComponent("NowPlayingHelper.dylib")
        let manager = FileManager.default
        guard manager.fileExists(atPath: script.path), manager.fileExists(atPath: library.path), manager.isExecutableFile(atPath: "/usr/bin/perl") else { return nil }
        return (script, library)
    }

    var isAvailable: Bool { Self.helperFiles != nil }

    func start() {
        queue.async { [self] in
            stopped = false
            launch()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            terminate()
        }
    }

    func send(_ command: String) {
        queue.async { [self] in
            guard let input, let data = (command + "\n").data(using: .utf8) else { return }
            try? input.write(contentsOf: data)
        }
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        guard let files = Self.helperFiles else {
            onFailure("System-wide Now Playing needs the packaged app. Build it with scripts/build-app.sh.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [files.script.path, files.library.path]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.queue.async { self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] finished in
            self?.queue.async { self?.handleExit(of: finished) }
        }
        do {
            try process.run()
            self.process = process
            self.input = stdin.fileHandleForWriting
            buffer.removeAll(keepingCapacity: true)
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            onFailure("Now Playing could not start: \(error.localizedDescription)")
        }
    }

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let snapshot = NowPlayingSnapshot.decode(line: Data(line)) { onSnapshot(snapshot) }
        }
        if buffer.count > Self.maximumLineBytes { buffer.removeAll() }
    }

    private func handleExit(of finished: Process) {
        guard finished === process else { return }
        (finished.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        guard !stopped else { return }
        let now = Date()
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentFailures.count >= 5 {
            stopped = true
            onFailure("Now Playing stopped responding. Choose a player again to retry.")
            return
        }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.launch() }
    }

    private func terminate() {
        guard let process else { return }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        if process.isRunning { process.terminate() }
        self.process = nil
        input = nil
    }
}
