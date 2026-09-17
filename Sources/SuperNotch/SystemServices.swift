import SwiftUI
import AppKit
import CoreAudio
import AudioToolbox
import IOKit.ps
import Network
import Combine

@MainActor final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    @Published var battery = 100
    @Published var charging = false
    @Published var hasBattery = false
    @Published var connected = true
    @Published var volume: Float = 0.5
    @Published var memoryUsed: Double = 0
    @Published var uptime = ""
    @Published var activity = "All systems ready"
    /// Lets event-driven consumers piggyback on the existing low-frequency system sample.
    let didRefresh = PassthroughSubject<Void, Never>()
    private var timer: Timer?
    private let network = NWPathMonitor()
    func start() {
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        network.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.connected = path.status == .satisfied } }
        network.start(queue: DispatchQueue(label: "SuperNotch.network"))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            let name = (n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.lastPathComponent ?? "Drive"
            Task { @MainActor in self?.activity = "\(name) connected" }
        }
    }
    func refresh() {
        defer { didRefresh.send() }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list { if let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] {
                hasBattery = true; let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0; let maxValue = d[kIOPSMaxCapacityKey] as? Int ?? 100
                battery = maxValue > 0 ? Int(Double(current) / Double(maxValue) * 100) : 0; charging = d[kIOPSIsChargingKey] as? Bool ?? false
            } }
        }
        volume = readVolume()
        var stats = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        if result == KERN_SUCCESS { memoryUsed = Double(stats.active_count + stats.wire_count + stats.compressor_page_count) * Double(vm_kernel_page_size) / 1_073_741_824 }
        let hours = Int(ProcessInfo.processInfo.systemUptime) / 3600; uptime = "\(hours / 24)d \(hours % 24)h"
    }
    private func device() -> AudioDeviceID {
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id); return id
    }
    func readVolume() -> Float {
        var value: Float32 = 0.5; var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device(), &address, 0, nil, &size, &value); return value
    }
    func setVolume(_ value: Float) {
        var value = max(0, min(1, value)); var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        let result = AudioObjectSetPropertyData(device(), &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if result == noErr { volume = value; activity = "Volume \(Int(value * 100))%" } else { activity = "This output uses hardware volume controls" }
    }
}

/// Playback position, published separately so per-second ticks only refresh views that show time.
@MainActor final class MediaProgress: ObservableObject {
    static let shared = MediaProgress()
    @Published var value: Double = 0
}

@MainActor final class MediaController: ObservableObject {
    static let shared = MediaController()
    @Published var title = "Your music, up here."
    @Published var artist = "Connect Music or Spotify to begin"
    @Published var playing = false
    var progress: Double {
        get { MediaProgress.shared.value }
        set { if abs(MediaProgress.shared.value - newValue) >= 0.25 || newValue == 0 { MediaProgress.shared.value = newValue } }
    }
    @Published var duration: Double = 1
    /// "Automatic" follows whatever app macOS reports as Now Playing; "Music" and "Spotify" use AppleScript.
    @Published var source = UserDefaults.standard.string(forKey: "mediaSource") ?? "Automatic" {
        didSet {
            guard oldValue != source else { return }
            UserDefaults.standard.set(source, forKey: "mediaSource")
            sourceRevision &+= 1
            refreshTask?.cancel()
            refreshTask = nil
            spotifyTimingTask?.cancel()
            spotifyTimingTask = nil
            polling = false
            clearCurrentArtwork()
            clearAppIdentity()
            if oldValue == "Automatic" { bridge?.stop() }
            if enabled { connect() }
        }
    }
    @Published var enabled = false
    @Published var error: String?
    @Published private(set) var artwork: NSImage?
    /// The app currently playing, when known (for example a browser playing YouTube).
    @Published private(set) var appName: String?
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var appBundleIdentifier: String?
    var isAutomatic: Bool { source == "Automatic" }
    private var bridge: NowPlayingBridge?
    private var snapshotElapsed: Double = 0
    private var snapshotDate = Date()
    private var snapshotRate: Double = 0
    private var hasSnapshot = false
    private var timer: Timer?
    private var polling = false
    private var refreshTask: Task<Void, Never>?
    private var spotifyTimingTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkKey: String?
    private let artworkCache = MediaArtworkCache()
    private var artworkRetryAt: [String: Date] = [:]
    private var sourceRevision = 0

