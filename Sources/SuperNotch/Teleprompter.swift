import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class TeleprompterStore: ObservableObject {
    static let shared = TeleprompterStore()
    @Published var script = UserDefaults.standard.string(forKey: "teleprompter.script") ?? "" { didSet { UserDefaults.standard.set(script, forKey: "teleprompter.script") } }
    @Published var speed = UserDefaults.standard.object(forKey: "teleprompter.speed") as? Double ?? 45 { didSet { UserDefaults.standard.set(speed, forKey: "teleprompter.speed") } }
    @Published var fontSize = UserDefaults.standard.object(forKey: "teleprompter.fontSize") as? Double ?? 36 { didSet { UserDefaults.standard.set(fontSize, forKey: "teleprompter.fontSize") } }
    @Published var mirrored = UserDefaults.standard.bool(forKey: "teleprompter.mirrored") { didSet { UserDefaults.standard.set(mirrored, forKey: "teleprompter.mirrored") } }
    @Published var playing = false
    @Published var resetToken = 0
    @Published var readerOpen = false
    @Published var message = ""
    private init() {
        if !speed.isFinite || !(10...180).contains(speed) { speed = 45 }
        if !fontSize.isFinite || !(20...80).contains(fontSize) { fontSize = 36 }
    }
    func reset() { playing = false; resetToken += 1 }
    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { message = "The clipboard contains no text."; return }
        script = text; reset(); message = "Script replaced with clipboard text."
    }
    func importText() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { script = try String(contentsOf: url, encoding: .utf8); reset(); message = "Loaded \(url.lastPathComponent)." }
        catch { message = "Could not read this UTF-8 text file: \(error.localizedDescription)" }
    }
}

private final class PromptScrollView: NSScrollView {
    var didLayout: (() -> Void)?
    override func layout() { super.layout(); didLayout?() }
}

private struct PromptScroller: NSViewRepresentable {
    let script: String
    let fontSize: Double
    let speed: Double
    let playing: Bool
    let resetToken: Int
    let reachedEnd: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PromptScrollView(); scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = false; text.drawsBackground = false
        text.isRichText = false; text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.textContainerInset = NSSize(width: 24, height: 36)
        scroll.documentView = text
        context.coordinator.scroll = scroll; context.coordinator.text = text
        scroll.didLayout = { [weak coordinator = context.coordinator] in coordinator?.layoutChanged() }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.speed = speed; coordinator.reachedEnd = reachedEnd
        if coordinator.script != script || coordinator.fontSize != fontSize {
            coordinator.script = script; coordinator.fontSize = fontSize
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = fontSize * 0.34; paragraph.alignment = .left
            let attributed = NSAttributedString(string: script, attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
            coordinator.text?.textStorage?.setAttributedString(attributed)
            coordinator.resizeText()
        }
        if coordinator.resetToken != resetToken {
            coordinator.resetToken = resetToken; scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        }
        coordinator.setPlaying(playing)
    }
    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.setPlaying(false) }
    @MainActor final class Coordinator {
        weak var scroll: NSScrollView?
        weak var text: NSTextView?
        var script = ""
        var fontSize: Double = 0
        var speed: Double = 45
        var resetToken = -1
        var reachedEnd: () -> Void = {}
        private var timer: Timer?
        private var lastTick = Date()
        private var previousWidth: CGFloat = 0
        private var previousHeight: CGFloat = 0
        private var resizing = false
        func layoutChanged() {
            guard let scroll, !resizing else { return }
            if scroll.contentSize.width != previousWidth || scroll.contentSize.height != previousHeight { resizeText() }
        }
        func resizeText() {
            guard let scroll, let text, let container = text.textContainer, let manager = text.layoutManager else { return }
            guard !resizing else { return }
            resizing = true; defer { resizing = false }
            let width = max(1, scroll.contentSize.width)
            previousHeight = scroll.contentSize.height
            previousWidth = width
            text.setFrameSize(NSSize(width: width, height: max(text.frame.height, scroll.contentSize.height)))
            container.containerSize = NSSize(width: max(1, width - text.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
            manager.ensureLayout(for: container)
            let height = manager.usedRect(for: container).height + text.textContainerInset.height * 2 + scroll.contentSize.height * 0.65
            text.setFrameSize(NSSize(width: width, height: max(height, scroll.contentSize.height)))
        }
        func setPlaying(_ playing: Bool) {
            if let scroll, scroll.contentSize.width != previousWidth { resizeText() }
            guard playing else { timer?.invalidate(); timer = nil; return }
            guard timer == nil else { return }
            lastTick = Date()
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        private func tick() {
            guard let scroll, let text else { setPlaying(false); return }
            if scroll.contentSize.width != previousWidth { resizeText() }
            let now = Date(); let delta = min(0.2, now.timeIntervalSince(lastTick)); lastTick = now
            let maximum = max(0, text.frame.height - scroll.contentSize.height)
            let next = min(maximum, scroll.contentView.bounds.origin.y + speed * delta)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: next)); scroll.reflectScrolledClipView(scroll.contentView)
            if next >= maximum { setPlaying(false); reachedEnd() }
        }
    }
}

