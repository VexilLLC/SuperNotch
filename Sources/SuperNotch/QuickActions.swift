import SwiftUI
import AppKit
import ApplicationServices
import Carbon

// App launch integration: NSApp.servicesProvider = FinderShelfServices.shared
// NSServices: [{NSMenuItem:{default:"Add to SuperNotch Shelf"}, NSMessage:"addToShelf",
// NSPortName:"SuperNotch", NSSendTypes:["public.file-url", "NSFilenamesPboardType"]},
// {NSMenuItem:{default:"Add to SuperNotch Basket"}, NSMessage:"addToBasket",
// NSPortName:"SuperNotch", NSSendTypes:["public.file-url", "NSFilenamesPboardType"]}]
@MainActor final class FinderShelfServices: NSObject {
    static let shared = FinderShelfServices()
    @objc func addToShelf(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { error.pointee = "Select one or more files or folders in Finder."; return }
        FileShelfStore.shared.add(urls: urls)
        AppState.shared.page = .files; AppDelegate.shared?.openWorkspace()
    }
    @objc func addToBasket(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { error.pointee = "Select one or more files or folders in Finder."; return }
        FileShelfStore.shared.add(urls: urls); BasketController.shared.show()
    }
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        if let values = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !values.isEmpty {
            return values.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        }
        if let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            return paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}

enum RingAction: String, CaseIterable, Identifiable {
    case shelf = "File shelf", basket = "Basket", clipboard = "Clipboard", screenshot = "Screenshot", workspace = "Workspace", focus = "Focus", notes = "Focus & notes", awake = "Keep awake"
    var id: String { rawValue }
    var icon: String {
        switch self { case .shelf: return "tray.full.fill"; case .basket: return "basket.fill"; case .clipboard: return "doc.on.clipboard.fill"; case .screenshot: return "viewfinder"; case .workspace: return "square.grid.2x2.fill"; case .focus: return "timer"; case .notes: return "note.text"; case .awake: return "cup.and.saucer.fill" }
    }
    var color: Color { switch self { case .shelf, .basket: return .purple; case .clipboard: return .blue; case .screenshot: return .mint; case .workspace: return .white; case .focus, .notes: return .orange; case .awake: return .pink } }
}

/// Maps pointer movement to the six clockwise slices used by the quick ring.
/// AppKit screen coordinates are used here (positive Y points upward), so the
/// first segment is centered above the ring and subsequent segments move clockwise.
struct QuickRingSelectionGeometry {
    static let segmentCount = 6
    static let panelSize: CGFloat = 420
    static let deadZoneRadius: CGFloat = 54
    static let activationMovementThreshold: CGFloat = 22

    static func hasMovedEnough(from activationPoint: CGPoint, to point: CGPoint, threshold: CGFloat = activationMovementThreshold) -> Bool {
        hypot(point.x - activationPoint.x, point.y - activationPoint.y) >= threshold
    }

    static func segmentIndex(for point: CGPoint, around center: CGPoint, deadZone: CGFloat = deadZoneRadius) -> Int? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard hypot(dx, dy) >= deadZone else { return nil }
        let fullTurn = Double.pi * 2
        let segment = fullTurn / Double(segmentCount)
        let clockwiseFromTop = (Double.pi / 2 - atan2(Double(dy), Double(dx)) + fullTurn).truncatingRemainder(dividingBy: fullTurn)
        return Int(floor((clockwiseFromTop + segment / 2) / segment)) % segmentCount
    }
}

@MainActor final class QuickRingController: ObservableObject {
    static let shared = QuickRingController()
    @Published var slots: [RingAction] = [.shelf, .clipboard, .screenshot, .focus, .basket, .workspace] {
        didSet { UserDefaults.standard.set(slots.map(\.rawValue), forKey: "quickRing.slots") }
    }
    @Published private(set) var shortcutStatus = ""
    @Published private(set) var highlightedIndex: Int?
    @Published private(set) var isHoldingShortcut = false
    private var panel: NSPanel?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var globalMonitor: Any?
    private var pointerTimer: Timer?
    private var activationPoint: CGPoint?
    private var hasMovedFromActivationPoint = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let capture = CaptureToolsModel()
    private init() {
        if let values = UserDefaults.standard.stringArray(forKey: "quickRing.slots"), values.count == 6 {
            let decoded = values.compactMap(RingAction.init(rawValue:)); if decoded.count == 6 { slots = decoded }
        }
    }
    func installShortcut() {
        guard handler == nil else { return }
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let install = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == 0x534E5247 else { return OSStatus(eventNotHandledErr) }
            let kind = GetEventKind(event)
            Task { @MainActor in
                if kind == UInt32(kEventHotKeyPressed) {
                    QuickRingController.shared.show(holdingShortcut: true)
                } else if kind == UInt32(kEventHotKeyReleased) {
                    QuickRingController.shared.finishShortcutSelection()
                }
            }
            return noErr
        }, events.count, &events, nil, &handler)
        guard install == noErr else { shortcutStatus = "Could not install the ring shortcut."; return }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x534E5247, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        shortcutStatus = result == noErr ? "Hold ⌘⇧R, point at an action, then release" : "⌘⇧R is unavailable. Open the ring using the button."
    }
    func show(holdingShortcut: Bool = false) {
        if panel?.isVisible == true {
            if holdingShortcut { isHoldingShortcut = true } else { dismiss() }
            return
        }
        isHoldingShortcut = holdingShortcut
        highlightedIndex = nil
        let size = QuickRingSelectionGeometry.panelSize
        if panel == nil {
            let window = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.level = .popUpMenu; window.backgroundColor = .clear; window.isOpaque = false; window.hasShadow = false
            window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window.acceptsMouseMovedEvents = true
            window.dismissHandler = { [weak self] in self?.dismiss() }
            panel = window
        }
        guard let panel else { return }
        let host = NSHostingView(rootView: QuickRingView(controller: self).preferredColorScheme(.dark))
        host.sizingOptions = []
        panel.contentView = host
        let cursor = NSEvent.mouseLocation
        activationPoint = cursor
        hasMovedFromActivationPoint = false
        let frame = (NSScreen.screens.first { $0.frame.contains(cursor) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let origin = NSPoint(x: min(max(cursor.x - size / 2, frame.minX), frame.maxX - size), y: min(max(cursor.y - size / 2, frame.minY), frame.maxY - size))
        panel.setFrameOrigin(origin); panel.makeKeyAndOrderFront(nil)
        outsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel { self?.dismiss() }; return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.dismiss(); return nil }
            if let value = event.charactersIgnoringModifiers?.first?.wholeNumberValue, (1...6).contains(value) { self.run(self.slots[value - 1]); return nil }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.dismiss() } }
        pointerTimer?.invalidate()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateSelection(at: NSEvent.mouseLocation) }
        }
    }
    private func updateSelection(at point: CGPoint) {
        guard let panel, panel.isVisible else { return }
        if !hasMovedFromActivationPoint, let activationPoint {
            guard QuickRingSelectionGeometry.hasMovedEnough(from: activationPoint, to: point) else {
                if highlightedIndex != nil { highlightedIndex = nil }
                return
            }
            hasMovedFromActivationPoint = true
        }
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let next = QuickRingSelectionGeometry.segmentIndex(for: point, around: center)
        guard next != highlightedIndex else { return }
        if next != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        highlightedIndex = next
    }
    func finishShortcutSelection() {
        guard isHoldingShortcut, panel?.isVisible == true else { return }
        let action = Self.actionForShortcutRelease(isHolding: isHoldingShortcut, highlightedIndex: highlightedIndex, slots: slots)
        isHoldingShortcut = false
        if let action { run(action) } else { dismiss() }
    }
    nonisolated static func actionForShortcutRelease(isHolding: Bool, highlightedIndex: Int?, slots: [RingAction]) -> RingAction? {
        guard isHolding, let highlightedIndex, slots.indices.contains(highlightedIndex) else { return nil }
        return slots[highlightedIndex]
    }
    func dismiss() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        for monitor in [outsideMonitor, keyMonitor, globalMonitor] { if let monitor { NSEvent.removeMonitor(monitor) } }
        outsideMonitor = nil; keyMonitor = nil; globalMonitor = nil
        pointerTimer?.invalidate(); pointerTimer = nil
        activationPoint = nil; hasMovedFromActivationPoint = false
        highlightedIndex = nil; isHoldingShortcut = false
    }
    func run(_ action: RingAction) {
        dismiss()
        switch action {
        case .shelf: AppState.shared.page = .files; AppDelegate.shared?.openWorkspace()
        case .basket: BasketController.shared.show()
        case .clipboard: AppDelegate.shared?.openClipboard()
        case .screenshot:
            AppDelegate.shared?.setExpanded(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.capture.captureRegion() }
        case .workspace: AppState.shared.page = .home; AppDelegate.shared?.openWorkspace()
        case .focus: ProductivityStore.shared.toggleTimer()
        case .notes: AppDelegate.shared?.openNotesWidget()
        case .awake: ProductivityStore.shared.toggleAwake()
        }
    }
}

private struct QuickRingSegment: Shape {
    let index: Int
    private let innerRadius: CGFloat = 61
    private let outerInset: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2 - outerInset
        let start = Angle.degrees(-120 + Double(index) * 60)
        let end = Angle.degrees(-60 + Double(index) * 60)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct QuickRingView: View {
    @ObservedObject var controller: QuickRingController
    private let size = QuickRingSelectionGeometry.panelSize
    private let accent = Color(red: 0.25, green: 0.82, blue: 0.86)
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.035, green: 0.045, blue: 0.055).opacity(0.97))
                .padding(4)
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1).padding(5))
                .shadow(color: .black.opacity(0.6), radius: 20, y: 8)
            ForEach(0..<6, id: \.self) { index in
                let action = controller.slots[index]
                let angle = Double(index) * .pi / 3 - .pi / 2
                let selected = controller.highlightedIndex == index
                Button { controller.run(action) } label: {
                    ZStack {
                        QuickRingSegment(index: index)
                            .fill(selected ? accent.opacity(0.32) : .white.opacity(0.045))
                            .overlay(QuickRingSegment(index: index).stroke(selected ? accent.opacity(0.9) : .white.opacity(0.1), lineWidth: selected ? 1.5 : 0.7))
                        VStack(spacing: 7) {
                            Image(systemName: action.icon)
                                .font(.system(size: selected ? 29 : 25, weight: .semibold))
                                .foregroundStyle(selected ? .white : action.color)
                                .shadow(color: selected ? accent.opacity(0.8) : .clear, radius: 8)
                            Text(action.rawValue)
                                .font(.system(size: 11, weight: selected ? .bold : .semibold, design: .rounded))
                                .foregroundStyle(selected ? .white : .white.opacity(0.78))
                                .lineLimit(1)
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(selected ? accent : .white.opacity(0.34))
                        }
                        .offset(x: cos(angle) * 128, y: sin(angle) * 128)
                        .scaleEffect(selected ? 1.06 : 1)
                        .animation(.easeOut(duration: 0.11), value: selected)
                    }
                    .contentShape(QuickRingSegment(index: index))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.rawValue)
                .accessibilityHint("Action \(index + 1) of 6")
                .help("\(action.rawValue) · \(index + 1)")
            }
            centerHub
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.1), value: controller.highlightedIndex)
    }

    private var centerHub: some View {
        let selected = controller.highlightedIndex.map { controller.slots[$0] }
        return Button { controller.dismiss() } label: {
            VStack(spacing: 4) {
                if let selected {
                    Image(systemName: selected.icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(accent)
                    Text(selected.rawValue).font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(controller.isHoldingShortcut ? "RELEASE" : "CLICK SLICE")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.48))
                } else {
                    Image(systemName: "cursorarrow.motionlines").font(.system(size: 18, weight: .semibold)).foregroundStyle(accent)
                    Text("MOVE TO SELECT").font(.system(size: 9, weight: .bold, design: .rounded))
                    Text(controller.isHoldingShortcut ? "RELEASE TO CANCEL" : "ESC TO CLOSE")
                        .font(.system(size: 7.5, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .frame(width: 112, height: 112)
            .background(Color.black.opacity(0.86), in: Circle())
            .overlay(Circle().stroke(selected == nil ? .white.opacity(0.15) : accent.opacity(0.8), lineWidth: selected == nil ? 1 : 2))
            .shadow(color: .black.opacity(0.55), radius: 10)
        }
        .buttonStyle(.plain)
        .help("Close ring")
    }
}

@MainActor final class KeySoundStore: ObservableObject {
    static let shared = KeySoundStore()
    @Published private(set) var enabled = false
    @Published var soundName = "Tink"
    @Published var volume: Double = 0.25
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastPlay = Date.distantPast
    private var recentSounds: [NSSound] = []
    func setEnabled(_ value: Bool) {
        stop(); enabled = value; accessibilityTrusted = AXIsProcessTrusted()
        guard value else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.play(event); return event }
        if accessibilityTrusted {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in Task { @MainActor in self?.play(event) } }
        }
    }
    func refreshPermission() { let previous = enabled; setEnabled(previous) }
    func preview() { playSound() }
    private func play(_ event: NSEvent) {
        guard enabled, !event.isARepeat, !event.modifierFlags.contains(.command), Date().timeIntervalSince(lastPlay) > 0.025 else { return }
        // Event content is never read, recorded, or retained.
        lastPlay = Date(); playSound()
    }
    private func playSound() {
        recentSounds.removeAll { !$0.isPlaying }
        guard let sound = NSSound(named: soundName)?.copy() as? NSSound else { return }
        sound.volume = Float(volume); recentSounds.append(sound); sound.play()
    }
    private func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil; recentSounds.forEach { $0.stop() }; recentSounds.removeAll()
    }
}

