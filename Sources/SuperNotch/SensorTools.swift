import SwiftUI
import AppKit
import AVFoundation
import Speech
import UniformTypeIdentifiers

private final class CameraPipeline: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.supernotch.camera")
    func start(completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                if session.inputs.isEmpty {
                    guard let device = AVCaptureDevice.default(for: .video) else { completion("No camera is available on this Mac."); return }
                    let input = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    session.sessionPreset = .high
                    guard session.canAddInput(input) else { session.commitConfiguration(); completion("This camera cannot be opened."); return }
                    session.addInput(input); session.commitConfiguration()
                }
                session.startRunning()
                completion(session.isRunning ? nil : "The camera did not start. Another app may be using it.")
            } catch { completion(error.localizedDescription) }
        }
    }
    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
}

@MainActor
private final class SensorToolsStore: NSObject, ObservableObject, AVAudioRecorderDelegate {
    let camera = CameraPipeline()
    @Published var cameraRunning = false
    @Published var cameraStarting = false
    @Published var recording = false
    @Published var seconds: TimeInterval = 0
    @Published var level: Float = 0
    @Published var audioURL: URL?
    @Published var transcript = ""
    @Published var transcribing = false
    @Published var message = ""
    @Published var allowNetwork = false
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var cameraGeneration = UUID()
    private var recordingGeneration = UUID()
    private var speechGeneration = UUID()
    var timeText: String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate), name: NSApplication.willTerminateNotification, object: nil)
        if let path = UserDefaults.standard.string(forKey: "sensor.lastRecording"), FileManager.default.fileExists(atPath: path) { audioURL = URL(fileURLWithPath: path) }
    }
    func startCamera() {
        guard !cameraRunning, !cameraStarting else { return }
        cameraStarting = true
        let token = UUID(); cameraGeneration = token
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard token == cameraGeneration else { return }
            guard granted else { cameraStarting = false; message = "Camera access was declined. Enable SuperNotch in System Settings → Privacy & Security → Camera."; return }
            camera.start { [weak self] error in
                Task { @MainActor in
                    guard let self, token == self.cameraGeneration else { return }
                    self.cameraStarting = false; self.cameraRunning = error == nil
                    if let error { self.message = error }
                }
            }
        }
    }
    func stopCamera() { cameraGeneration = UUID(); cameraStarting = false; cameraRunning = false; camera.stop() }
    func startRecording() {
        guard !recording else { return }
        let token = UUID(); recordingGeneration = token
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard token == recordingGeneration else { return }
            guard granted else { message = "Microphone access was declined. Enable SuperNotch in System Settings → Privacy & Security → Microphone."; return }
            do {
                let directory = SuperNotchStorage.baseDirectory.appendingPathComponent("Recordings", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = "Voice memo \(Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)).replacingOccurrences(of: "/", with: "-"))"
                let url = directory.appendingPathComponent(name + "-" + UUID().uuidString.prefix(4) + ".m4a")
                let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
                recorder.delegate = self; recorder.isMeteringEnabled = true
                guard recorder.prepareToRecord(), recorder.record() else { message = "The microphone could not begin recording."; return }
                self.recorder = recorder; recording = true; seconds = 0; transcript = ""; message = ""
                timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let recorder = self.recorder else { return }
                        self.seconds = recorder.currentTime; recorder.updateMeters()
                        self.level = max(0, min(1, (recorder.averagePower(forChannel: 0) + 55) / 55))
                    }
                }
            } catch { message = "Recording failed: \(error.localizedDescription)" }
        }
    }
    func stopRecording() {
        recordingGeneration = UUID()
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop(); self.recorder = nil; recording = false; timer?.invalidate(); timer = nil; level = 0
        if FileManager.default.fileExists(atPath: url.path) {
            audioURL = url; UserDefaults.standard.set(url.path, forKey: "sensor.lastRecording")
            FileShelfStore.shared.add(urls: [url]); message = "Voice memo saved and added to your File Shelf."
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.stopRecording(); self.message = "Audio encoding failed: \(error?.localizedDescription ?? "Unknown error")" }
    }
    func chooseAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { audioURL = url; transcript = ""; message = "" }
    }
    func transcribe() {
        guard let url = audioURL, !recording, !transcribing else { return }
        transcribing = true; transcript = ""; message = ""
        let token = UUID(); speechGeneration = token
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            Task { @MainActor in
                guard let self, token == self.speechGeneration else { return }
                guard authorization == .authorized else { self.transcribing = false; self.message = "Speech recognition access was declined or restricted. Check System Settings → Privacy & Security → Speech Recognition."; return }
                guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else { self.transcribing = false; self.message = "Speech recognition is unavailable for your current language. Try again after checking the system language and downloaded speech support."; return }
                guard recognizer.supportsOnDeviceRecognition || self.allowNetwork else {
                    self.transcribing = false; self.message = "On-device transcription is unavailable for your language or Mac. You can explicitly allow Apple’s online speech service below, then retry."; return
                }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.requiresOnDeviceRecognition = !self.allowNetwork
                request.shouldReportPartialResults = true
                self.speechRecognizer = recognizer
                self.speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self, token == self.speechGeneration else { return }
                        if let result { self.transcript = result.bestTranscription.formattedString }
                        if result?.isFinal == true || error != nil {
                            self.transcribing = false; self.speechTask = nil; self.speechRecognizer = nil
                            if let error { self.message = "Transcription stopped: \(error.localizedDescription)" }
                            else { self.message = "Transcription complete. Copy the text or save it to Notes." }
                        }
                    }
                }
            }
        }
    }
    func cancelTranscription() { speechGeneration = UUID(); speechTask?.cancel(); speechTask = nil; speechRecognizer = nil; transcribing = false }
    @objc private func applicationWillTerminate() { cleanup() }
    func cleanup() { stopCamera(); stopRecording(); cancelTranscription() }
}

private final class CameraPreviewNSView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); wantsLayer = true
        preview.videoGravity = .resizeAspectFill; layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layout() {
        super.layout(); CATransaction.begin(); CATransaction.setDisableActions(true); preview.frame = bounds; CATransaction.commit()
        if let connection = preview.connection, connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true }
    }
}
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraPreviewNSView { let view = CameraPreviewNSView(frame: .zero); view.preview.session = session; return view }
    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) { nsView.preview.session = session }
    static func dismantleNSView(_ nsView: CameraPreviewNSView, coordinator: ()) { nsView.preview.session = nil }
}

struct SensorToolsView: View {
    @StateObject private var store = SensorToolsStore()
    @State private var tool = "Mirror"
    init(initialTool: String = "") { _tool = State(initialValue: initialTool == "Voice notes" ? "Voice & text" : initialTool == "Emoji picker" ? "Emoji" : "Mirror") }
    @State private var emojiSearch = ""
    @State private var copiedEmoji = ""
    private let emoji: [(String, String)] = [
        ("😀", "happy smile"), ("😃", "happy joy"), ("😁", "grin"), ("😂", "laugh tears"), ("🥹", "tears grateful"), ("😊", "blush happy"), ("🥰", "love hearts"), ("😍", "love eyes"), ("😎", "cool glasses"), ("🤔", "thinking"), ("🫡", "salute"), ("🤩", "star excited"), ("🥳", "party"), ("😴", "sleep"), ("😭", "cry sad"), ("🤯", "mind blown"), ("👋", "wave hello"), ("👏", "clap"), ("🙌", "celebrate hands"), ("👍", "thumbs yes"), ("👎", "thumbs no"), ("🤝", "handshake"), ("🙏", "thanks please pray"), ("💪", "muscle strong"), ("❤️", "heart love red"), ("🧡", "heart orange"), ("💛", "heart yellow"), ("💚", "heart green"), ("💙", "heart blue"), ("💜", "heart purple"), ("✨", "sparkles"), ("🔥", "fire"), ("⭐️", "star"), ("🎉", "party celebration"), ("🎯", "target goal"), ("🚀", "rocket launch"), ("💡", "idea light"), ("✅", "check done"), ("❌", "cross no"), ("⚠️", "warning"), ("📌", "pin"), ("📎", "paperclip"), ("📝", "note writing"), ("💻", "computer laptop"), ("☕️", "coffee"), ("🍕", "pizza"), ("🌈", "rainbow"), ("🌞", "sun"), ("🌙", "moon"), ("🐶", "dog"), ("🐱", "cat"), ("🌱", "plant"), ("🎵", "music"), ("🎮", "game"), ("📸", "camera"), ("🎙️", "microphone")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Tool", selection: $tool) { Text("Mirror").tag("Mirror"); Text("Voice & text").tag("Voice & text"); Text("Emoji").tag("Emoji") }.pickerStyle(.segmented).labelsHidden().fixedSize().frame(maxWidth: .infinity)
            switch tool { case "Mirror": mirror; case "Voice & text": voice; default: emojiPicker }
            if !store.message.isEmpty { InlineMessage(text: store.message) }
        }.padding(20).onDisappear { store.cleanup() }.onChange(of: tool) { _, _ in store.cleanup() }
    }
    private var mirror: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.quinary)
                if store.cameraRunning || store.cameraStarting {
                    CameraPreview(session: store.camera.session).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if store.cameraStarting { ProgressView("Starting camera…").padding().background(.ultraThinMaterial, in: Capsule()) }
                } else {
                    VStack(spacing: 12) { Image(systemName: "camera.aperture").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary); Text("Camera Off").font(.headline); Text("Your camera turns on only when you open the mirror.").font(.caption).foregroundStyle(.secondary) }.padding()
                }
            }.frame(minHeight: 260, maxHeight: 420)
            HStack {
                Label(store.cameraRunning ? "Camera on · mirrored preview" : "Camera off", systemImage: store.cameraRunning ? "circle.fill" : "camera").font(.caption).foregroundStyle(store.cameraRunning ? .green : .secondary)
                Spacer()
                Button(store.cameraRunning || store.cameraStarting ? "Close Mirror" : "Open Mirror") { if store.cameraRunning || store.cameraStarting { store.stopCamera() } else { store.startCamera() } }.buttonStyle(.borderedProminent)
            }
        }
    }
    private var voice: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text("Voice memo").font(.headline); Text("Record locally, then turn speech into text.").font(.caption).foregroundStyle(.secondary) }
                Spacer(); Text(store.timeText).font(.system(.title2, design: .monospaced)).foregroundStyle(store.recording ? .red : .primary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.fill.tertiary)
                    Capsule().fill(store.recording ? Color.red.gradient : Color.gray.gradient).frame(width: max(5, geometry.size.width * CGFloat(store.level)))
                }
            }.frame(height: 8)
            HStack {
                Button { store.recording ? store.stopRecording() : store.startRecording() } label: { Label(store.recording ? "Stop & save" : "Record", systemImage: store.recording ? "stop.fill" : "mic.fill") }.buttonStyle(.borderedProminent).tint(.red).disabled(store.transcribing)
                Button("Open audio…") { store.chooseAudio() }.disabled(store.recording || store.transcribing)
                Spacer()
            }
            if let url = store.audioURL {
                HStack {
                    Image(systemName: "waveform").foregroundStyle(.pink)
                    Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "play.circle") }.help("Play in default audio app")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }.help("Show recording in Finder")
                }.rowStyle()
            }
            Divider()
            HStack {
                Label("Transcription", systemImage: "text.bubble").font(.headline); Spacer()
                if store.transcribing { ProgressView().controlSize(.small); Button("Cancel") { store.cancelTranscription() } }
                else { Button("Transcribe audio") { store.transcribe() }.disabled(store.audioURL == nil || store.recording) }
            }
            Toggle("Allow Apple’s online speech service", isOn: $store.allowNetwork).font(.caption).disabled(store.transcribing)
            Text(store.allowNetwork ? "Audio may be sent to Apple for transcription. Uses your current system language." : "On-device only. Availability depends on your Mac and system language.").font(.caption2).foregroundStyle(.secondary)
            if !store.transcript.isEmpty {
                ScrollView { Text(store.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(height: 120).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
                HStack {
                    Button("Copy text") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.transcript, forType: .string) }
                    Button("Save to Notes") { ProductivityStore.shared.saveNote(store.transcript); store.message = "Transcription saved to Notes." }
                }
            } else { Text("Short, clear recordings give the best results. Speech service limits may stop longer transcriptions.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4) }
        }
    }
    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { TextField("Search emoji…", text: $emojiSearch).textFieldStyle(.roundedBorder); Button("All symbols…") { NSApp.orderFrontCharacterPalette(nil) } }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                    ForEach(emoji.filter { emojiSearch.isEmpty || $0.1.localizedCaseInsensitiveContains(emojiSearch) || $0.0 == emojiSearch }, id: \.0) { item in
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.0, forType: .string); copiedEmoji = item.0 } label: { Text(item.0).font(.system(size: 27)).frame(width: 42, height: 42).background(copiedEmoji == item.0 ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.fill.quinary), in: RoundedRectangle(cornerRadius: 8, style: .continuous)) }.buttonStyle(.plain).help(item.1)
                    }
                }
            }.frame(minHeight: 260, maxHeight: .infinity)
            Text(copiedEmoji.isEmpty ? "Click an emoji to copy it. Open All symbols for the complete macOS library." : "\(copiedEmoji) copied. Paste it anywhere.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