    func connect() {
        enabled = true
        timer?.invalidate(); timer = nil
        if isAutomatic {
            startBridge()
            updateProgressClock()
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Reconnects the selected player at launch. Automatic tracking needs no Automation permission.
    func startAutomaticIfNeeded() {
        // A showcase run keeps its scripted track instead of tracking real playback.
        guard !Showcase.isActive else { return }
        if !enabled { connect() }
    }

    /// Installs a fictional Now Playing track for documentation screenshots.
    func applyShowcaseTrack(title: String, artist: String, artwork: NSImage, elapsed: Double, duration: Double) {
        guard Showcase.isActive else { return }
        self.title = title
        self.artist = artist
        self.duration = duration
        self.artwork = artwork
        progress = elapsed
        playing = true
        enabled = true
        error = nil
    }

    private func startBridge() {
        if bridge == nil {
            bridge = NowPlayingBridge(
                onSnapshot: { snapshot in Task { @MainActor in MediaController.shared.apply(snapshot) } },
                onFailure: { message in Task { @MainActor in MediaController.shared.bridgeFailed(message) } }
            )
        }
        guard let bridge, bridge.isAvailable else {
            error = "System-wide Now Playing needs the packaged app. Choose Apple Music or Spotify, or build with scripts/build-app.sh."
            title = "Now Playing unavailable"; artist = "Choose a player below"
            return
        }
        if !hasSnapshot { title = "Nothing playing"; artist = "Play something in any app" }
        error = nil
        bridge.start()
    }

    private func bridgeFailed(_ message: String) {
        guard isAutomatic else { return }
        error = message
        playing = false
    }

    private func apply(_ snapshot: NowPlayingSnapshot) {
        guard isAutomatic, enabled else { return }
        hasSnapshot = true
        if error != nil { error = nil }
        guard let newTitle = snapshot.title, !newTitle.isEmpty else {
            if title != "Nothing playing" { title = "Nothing playing" }
            if artist != "Play something in any app" { artist = "Play something in any app" }
            if playing { playing = false }
            if duration != 1 { duration = 1 }
            progress = 0; snapshotRate = 0
            updateProgressClock()
            clearCurrentArtwork(); clearAppIdentity()
            return
        }
        updateAppIdentity(snapshot.appBundleIdentifier)
        if title != newTitle { title = newTitle }
        let trimmedArtist = snapshot.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextArtist = !trimmedArtist.isEmpty ? trimmedArtist : (snapshot.album?.isEmpty == false ? snapshot.album! : (appName ?? "Unknown artist"))
        if artist != nextArtist { artist = nextArtist }
        let nextDuration = max(1, snapshot.duration ?? 1)
        if duration != nextDuration { duration = nextDuration }
        if playing != snapshot.playing { playing = snapshot.playing }
        snapshotElapsed = snapshot.elapsed ?? 0
        snapshotDate = snapshot.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
        snapshotRate = snapshot.playing ? (snapshot.rate ?? 1) : 0
        interpolateProgress()
        updateProgressClock()
        if snapshot.appBundleIdentifier == SpotifyDockManager.bundleIdentifier {
            refreshSpotifyTiming(expectedTitle: newTitle)
        }

        updateAutomaticArtwork(key: snapshot.artworkKey, encoded: snapshot.artwork)
    }

    func updateAutomaticArtwork(key: String?, encoded: String?) {
        guard let key else { clearCurrentArtwork(); return }
        let cacheKey = "Automatic\u{1E}" + key
        // Heartbeats carry the key but no image. Do not cancel an in-flight decode.
        if artworkKey == cacheKey, artwork != nil || artworkTask != nil { return }
        clearCurrentArtwork()
        artworkKey = cacheKey
        if let cached = artworkCache.image(for: cacheKey) {
            artwork = cached
            return
        }
        guard let encoded, encoded.utf8.count <= 6 * 1024 * 1024 else { return }
        let revision = sourceRevision
        artworkTask = Task { [weak self] in
            let image = await Task.detached(priority: .utility) {
                guard let data = Data(base64Encoded: encoded) else { return nil as NSImage? }
                return await MediaArtworkLoader.decodeData(data)
            }.value
            guard let self, !Task.isCancelled, self.sourceRevision == revision,
                  self.artworkKey == cacheKey else { return }
            self.artworkTask = nil
            guard let image else { return }
            self.artworkCache.insert(image, for: cacheKey)
            self.artwork = image
        }
    }

    /// Ticks once a second only while something plays; paused or idle media needs no timer.
    private func updateProgressClock() {
        guard isAutomatic else { return }
        if playing && enabled {
            guard timer == nil else { return }
            let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.interpolateProgress() } }
            clock.tolerance = 0.2
            RunLoop.main.add(clock, forMode: .common)
            timer = clock
        } else {
            timer?.invalidate(); timer = nil
        }
    }

    private func interpolateProgress() {
        guard isAutomatic, enabled, hasSnapshot else { return }
        let elapsed = snapshotElapsed + max(0, Date().timeIntervalSince(snapshotDate)) * snapshotRate
        progress = min(max(0, elapsed), duration)
    }

    private func updateAppIdentity(_ bundleIdentifier: String?) {
        guard bundleIdentifier != appBundleIdentifier else { return }
        appBundleIdentifier = bundleIdentifier
        guard let bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            appName = nil; appIcon = nil
            return
        }
        appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        appIcon = SmallIconCache.fileIcon(for: url.path, pixels: 160)
    }

    private func clearAppIdentity() {
        if appBundleIdentifier != nil { appBundleIdentifier = nil }
        if appName != nil { appName = nil }
        if appIcon != nil { appIcon = nil }
    }

    func command(_ command: String) {
        guard enabled else { connect(); return }
        if isAutomatic {
            if appBundleIdentifier == SpotifyDockManager.bundleIdentifier {
                runSpotifyCommand(command)
                return
            }
            switch command {
            case "playpause":
                bridge?.send("toggle")
                playing.toggle(); snapshotElapsed = progress; snapshotDate = Date(); snapshotRate = playing ? 1 : 0
                updateProgressClock()
            case "next track": bridge?.send("next")
            case "previous track": bridge?.send("previous")
            default: bridge?.send("refresh")
            }
            return
        }
        let app = source
        let revision = sourceRevision
        Task { [weak self] in
            let result = await Self.script("tell application \"\(app)\" to \(command)")
            guard let self, self.enabled, self.source == app, self.sourceRevision == revision else { return }
            if let message = result.1 {
                self.error = message
                self.clearCurrentArtwork()
            }
            self.refresh()
        }
    }

    func seek(_ value: Double) {
        if isAutomatic {
            guard enabled else { return }
            let target = min(max(0, value), duration)
            if appBundleIdentifier == SpotifyDockManager.bundleIdentifier {
                snapshotElapsed = target; snapshotDate = Date(); progress = target
                runSpotifyCommand("set player position to \(target)")
                return
            }
            bridge?.send("seek \(target)")
            snapshotElapsed = target; snapshotDate = Date(); progress = target
            return
        }
        command("set player position to \(max(0, value))")
    }

    func refresh() {
        if isAutomatic { if enabled { bridge?.send("refresh") }; return }
        guard enabled, !polling else { return }
        let app = source
        guard app == "Music" || app == "Spotify" else {
            clearCurrentArtwork()
            return
        }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == (app == "Music" ? "com.apple.Music" : "com.spotify.client") }) else {
            title = "Open \(app) to play"
            artist = "Waiting for your music"
            playing = false
            error = nil
            clearCurrentArtwork()
            return
        }

        polling = true
        let revision = sourceRevision
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let result = await Self.script("""
            tell application "\(app)"
                if player state is stopped then return "Stopped"
                set t to current track
                return (name of t) & "␞" & (artist of t) & "␞" & (player state as text) & "␞" & (player position as text) & "␞" & (duration of t as text) & "␞" & (id of t as text)
            end tell
            """)
            defer {
                if self.sourceRevision == revision {
                    self.polling = false
                    self.refreshTask = nil
                }
            }
            guard !Task.isCancelled, self.enabled, self.source == app, self.sourceRevision == revision else { return }
            if let message = result.1 {
                error = message
                clearCurrentArtwork()
                return
            }
            let pieces = result.0.components(separatedBy: "␞")
            guard pieces.count >= 5 else {
                playing = false
                title = "Nothing playing"
                artist = "Choose a song in \(app)"
                clearCurrentArtwork()
                return
            }
            if title != pieces[0] { title = pieces[0] }
            if artist != pieces[1] { artist = pieces[1] }
            let nextPlaying = pieces[2] == "playing"
            if playing != nextPlaying { playing = nextPlaying }
            progress = Self.parseMediaNumber(pieces[3]) ?? 0
            let nextDuration = max(1, (Self.parseMediaNumber(pieces[4]) ?? 1) / (app == "Spotify" ? 1000 : 1))
            if duration != nextDuration { duration = nextDuration }
            if error != nil { error = nil }
            let identifier = pieces.count >= 6 ? pieces[5] : ""
            let key = artworkKey(source: app, title: title, artist: artist, duration: duration, identifier: identifier)
            updateArtwork(key: key, source: app, trackID: identifier)
        }
    }

    nonisolated static func script(_ source: String) async -> (String, String?) {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                var error: NSDictionary?
                let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? ""
                return (output, error?[NSAppleScript.errorMessage] as? String)
            }
        }.value
    }

    nonisolated static func scriptData(_ source: String) async -> (Data?, String?) {
        await Task.detached(priority: .utility) {
            guard let script = NSAppleScript(source: source) else {
                return (nil, "Unable to create artwork script")
            }
            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            let data = descriptor.data
            return (data.isEmpty ? nil : data, error?[NSAppleScript.errorMessage] as? String)
        }.value
    }

    nonisolated static func parseMediaNumber(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed) { return number }
        guard trimmed.contains(","), !trimmed.contains(".") else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    private func runSpotifyCommand(_ command: String) {
        let revision = sourceRevision
        if command == "playpause" {
            playing.toggle()
            snapshotElapsed = progress
            snapshotDate = Date()
            snapshotRate = playing ? 1 : 0
            updateProgressClock()
        }
        Task { [weak self] in
            let result = await Self.script("tell application \"Spotify\" to \(command)")
            guard let self, self.enabled, self.isAutomatic,
                  self.sourceRevision == revision,
                  self.appBundleIdentifier == SpotifyDockManager.bundleIdentifier else { return }
            if let message = result.1 {
                self.error = message
                self.bridge?.send("refresh")
                return
            }
            self.error = nil
            try? await Task.sleep(for: .milliseconds(180))
            self.bridge?.send("refresh")
            self.refreshSpotifyTiming(expectedTitle: self.title, replacingExistingTask: true)
        }
    }

    private func refreshSpotifyTiming(expectedTitle: String, replacingExistingTask: Bool = false) {
        if replacingExistingTask {
            spotifyTimingTask?.cancel()
            spotifyTimingTask = nil
        }
        guard spotifyTimingTask == nil else { return }
        let revision = sourceRevision
        spotifyTimingTask = Task { [weak self] in
            guard let self else { return }
            let result = await Self.script("""
            tell application "Spotify"
                if player state is stopped then return ""
                set t to current track
                return (name of t) & "␞" & (player state as text) & "␞" & (player position as text) & "␞" & (duration of t as text)
            end tell
            """)
            defer { if self.sourceRevision == revision { self.spotifyTimingTask = nil } }
            guard !Task.isCancelled, self.enabled, self.isAutomatic,
                  self.sourceRevision == revision,
                  self.appBundleIdentifier == SpotifyDockManager.bundleIdentifier,
                  result.1 == nil else { return }
            let pieces = result.0.components(separatedBy: "␞")
            guard pieces.count == 4, pieces[0] == expectedTitle,
                  let elapsed = Self.parseMediaNumber(pieces[2]),
                  let milliseconds = Self.parseMediaNumber(pieces[3]) else { return }
            self.playing = pieces[1] == "playing"
            self.duration = max(1, milliseconds / 1000)
            self.snapshotElapsed = min(max(0, elapsed), self.duration)
            self.snapshotDate = Date()
            self.snapshotRate = self.playing ? 1 : 0
            self.progress = self.snapshotElapsed
            self.updateProgressClock()
        }
    }

    private func artworkKey(source: String, title: String, artist: String, duration: Double, identifier: String) -> String {
        let identity = identifier.isEmpty ? "\(title)\u{1F}\(artist)\u{1F}\(duration)" : identifier
        return "\(source)\u{1E}\(identity)"
    }

    private func updateArtwork(key: String, source: String, trackID: String) {
        let now = Date()
        artworkRetryAt = artworkRetryAt.filter { $0.value > now }
        if artworkKey == key {
            if artwork != nil || artworkTask != nil {
                return
            }
            if let retryAt = artworkRetryAt[key], retryAt > Date() {
                return
            }
        } else {
            artworkTask?.cancel()
            artworkTask = nil
            artworkKey = key
            artwork = nil
        }

        if let cached = artworkCache.image(for: key) {
            artworkRetryAt.removeValue(forKey: key)
            artwork = cached
            return
        }
        if let retryAt = artworkRetryAt[key], retryAt > Date() {
            return
        }

        let revision = sourceRevision
        artworkTask = Task { [weak self] in
            let image = await MediaArtworkLoader.load(source: source, trackID: trackID)
            guard let self,
                  !Task.isCancelled,
                  self.enabled,
                  self.source == source,
                  self.sourceRevision == revision,
                  self.artworkKey == key else {
                return
            }
            self.artworkTask = nil
            guard let image else {
                self.artworkRetryAt[key] = Date().addingTimeInterval(30)
                return
            }
            self.artworkRetryAt.removeValue(forKey: key)
            self.artworkCache.insert(image, for: key)
            self.artwork = image
        }
    }

    private func clearCurrentArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkKey = nil
        if artwork != nil { artwork = nil }
    }

}

struct MediaView: View {
    @StateObject private var media = MediaController.shared
    @ObservedObject private var clock = MediaProgress.shared
    @StateObject private var system = SystemMonitor.shared
    @State private var showOutputs = false
    var body: some View {
        ScrollView { VStack(spacing: 22) {
            Picker("Player", selection: $media.source) { Text("Any Player").tag("Automatic"); Text("Apple Music").tag("Music"); Text("Spotify").tag("Spotify") }.pickerStyle(.segmented).labelsHidden().fixedSize().onChange(of: media.source) { _, _ in if media.enabled { media.refresh() } }
            MediaArtworkView(size: 220, cornerRadius: 12, showsAppBadge: true).shadow(color: .black.opacity(0.25), radius: 18, y: 8).padding(.top, 8)
            VStack(spacing: 4) { Text(media.title).font(.title2.weight(.semibold)).lineLimit(1); Text(media.artist).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                if media.isAutomatic, let name = media.appName { Label("Playing in \(name)", systemImage: "play.circle").font(.callout).foregroundStyle(.tertiary).padding(.top, 2) } }
            VStack(spacing: 5) { Slider(value: Binding(get: { min(media.progress, media.duration) }, set: { media.seek($0) }), in: 0...max(1, media.duration)).disabled(!media.enabled); HStack { Text(time(media.progress)); Spacer(); Text(time(media.duration)) }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }.frame(maxWidth: 410)
            HStack(spacing: 34) { Button { media.command("previous track") } label: { Image(systemName: "backward.end.fill") }; Button { media.command("playpause") } label: { Image(systemName: media.playing ? "pause.fill" : "play.fill").font(.system(size: 25)).frame(width: 54, height: 54).background(.fill.tertiary, in: Circle()) }; Button { media.command("next track") } label: { Image(systemName: "forward.end.fill") } }.buttonStyle(.plain).font(.title2)
            HStack { Image(systemName: "speaker.fill"); Slider(value: Binding(get: { Double(system.volume) }, set: { system.setVolume(Float($0)) }), in: 0...1); Image(systemName: "speaker.wave.3.fill") }.foregroundStyle(.secondary).frame(maxWidth: 300)
            Button { showOutputs.toggle() } label: { Label("Audio Output", systemImage: "airplay.audio") }.popover(isPresented: $showOutputs) { AudioDevicesView().frame(width: 400, height: 380) }
            if media.source == "Spotify" || (media.isAutomatic && media.appBundleIdentifier == SpotifyDockManager.bundleIdentifier) {
                Button { SpotifyDockManager.shared.focusSpotify() } label: { Label("Open Spotify", systemImage: "arrow.up.forward.app") }
                if SpotifyDockManager.shared.isPrepared {
                    Text("Spotify opens on demand while staying out of the Dock.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if media.isAutomatic, let name = media.appName, media.appBundleIdentifier != SpotifyDockManager.bundleIdentifier {
                Button { NowPlayingAppOpener.open(bundleIdentifier: media.appBundleIdentifier) } label: { Label("Open \(name)", systemImage: "arrow.up.forward.app") }
            }
            if media.isAutomatic { Text("Follows music and video from any app, including browsers, Spotify and Apple Music.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if !media.enabled && !media.isAutomatic { Button("Connect Player") { media.connect() }.buttonStyle(.borderedProminent).controlSize(.large); Text("macOS may ask to allow control of your music app.").font(.callout).foregroundStyle(.secondary) }
            if let error = media.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private func time(_ v: Double) -> String { String(format: "%d:%02d", Int(v) / 60, Int(v) % 60) }
}