struct QuickActionsView: View {
    @ObservedObject private var ring = QuickRingController.shared
    @ObservedObject private var keys = KeySoundStore.shared
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) { Label("Cursor Ring", systemImage: "circle.hexagongrid.fill").font(.headline); Text("Six shortcuts, right at your pointer.").font(.callout).foregroundStyle(.secondary) }
                Spacer(); Button("Open Ring") { ring.show() }.buttonStyle(.borderedProminent)
            }
            Text(ring.shortcutStatus).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(0..<6, id: \.self) { index in
                    HStack { Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary); Picker("Slot \(index + 1)", selection: Binding(get: { ring.slots[index] }, set: { ring.slots[index] = $0 })) { ForEach(RingAction.allCases) { action in Label(action.rawValue, systemImage: action.icon).tag(action) } }.labelsHidden() }
                }
            }
            Text("Hold ⌘⇧R, move toward an action, then release to open it. You can also click an action or press 1–6. Escape or clicking outside closes the ring.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle(isOn: Binding(get: { keys.enabled }, set: { keys.setEnabled($0) })) { Label("Typing Sounds", systemImage: "keyboard").font(.headline) }
            Text("A quiet click for each key. Uses macOS sounds; keyboard text is never read or saved.").font(.caption).foregroundStyle(.secondary)
            HStack { Picker("Sound", selection: $keys.soundName) { ForEach(["Tink", "Pop", "Glass", "Purr"], id: \.self) { Text($0) } }; Slider(value: $keys.volume, in: 0...1).frame(maxWidth: 150).accessibilityLabel("Typing sound volume"); Button("Preview") { keys.preview() } }
            HStack {
                Label(keys.accessibilityTrusted ? "Accessibility access available" : "Sounds work within SuperNotch", systemImage: keys.accessibilityTrusted ? "checkmark.circle" : "info.circle").font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Refresh") { keys.refreshPermission() }
            }
            if !keys.accessibilityTrusted {
                Text("For sounds in other apps, enable SuperNotch in Accessibility settings, then click Refresh.").font(.caption).foregroundStyle(.secondary)
                Button("Open Accessibility settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) } }
            }
            Divider()
            Label("Finder Services", systemImage: "folder.badge.plus").font(.headline)
            Text("Select files in Finder, then choose Services → Add to SuperNotch Shelf or Add to SuperNotch Basket. If missing, enable the services in System Settings → Keyboard → Keyboard Shortcuts → Services. The installed application must be registered with macOS.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: 760, alignment: .leading) }.onAppear { ring.installShortcut(); keys.refreshPermission() }
    }
}
