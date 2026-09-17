import SwiftUI
import AppKit
import Carbon
import ServiceManagement

@main
struct SuperNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        // Settings live in a custom window; keep ⌘, pointed at it.
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) { Button("Settings…") { AppDelegate.shared?.openSettings() }.keyboardShortcut(",", modifiers: .command) } }
    }
}

enum IslandHomeLayout: String, CaseIterable, Identifiable {
    case musicFocus, focusMusic, music, focus
    var id: String { rawValue }
    var title: String {
        switch self {
        case .musicFocus: return "Music + Focus"
        case .focusMusic: return "Focus + Music"
        case .music: return "Music"
        case .focus: return "Focus"
        }
    }
}

@MainActor final class Preferences: ObservableObject {
    static let shared = Preferences()
    @Published var homeLayout = IslandHomeLayout(rawValue: UserDefaults.standard.string(forKey: "homeLayout") ?? "musicFocus") ?? .musicFocus { didSet { save("homeLayout", homeLayout.rawValue) } }
    @Published var shelfRetention = ShelfRetention(rawValue: UserDefaults.standard.string(forKey: "shelfRetention") ?? "forever") ?? .forever { didSet { save("shelfRetention", shelfRetention.rawValue); FileShelfStore.shared.retentionPolicyDidChange() } }
    @Published var liveActivities = UserDefaults.standard.object(forKey: "liveActivities") as? Bool ?? true { didSet { save("liveActivities", liveActivities); if !liveActivities { IslandActivityController.shared.dismiss() } } }
    @Published var hover = UserDefaults.standard.object(forKey: "hover") as? Bool ?? true { didSet { save("hover", hover) } }
    @Published var island = UserDefaults.standard.object(forKey: "island") as? Bool ?? false { didSet { save("island", island); AppDelegate.shared?.rebuildPanels() } }
    @Published var allDisplays = UserDefaults.standard.bool(forKey: "allDisplays") { didSet { save("allDisplays", allDisplays); AppDelegate.shared?.rebuildPanels() } }
    @Published var outline = UserDefaults.standard.object(forKey: "outline") as? Bool ?? true { didSet { save("outline", outline) } }
    @Published var shakeBasket = UserDefaults.standard.bool(forKey: "shakeBasket") { didSet { save("shakeBasket", shakeBasket); BasketController.shared.enableDragSummon(shakeBasket) } }
    @Published var accentName = UserDefaults.standard.string(forKey: "accentName") ?? "System" { didSet { save("accentName", accentName) } }
    static let accentNames = ["System", "Blue", "Violet", "Mint", "Orange", "Pink"]
    var accent: Color { switch accentName { case "Blue": return .blue; case "Violet": return .purple; case "Mint": return .mint; case "Orange": return .orange; case "Pink": return .pink; default: return .accentColor } }
    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }
}

@MainActor final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var page: Page = .home
    @Published var toolGroup = 0
    @Published var toolDetail = ""
    @Published var expanded = false
    /// Pointer is over the collapsed island; it grows slightly before opening.
    @Published var hovering = false
    @Published var islandTab = 0
    @Published var islandWidget = UserDefaults.standard.integer(forKey: "lastIslandWidget") { didSet { UserDefaults.standard.set(islandWidget, forKey: "lastIslandWidget") } }
    @Published var notice: String?
    enum Page: String, CaseIterable, Identifiable {
        case home = "Overview", files = "File Shelf", clipboard = "Clipboard", media = "Now Playing", productivity = "Focus & Notes", tools = "Tools", extensions = "All Features"
        var id: String { rawValue }
        var icon: String { switch self { case .home: return "square.grid.2x2"; case .files: return "tray.full"; case .clipboard: return "list.clipboard"; case .media: return "play.circle"; case .productivity: return "timer"; case .tools: return "wrench.and.screwdriver"; case .extensions: return "puzzlepiece.extension" } }
    }
}

