import SwiftUI
import AppKit
import ApplicationServices
import Darwin

@MainActor final class CommandToolsModel: ObservableObject {
    static let shared = CommandToolsModel()
    @Published var queryText = ""
    @Published var results: [URL] = []
    @Published var searching = false
    @Published var command = ""
    @Published var output = ""
    @Published var running = false
    @Published var workingDirectory = FileManager.default.homeDirectoryForCurrentUser
    @Published var message: String?
    @Published var targetPID: Int32 = 0
    private let query = NSMetadataQuery()
    private var queryObservers: [NSObjectProtocol] = []
    private var appObserver: NSObjectProtocol?
    private var debounce: Task<Void, Never>?
    private var process: CommandChildProcess?
    private var outputPipe: Pipe?
    private var applications: [URL] = []

    init() {
        for directory in ["/Applications", "/System/Applications", "/System/Applications/Utilities", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
            applications += ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        }
        applications.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        results = applications
        for notification in [NSNotification.Name.NSMetadataQueryDidFinishGathering, NSNotification.Name.NSMetadataQueryDidUpdate] {
            queryObservers.append(NotificationCenter.default.addObserver(forName: notification, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.receiveSearch() }
            })
        }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { targetPID = app.processIdentifier }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.targetPID = app.processIdentifier }
        }
    }
    var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
    func search() {
        debounce?.cancel()
        query.stop()
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        results = applications.filter { text.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(text) }
        searching = !text.isEmpty
        guard !text.isEmpty else { return }
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            query.searchScopes = [NSMetadataQueryUserHomeScope, NSMetadataQueryLocalComputerScope]
            query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
            query.start()
        }
    }
    private func receiveSearch() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { searching = false; return }
        var urls = applications.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(text) }
        for index in 0..<min(query.resultCount, 150) {
            if let item = query.result(at: index) as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                let url = URL(fileURLWithPath: path)
                if !urls.contains(url) { urls.append(url) }
            }
        }
        results = urls
        searching = query.isGathering
    }
    func open(_ url: URL) { if !NSWorkspace.shared.open(url) { message = "Could not open \(url.lastPathComponent)." } }
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.directoryURL = workingDirectory; panel.prompt = "Use Directory"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.workingDirectory = url }
        }
    }
    func run() {
        guard !running, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pipe = Pipe()
        output = "$ \(command)\n"
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendOutput(text) }
        }
        do {
            let task = try CommandChildProcess(command: command, directory: workingDirectory.path, output: pipe.fileHandleForWriting.fileDescriptor) { [weak self] status in
                guard let self else { return }
                self.appendOutput("\n[Process exited with status \(status)]\n")
                self.running = false
                self.process = nil
                self.outputPipe = nil
            }
            try? pipe.fileHandleForWriting.close()
            process = task; outputPipe = pipe; running = true
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            message = error.localizedDescription
            appendOutput("\n\(error.localizedDescription)")
        }
    }
    func runPaletteCommand(_ value: String, workingDirectory path: String?) {
        guard !running else { message = "Another command is already running."; return }
        command = value
        if let path {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                workingDirectory = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        run()
    }
    private func appendOutput(_ value: String) {
        output += value
        if output.count > 100_000 { output = "[Earlier output truncated]\n" + String(output.suffix(90_000)) }
    }
    func cancel() {
        guard let process else { return }
        process.cancel()
        message = "Stopping the command and its process group."
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        message = "Enable SuperNotch in Privacy & Security → Accessibility, then retry the layout."
    }
    func snap(_ layout: String) {
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        guard targetPID != 0, let target = NSRunningApplication(processIdentifier: targetPID), !target.isTerminated else { message = "Choose a running app first."; return }
        let app = AXUIElementCreateApplication(targetPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { message = "The selected app has no accessible focused window."; return }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main!
        let frame = screen.visibleFrame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        var rect = CGRect(x: frame.minX, y: primaryTop - frame.maxY, width: frame.width, height: frame.height)
        switch layout {
        case "Left half": rect.size.width /= 2
        case "Right half": rect.origin.x += rect.width / 2; rect.size.width /= 2
        case "Center": rect = rect.insetBy(dx: rect.width * 0.15, dy: rect.height * 0.12)
        default: break
        }
        var point = rect.origin; var size = rect.size
        guard let pointValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        let move = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        let resize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        // Some apps adjust their position after a resize; apply the final origin again.
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pointValue)
        if move == .success && resize == .success { target.activate(options: []); message = "Applied \(layout.lowercased()) to \(target.localizedName ?? "window")." }
        else { message = "The app could not apply this layout. Fixed-size or full-screen windows may reject resizing." }
    }
}

@MainActor struct CommandToolsView: View {
    @StateObject private var model = CommandToolsModel.shared
    @State private var mode = "Launcher"
    let initialTool: String
    init(initialTool: String = "") { self.initialTool = initialTool; _mode = State(initialValue: Self.modeName(initialTool)) }
    init() { self.initialTool = "" }
    private static func modeName(_ value: String) -> String {
        switch value { case "Command runner": "Terminal"; case "Window snap": "Window snap"; case "Command palette": "Palette"; default: "Launcher" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Tool", selection: $mode) { Text("Launcher").tag("Launcher"); Text("Palette").tag("Palette"); Text("Terminal").tag("Terminal"); Text("Window Snap").tag("Window snap") }.pickerStyle(.segmented).labelsHidden().fixedSize().frame(maxWidth: .infinity)
            switch mode { case "Palette": PaletteCommandsView(); case "Terminal": terminal; case "Window snap": snap; default: launcher }
            if let message = model.message {
                InlineMessage(text: message) { model.message = nil }
            }
        }.padding(20)
            .onChange(of: initialTool) { _, value in mode = Self.modeName(value) }
    }
    private var launcher: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find applications and indexed files…", text: $model.queryText).textFieldStyle(.plain).onChange(of: model.queryText) { _, _ in model.search() }.onSubmit { if let first = model.results.first { model.open(first) } }
                if model.searching { ProgressView().controlSize(.small) }
            }.padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            Text(model.queryText.isEmpty ? "Applications" : "Spotlight Results · \(model.results.count)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.results, id: \.path) { url in
                        HStack(spacing: 11) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 29, height: 29)
                            VStack(alignment: .leading, spacing: 3) { Text(url.deletingPathExtension().lastPathComponent).font(.body.weight(.medium)); Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            Spacer()
                            Button { FileShelfStore.shared.add(urls: [url]); model.message = "Added \(url.lastPathComponent) to the shelf." } label: { Image(systemName: "tray.and.arrow.down") }.help("Add to shelf")
                            Button("Open") { model.open(url) }
                        }.rowStyle(padding: 8).onTapGesture(count: 2) { model.open(url) }
                    }
                }
                if model.results.isEmpty { Text("No indexed matches. Spotlight results depend on your Mac’s indexing and permissions.").foregroundStyle(.secondary).padding(30) }
            }
        }
    }
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "folder"); Text(model.workingDirectory.path).font(.caption).lineLimit(1).truncationMode(.middle); Spacer(); Button("Choose folder") { model.chooseDirectory() }.disabled(model.running) }
            HStack {
                Text("❯").foregroundStyle(.green).font(.system(.body, design: .monospaced))
                TextField("Enter a shell command", text: $model.command).font(.system(.body, design: .monospaced)).textFieldStyle(.plain).onSubmit { model.run() }.disabled(model.running)
                if model.running { Button("Stop", role: .destructive) { model.cancel() } } else { Button("Run") { model.run() }.buttonStyle(.borderedProminent).disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }.padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            ScrollView([.horizontal, .vertical]) {
                Text(model.output.isEmpty ? "Command output appears here." : model.output).font(.system(size: 11, design: .monospaced)).foregroundStyle(model.output.isEmpty ? .secondary : .primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
            HStack {
                Text("zsh command runner · no interactive input · up to 100,000 output characters").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Clear output") { model.output = "" }.disabled(model.running)
            }
        }
    }
    private var snap: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Arrange another app’s focused window on the display under your pointer.").font(.callout).foregroundStyle(.secondary)
            Picker("Target app", selection: $model.targetPID) {
                Text("Choose an application").tag(Int32(0))
                ForEach(model.runningApps, id: \.processIdentifier) { app in Text(app.localizedName ?? "Application").tag(app.processIdentifier) }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(["Left half", "Right half", "Fill display", "Center"], id: \.self) { layout in
                    Button { model.snap(layout) } label: {
                        VStack(spacing: 12) {
                            Image(systemName: layout == "Left half" ? "rectangle.lefthalf.filled" : layout == "Right half" ? "rectangle.righthalf.filled" : layout == "Center" ? "rectangle.center.inset.filled" : "rectangle.fill").font(.system(size: 28)).foregroundStyle(.tint)
                            Text(layout).font(.body.weight(.medium))
                        }.frame(maxWidth: .infinity).padding(8).cardStyle().contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
            }
            Button("Enable Accessibility access…") { model.requestAccessibility() }
            Text("Window management requires Accessibility permission. Full-screen and fixed-size windows may not support these layouts.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// Launches an isolated process group so cancellation reaches pipelines and child commands.
/// Detached processes which create a new session are outside this command runner's scope.
private final class CommandChildProcess: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    init(command: String, directory: String, output: Int32, completion: @escaping @MainActor (Int32) -> Void) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var args: [UnsafeMutablePointer<CChar>?] = (["/bin/zsh", "-lc", command] as [String]).map { value in value.withCString { strdup($0) } } + [nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { args.forEach { free($0) }; environment.forEach { free($0) } }
        var child: pid_t = 0
        let error = posix_spawn(&child, "/bin/zsh", &actions, &attributes, &args, &environment)
        guard error == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(error)) }
        pid = child
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            // WNOWAIT keeps the process ID reserved until cancellation escalation is complete.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            lock.lock()
            let shouldEscalate = cancelled
            if !shouldEscalate { finished = true }
            lock.unlock()
            if shouldEscalate {
                // The shell may exit before its children; the unreaped PID still identifies our group.
                _ = kill(-pid, SIGTERM)
                usleep(250_000)
                _ = kill(-pid, SIGKILL)
            }
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            lock.lock(); finished = true; lock.unlock()
            let exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            Task { @MainActor in completion(exitStatus) }
        }
    }
    func cancel() {
        lock.lock()
        guard !finished, !cancelled else { lock.unlock(); return }
        cancelled = true
        _ = kill(-pid, SIGTERM)
        lock.unlock()
        // A shell may ignore SIGTERM. Escalate while its PID is still reserved by waitid.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock(); defer { lock.unlock() }
            if !finished { _ = kill(-pid, SIGKILL) }
        }
    }
}