@MainActor private final class TeleprompterWindow: NSObject, NSWindowDelegate {
    static let shared = TeleprompterWindow()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "SuperNotch Teleprompter"; window.backgroundColor = .black
            window.minSize = NSSize(width: 500, height: 420); window.level = .floating; window.isReleasedWhenClosed = false
            window.collectionBehavior = [.fullScreenPrimary]; window.delegate = self
            window.contentView = NSHostingView(rootView: TeleprompterReader().preferredColorScheme(.dark)); window.center(); self.window = window
        }
        TeleprompterStore.shared.readerOpen = true
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { TeleprompterStore.shared.playing = false; TeleprompterStore.shared.readerOpen = false }
    func fullscreen() { window?.toggleFullScreen(nil) }
}

private struct PromptControls: View {
    @ObservedObject var store = TeleprompterStore.shared
    var body: some View {
        HStack(spacing: 12) {
            Button { store.playing.toggle() } label: { Label(store.playing ? "Pause" : "Play", systemImage: store.playing ? "pause.fill" : "play.fill") }.buttonStyle(.borderedProminent).tint(.orange).disabled(store.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button { store.reset() } label: { Image(systemName: "backward.end.fill") }.help("Return to top")
            Spacer()
            Toggle("Mirror", isOn: $store.mirrored).toggleStyle(.checkbox)
        }
    }
}

private struct PromptDisplay: View {
    @ObservedObject var store = TeleprompterStore.shared
    var standalone = false
    var body: some View {
        ZStack(alignment: .leading) {
            Color.black
            if store.script.isEmpty { VStack(spacing: 12) { Image(systemName: "text.alignleft").font(.largeTitle); Text("Add your script to begin").font(.headline) }.foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                PromptScroller(script: store.script, fontSize: store.fontSize, speed: store.speed, playing: store.playing && (standalone || !store.readerOpen), resetToken: store.resetToken) { store.playing = false }.scaleEffect(x: store.mirrored ? -1 : 1, y: 1)
                Image(systemName: "arrowtriangle.right.fill").font(.system(size: 9)).foregroundStyle(.orange).padding(.leading, 5).allowsHitTesting(false)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct TeleprompterReader: View {
    @ObservedObject private var store = TeleprompterStore.shared
    var body: some View {
        VStack(spacing: 14) {
            HStack { Label("Teleprompter", systemImage: "text.alignleft").font(.headline); Spacer(); Button("Full screen") { TeleprompterWindow.shared.fullscreen() } }
            PromptDisplay(standalone: true)
            PromptControls()
            HStack { Text("Speed").font(.caption); Slider(value: $store.speed, in: 10...180); Text("\(Int(store.speed)) pt/s").font(.caption.monospacedDigit()).frame(width: 66) }
        }.padding(20).background(.black)
    }
}

struct TeleprompterView: View {
    @ObservedObject private var store = TeleprompterStore.shared
    @State private var editing = true
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Picker("View", selection: $editing) { Text("Write").tag(true); Text("Read").tag(false) }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer(); Button("Paste Script") { store.paste() }; Button("Import Text…") { store.importText() }
                Button("Open Reader") { store.playing = false; TeleprompterWindow.shared.show() }.disabled(store.script.isEmpty)
            }
            if editing {
                TextEditor(text: $store.script).font(.system(size: 15)).frame(minHeight: 220, maxHeight: .infinity).editorStyle()
                Text("\(store.script.split { $0.isWhitespace || $0.isNewline }.count) words · Saved on this Mac").font(.caption).foregroundStyle(.secondary)
            } else { PromptDisplay().frame(minHeight: 260, maxHeight: .infinity) }
            HStack { Text("Speed").font(.caption).frame(width: 42, alignment: .leading); Slider(value: $store.speed, in: 10...180); Text("\(Int(store.speed)) pt/s").font(.caption.monospacedDigit()).frame(width: 68) }
            HStack { Text("Type").font(.caption).frame(width: 42, alignment: .leading); Slider(value: $store.fontSize, in: 20...80, step: 1); Text("\(Int(store.fontSize)) pt").font(.caption.monospacedDigit()).frame(width: 68) }
            PromptControls()
            if !store.message.isEmpty { Text(store.message).font(.caption).foregroundStyle(.secondary) }
        }.padding(20).onChange(of: store.playing) { _, playing in if playing { editing = false } }.onChange(of: editing) { _, edit in if edit { store.playing = false } }.onDisappear { if !store.readerOpen { store.playing = false } }
    }
}