final class IslandPanel: NSPanel {
    var acceptsKeyboard = true
    var dismissHandler: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismissHandler?() }
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?
    var statusItem: NSStatusItem!
    var window: NSWindow?
    var panels: [NSPanel] = []
    var hotKeys: [EventHotKeyRef?] = []
    var eventHandler: EventHandlerRef?
    var hoverTimer: Timer?
    var keyEventMonitor: Any?
    var outsideSince: Date?
    var hoverSince: Date?
    var mouseMonitors: [Any] = []
    private var geometryCache: [ObjectIdentifier: IslandGeometry] = [:]
    var suppressHoverUntilExit = false
    var explicitExpansion = false
    private var pendingExternalActions: [ExternalAction] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        for (title, action, key) in [("Command Palette", #selector(openCommandPalette), ""), ("Open SuperNotch", #selector(openWorkspace), ""), ("Toggle shelf", #selector(toggleShelf), ""), ("Clipboard history", #selector(openClipboard), ""), ("Floating basket", #selector(openBasket), ""), ("Quick notes", #selector(openNotesWidget), ""), ("Agenda widget", #selector(openAgendaWidget), ""), ("Settings…", #selector(openSettings), ",")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SuperNotch", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        // The menu bar item can show live stats; see Settings › Menu Bar.
        statusItem = MenuBarController.shared.install(menu: menu)
        _ = CommandToolsModel.shared
        ClipboardStore.shared.startMonitoring()
        SystemMonitor.shared.start()
        BatteryInsightsMonitor.shared.start()
        MediaController.shared.startAutomaticIfNeeded()
        SystemActivitiesModel.shared.start()
        IslandActivityController.shared.start()
        AIUsageStore.shared.start()
        BasketController.shared.enableDragSummon(Preferences.shared.shakeBasket)
        rebuildPanels()
        NSApp.servicesProvider = FinderShelfServices.shared
        registerHotKeys()
        QuickRingController.shared.installShortcut()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildPanels), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Pointer movement drives hover, click-through and drag-to-open; no polling timer is needed.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in Task { @MainActor in self?.checkHover() } }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in self?.checkHover(); return event }) { mouseMonitors.append(local) }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in Task { @MainActor in self?.handleMouseDown(nil) } }) { mouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in self?.handleMouseDown(event); return event }) { mouseMonitors.append(local) }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if AppState.shared.expanded, NSApp.modalWindow == nil,
               let window = event.window ?? NSApp.keyWindow,
               self?.panels.contains(where: { $0 === window }) == true,
               event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
               let key = event.charactersIgnoringModifiers,
               let page = ["1": 0, "2": 1, "3": 2][key] {
                AppState.shared.islandTab = page
                return nil
            }
            if event.keyCode == 53, AppState.shared.expanded, NSApp.modalWindow == nil,
               let window = event.window ?? NSApp.keyWindow, self?.panels.contains(where: { $0 === window }) == true {
                self?.setExpanded(false)
                return nil
            }
            return event
        }
        if let page = ProcessInfo.processInfo.environment["SUPERNOTCH_DEBUG_PAGE"] {
            AppState.shared.page = AppState.Page.allCases.first { $0.rawValue.lowercased().contains(page.lowercased()) } ?? .home
            openWorkspace()
        }
        if let palette = ProcessInfo.processInfo.environment["SUPERNOTCH_DEBUG_PALETTE"] {
            DispatchQueue.main.async { [weak self] in
                self?.openCommandPalette()
                if palette.lowercased() == "clipboard" { CommandPaletteStore.shared.enterClipboard() }
            }
        }
        if pendingExternalActions.isEmpty && !UserDefaults.standard.bool(forKey: "didShowWorkspace") {
            UserDefaults.standard.set(true, forKey: "didShowWorkspace")
            openWorkspace()
        }
        let launchActions = pendingExternalActions
        pendingExternalActions.removeAll()
        for action in launchActions { ExternalActionDispatcher.shared.dispatch(action) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = ExternalActionParser.parse(url) else { continue }
            if Self.shared == nil {
                if pendingExternalActions.count < 32 { pendingExternalActions.append(action) }
            } else {
                ExternalActionDispatcher.shared.dispatch(action)
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openWorkspace(); return true }
    @objc func quitApp() { NSApp.terminate(nil) }
    @objc func openWorkspace() {
        setExpanded(false)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "SuperNotch"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = NSColor(white: 0.035, alpha: 1)
            w.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: WorkspaceView())
            // The window sets its own size; skip SwiftUI's min/max size measurement on every update.
            host.sizingOptions = []
            w.contentView = host
            w.minSize = NSSize(width: 880, height: 600); w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("SuperNotchWorkspace"); w.tabbingMode = .disallowed
            w.delegate = self
            if !w.setFrameUsingName("SuperNotchWorkspace") { w.center() }
            window = w
        }
        // A visible workspace behaves like a regular app: Dock icon, main menu and ⌘-Tab.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        // Release the view tree so a closed workspace holds no SwiftUI graph, images or observers.
        window = nil
        DispatchQueue.main.async { closing.contentView = nil }
        DispatchQueue.main.async { self.updateActivationPolicy() }
    }
    /// SuperNotch shows in the Dock only while one of its regular windows is open.
    func updateActivationPolicy() {
        let visible = window?.isVisible == true || SettingsWindowController.shared.isVisible
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
    }
    @objc func openClipboard() {
        ClipboardStore.shared.rememberPasteDestination()
        setExpanded(false)
        ClipboardPanelController.shared.show()
    }
    @objc func openCommandPalette() { CommandPaletteController.shared.toggle() }
    @objc func openBasket() { BasketController.shared.show() }
    @objc func openNotesWidget() { openWidget(0) }
    @objc func openAgendaWidget() { openWidget(1) }
    func openWidget(_ index: Int) {
        guard let widget = IslandWidgetID(rawValue: index) else { return }
        WidgetPreferences.shared.setVisible(widget, true)
        AppState.shared.islandTab = 2
        AppState.shared.islandWidget = index
        setExpanded(true)
        explicitExpansion = true
        panels.first?.makeKeyAndOrderFront(nil)
    }
    @objc func openSettings() {
        setExpanded(false)
        SettingsWindowController.shared.show()
    }
    @objc func toggleShelf() { setExpanded(!AppState.shared.expanded) }
    func setExpanded(_ value: Bool, fromHover: Bool = false) {
        guard value != AppState.shared.expanded else { return }
        outsideSince = nil; hoverSince = nil
        explicitExpansion = value && !fromHover
        if !value { suppressHoverUntilExit = true }
        withAnimation(value ? IslandMotion.open : IslandMotion.close) {
            AppState.shared.expanded = value
            AppState.shared.hovering = false
        }
        if value { IslandActivityController.shared.dismiss() }
        reposition()
        if value && !fromHover { panels.first?.makeKeyAndOrderFront(nil) }
        if !value { panels.filter { $0.isKeyWindow }.forEach { $0.resignKey() } }
    }
    @objc func rebuildPanels() {
        panels.forEach { $0.close() }; panels.removeAll(); geometryCache.removeAll()
        let screens = Preferences.shared.allDisplays ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        for screen in screens {
            let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.dismissHandler = { [weak self] in self?.setExpanded(false) }
            panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true; panel.level = .statusBar; panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            let geometry = IslandGeometry(screen: screen)
            let host = NSHostingView(rootView: IslandView(geometry: geometry).preferredColorScheme(.dark))
            host.sizingOptions = []
            host.layer?.backgroundColor = .clear
            geometryCache[ObjectIdentifier(panel)] = geometry
            panel.contentView = host
            panels.append(panel); place(panel, on: screen); panel.orderFrontRegardless()
        }
    }
    func reposition() {
        for (index, panel) in panels.enumerated() { if let screen = NSScreen.screens[safe: index] { place(panel, on: screen) } }
        checkHover()
    }
    /// The panel never resizes: it spans the largest island state and SwiftUI animates the shape inside it.
    private func place(_ panel: NSPanel, on screen: NSScreen) {
        (panel as? IslandPanel)?.acceptsKeyboard = AppState.shared.expanded
        let canvas = IslandGeometry(screen: screen).canvasSize
        let target = NSRect(x: (screen.frame.midX - canvas.width / 2).rounded(), y: screen.frame.maxY - canvas.height, width: canvas.width, height: canvas.height)
        if panel.frame != target { panel.setFrame(target, display: true) }
    }
    /// The visible island (and, when open, its navigation pills) in screen coordinates.
    private func islandRects(on screen: NSScreen, panel: NSPanel? = nil) -> [NSRect] {
        let geometry = panel.flatMap { geometryCache[ObjectIdentifier($0)] } ?? IslandGeometry(screen: screen)
        let state = AppState.shared
        let size = geometry.shapeSize(expanded: state.expanded, tab: state.islandTab, hovering: state.hovering, activity: IslandActivityController.shared.current != nil, live: IslandGeometry.hasLiveContent)
        let top = screen.frame.maxY - geometry.topGap
        // Collapsed targets get a little slack so the notch is easy to hit at the screen edge.
        let slack: CGFloat = state.expanded ? 0 : 6
        var rects = [NSRect(x: screen.frame.midX - size.width / 2 - slack, y: top - size.height - slack, width: size.width + slack * 2, height: size.height + slack + 1)]
        if state.expanded {
            let pillsTop = top - size.height - IslandGeometry.pillsGap
            rects.append(NSRect(x: screen.frame.midX - IslandGeometry.pillsWidth / 2, y: pillsTop - IslandGeometry.pillsHeight, width: IslandGeometry.pillsWidth, height: IslandGeometry.pillsHeight))
        }
        return rects
    }
    private func pointerIsOverIsland(_ point: NSPoint) -> Bool {
        panels.indices.contains { index in NSScreen.screens[safe: index].map { islandRects(on: $0, panel: panels[index]).contains { $0.contains(point) } } ?? false }
    }
    /// Clicking anywhere outside the open island closes it. Clicks inside SuperNotch's own
    /// popovers and menus (which belong to the island) are ignored.
    func handleMouseDown(_ event: NSEvent?) {
        guard AppState.shared.expanded else { return }
        if let window = event?.window, window !== self.window { return }
        if !pointerIsOverIsland(NSEvent.mouseLocation) { setExpanded(false) }
    }
    private func checkHover() {
        let p = NSEvent.mouseLocation
        var insideAny = false
        for (index, panel) in panels.enumerated() {
            guard let screen = NSScreen.screens[safe: index] else { continue }
            let inside = islandRects(on: screen, panel: panel).contains { $0.contains(p) }
            // Outside the visible shape, clicks fall through to the menu bar and apps below.
            let ignore = !inside && !(AppState.shared.expanded && panel.isKeyWindow && NSEvent.pressedMouseButtons != 0)
            if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
            insideAny = insideAny || inside
        }
        let state = AppState.shared
        if insideAny {
            guard !state.expanded else { return }
            if !state.hovering { withAnimation(IslandMotion.hover) { state.hovering = true } }
            // Hover only previews; a click opens. Dragging files onto the notch still opens the tray.
            let draggingFile = NSEvent.pressedMouseButtons & 1 == 1 && NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            if hoverSince == nil { hoverSince = Date() }
            if draggingFile, Date().timeIntervalSince(hoverSince!) > 0.15 { setExpanded(true, fromHover: true); state.islandTab = 1 }
        } else {
            hoverSince = nil
            if state.hovering { withAnimation(IslandMotion.hover) { state.hovering = false } }
        }
    }
    private func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }; var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == 0x534E4348 else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in switch id.id { case 1: AppDelegate.shared?.toggleShelf(); case 2: AppDelegate.shared?.openClipboard(); case 3: AppDelegate.shared?.openBasket(); case 4: AppDelegate.shared?.openNotesWidget(); case 5: AppDelegate.shared?.openAgendaWidget(); case 6: AppDelegate.shared?.openCommandPalette(); default: break } }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        for (index, key) in [UInt32(kVK_Space), UInt32(kVK_ANSI_V), UInt32(kVK_ANSI_B), UInt32(kVK_ANSI_N), UInt32(kVK_ANSI_A)].enumerated() {
            var ref: EventHotKeyRef?; RegisterEventHotKey(key, UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x534E4348, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &ref); hotKeys.append(ref)
        }
        var paletteRef: EventHotKeyRef?
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x534E4348, id: 6), GetApplicationEventTarget(), 0, &paletteRef)
        hotKeys.append(paletteRef)
    }
    func applicationWillTerminate(_ notification: Notification) { ClipboardStore.shared.flushPendingWrites(); BatteryInsightsMonitor.shared.stop(); IslandActivityController.shared.stop(); AIUsageStore.shared.stop(); CommandPaletteController.shared.hide(); hotKeys.forEach { if let key = $0 { UnregisterEventHotKey(key) } }; hoverTimer?.invalidate(); mouseMonitors.forEach { NSEvent.removeMonitor($0) }; if let keyEventMonitor { NSEvent.removeMonitor(keyEventMonitor) } }
}
extension Collection { subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil } }
