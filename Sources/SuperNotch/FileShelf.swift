import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

struct ShelfItem: Identifiable, Codable {
    let id: UUID
    var path: String
    var bookmark: Data?
    var pinned: Bool
    let addedAt: Date
    var basketID: UUID? = nil
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}

struct ShelfBasket: Identifiable, Codable, Equatable {
    static let mainID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let id: UUID
    var name: String
    static var main: ShelfBasket { ShelfBasket(id: mainID, name: "Main") }
}

private struct ShelfArchive: Codable {
    let version: Int
    let baskets: [ShelfBasket]
    let activeBasketID: UUID
    let items: [ShelfItem]
}

enum ShelfRetention: String, CaseIterable, Identifiable {
    case forever, hour, day, week
    var id: String { rawValue }
    var title: String {
        switch self { case .forever: return "Keep until removed"; case .hour: return "1 hour"; case .day: return "1 day"; case .week: return "1 week" }
    }
    var seconds: TimeInterval? {
        switch self { case .forever: return nil; case .hour: return 3600; case .day: return 86400; case .week: return 604800 }
    }
}

@MainActor final class FileShelfStore: ObservableObject {
    static let shared = FileShelfStore()
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var baskets: [ShelfBasket] = [.main]
    @Published private(set) var activeBasketID = ShelfBasket.mainID
    @Published var message: String?
    private let storageURL: URL
    private var accessedURLs: [URL] = []
    private var activeChooser: NSOpenPanel?
    private var legacyData: Data?
    private var loadFailed = false
    private var retentionTimer: Timer?
    private let monitorRetention: Bool
    var hasScheduledRetentionCheck: Bool { retentionTimer != nil }
    private let now: () -> Date
    private let retentionDuration: @MainActor () -> TimeInterval?

    init(storageURL: URL? = nil, now: @escaping () -> Date = Date.init, retentionDuration: @escaping @MainActor () -> TimeInterval? = { Preferences.shared.shelfRetention.seconds }, monitorRetention: Bool = true) {
        self.now = now
        self.retentionDuration = retentionDuration
        self.monitorRetention = monitorRetention
        let directory = SuperNotchStorage.baseDirectory
        self.storageURL = storageURL ?? directory.appendingPathComponent("shelf.json")
        try? FileManager.default.createDirectory(at: self.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: self.storageURL.path) {
            do {
                let data = try Data(contentsOf: self.storageURL)
                let saved: [ShelfItem]
                if let legacy = try? JSONDecoder().decode([ShelfItem].self, from: data) {
                    saved = legacy
                    legacyData = data
                } else {
                    let archive = try JSONDecoder().decode(ShelfArchive.self, from: data)
                    guard archive.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                    var seen = Set<UUID>()
                    baskets = archive.baskets.filter { seen.insert($0.id).inserted }.map {
                        ShelfBasket(id: $0.id, name: Self.cleanName($0.name) ?? "Basket")
                    }
                    if let index = baskets.firstIndex(where: { $0.id == ShelfBasket.mainID }) {
                        let main = baskets.remove(at: index)
                        baskets.insert(main, at: 0)
                    } else { baskets.insert(.main, at: 0) }
                    activeBasketID = baskets.contains { $0.id == archive.activeBasketID } ? archive.activeBasketID : ShelfBasket.mainID
                    saved = archive.items
                }
                items = saved.map { original in
                    var item = original
                    if !baskets.contains(where: { $0.id == item.basketID }) { item.basketID = ShelfBasket.mainID }
                    if let bookmark = item.bookmark {
                        var stale = false
                        if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                            item.path = resolved.path
                            if resolved.startAccessingSecurityScopedResource() { accessedURLs.append(resolved) }
                            if stale { item.bookmark = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
                        }
                    }
                    return item
                }
            } catch {
                loadFailed = true
                message = "Could not read the saved shelf. Its file has been preserved; changes are disabled until it is restored."
            }
        }
        purgeExpired()
        scheduleNextRetentionCheck()
    }
    deinit {
        retentionTimer?.invalidate()
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }
    /// Only references expire. Never delete or move the original files.
    func purgeExpired() {
        guard !loadFailed, let duration = retentionDuration(), duration.isFinite, duration > 0 else { return }
        let cutoff = now().addingTimeInterval(-duration)
        let oldCount = items.count
        items.removeAll { !$0.pinned && $0.addedAt <= cutoff }
        if items.count != oldCount { releaseUnusedAccess(); save() }
    }
    func retentionPolicyDidChange() {
        purgeExpired()
        scheduleNextRetentionCheck()
    }
    private func scheduleNextRetentionCheck() {
        retentionTimer?.invalidate(); retentionTimer = nil
        guard monitorRetention, let duration = retentionDuration(), duration.isFinite, duration > 0,
              let nextExpiry = items.lazy.filter({ !$0.pinned }).map({ $0.addedAt.addingTimeInterval(duration) }).min() else { return }
        let timer = Timer(timeInterval: max(1, nextExpiry.timeIntervalSince(now())), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.purgeExpired()
                self?.scheduleNextRetentionCheck()
            }
        }
        timer.tolerance = min(30, max(1, nextExpiry.timeIntervalSince(now()) * 0.05))
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }
    private func releaseUnusedAccess() {
        let retained = Set(items.map(\.path))
        accessedURLs.removeAll { url in
            guard !retained.contains(url.path) else { return false }
            url.stopAccessingSecurityScopedResource()
            return true
        }
    }
    var activeBasket: ShelfBasket { baskets.first { $0.id == activeBasketID } ?? .main }
    var activeItems: [ShelfItem] { items.filter { ($0.basketID ?? ShelfBasket.mainID) == activeBasketID } }
    var sortedItems: [ShelfItem] { activeItems.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.addedAt > $1.addedAt } }
    var canCreateBasket: Bool { !loadFailed && baskets.count < 12 }
    var canRemoveBasket: Bool { !loadFailed && activeBasketID != ShelfBasket.mainID }
    func basketItemCount(_ id: UUID) -> Int { items.filter { ($0.basketID ?? ShelfBasket.mainID) == id }.count }
    func selectBasket(_ id: UUID) {
        guard !loadFailed, baskets.contains(where: { $0.id == id }) else { return }
        activeBasketID = id
        save()
    }
    @discardableResult func createBasket(name: String) -> Bool {
        guard canCreateBasket, let name = Self.cleanName(name) else { return false }
        let basket = ShelfBasket(id: UUID(), name: name)
        baskets.append(basket)
        activeBasketID = basket.id
        save()
        return true
    }
    @discardableResult func renameActiveBasket(name: String) -> Bool { renameBasket(activeBasketID, name: name) }
    @discardableResult func renameBasket(_ id: UUID, name: String) -> Bool {
        guard !loadFailed, let name = Self.cleanName(name), let index = baskets.firstIndex(where: { $0.id == id }) else { return false }
        baskets[index].name = name
        save()
        return true
    }
    private static func cleanName(_ name: String) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40, !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return clean
    }
    private static func fileKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    func move(_ item: ShelfItem, to basketID: UUID) {
        guard !loadFailed, baskets.contains(where: { $0.id == basketID }), let index = items.firstIndex(where: { $0.id == item.id }), items[index].basketID != basketID else { return }
        let source = items[index]
        if let duplicate = items.firstIndex(where: { Self.fileKey($0.path) == Self.fileKey(source.path) && ($0.basketID ?? ShelfBasket.mainID) == basketID }) {
            items[duplicate].pinned = items[duplicate].pinned || source.pinned
            if items[duplicate].bookmark == nil { items[duplicate].bookmark = source.bookmark }
            items.remove(at: index)
        } else { items[index].basketID = basketID }
        releaseUnusedAccess()
        save()
    }
    func removeActiveBasket() { removeBasket(activeBasketID) }
    func removeBasket(_ id: UUID) {
        guard !loadFailed, id != ShelfBasket.mainID, baskets.contains(where: { $0.id == id }) else { return }
        // Merge references first. A matching destination keeps either pin.
        for item in items.filter({ ($0.basketID ?? ShelfBasket.mainID) == id }) { move(item, to: ShelfBasket.mainID) }
        if activeBasketID == id { activeBasketID = ShelfBasket.mainID }
        baskets.removeAll { $0.id == id }
        save()
    }
    func add(urls: [URL], to basketID: UUID? = nil) {
        guard !loadFailed else { return }
        // Capture destinations when an asynchronous chooser/drop starts. If
        // that basket was merged meanwhile, place references in Main.
        let requested = basketID ?? activeBasketID
        let destination = baskets.contains { $0.id == requested } ? requested : ShelfBasket.mainID
        var added = 0
        for url in urls where url.isFileURL {
            let url = url.standardizedFileURL
            let key = Self.fileKey(url.path)
            guard !items.contains(where: { Self.fileKey($0.path) == key && ($0.basketID ?? ShelfBasket.mainID) == destination }) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if url.startAccessingSecurityScopedResource() { accessedURLs.append(url) }
            let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            items.append(ShelfItem(id: UUID(), path: url.path, bookmark: bookmark, pinned: false, addedAt: now(), basketID: destination))
            added += 1
        }
        if added > 0 { message = nil; save() }
    }
    func togglePin(_ item: ShelfItem) {
        guard !loadFailed, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle(); save(); purgeExpired()
    }
    func remove(_ item: ShelfItem) { guard !loadFailed else { return }; items.removeAll { $0.id == item.id }; releaseUnusedAccess(); save() }
    func clearUnpinned() { guard !loadFailed else { return }; items.removeAll { !$0.pinned && ($0.basketID ?? ShelfBasket.mainID) == activeBasketID }; releaseUnusedAccess(); save() }
    func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        if let activeChooser { activeChooser.makeKeyAndOrderFront(nil); return }
        let destination = activeBasketID
        let panel = NSOpenPanel()
        activeChooser = panel
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add to Shelf"
        panel.begin { [weak self] response in
            Task { @MainActor in
                self?.activeChooser = nil
                if response == .OK { self?.add(urls: panel.urls, to: destination) }
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func open(_ item: ShelfItem) {
        if !NSWorkspace.shared.open(item.url) { message = "This file is unavailable. It may have been moved or deleted." }
    }
    func save() {
        guard !loadFailed else { return }
        do {
            if let legacyData {
                let backup = storageURL.appendingPathExtension("legacy-backup")
                if !FileManager.default.fileExists(atPath: backup.path) { try legacyData.write(to: backup, options: .withoutOverwriting) }
            }
            let archive = ShelfArchive(version: 1, baskets: baskets, activeBasketID: activeBasketID, items: items)
            try JSONEncoder().encode(archive).write(to: storageURL, options: .atomic)
            legacyData = nil
            scheduleNextRetentionCheck()
        }
        catch { message = "Could not save shelf: \(error.localizedDescription)" }
    }
}

struct FileShelfView: View {
    @ObservedObject var store: FileShelfStore
    @State private var targeted = false
    @State private var search = ""
    @State private var selectedID: UUID?
    init(store: FileShelfStore) { self.store = store }
    init() { self.store = .shared }
    private var visibleItems: [ShelfItem] {
        store.sortedItems.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                BasketSwitcher(store: store)
                Spacer()
                if store.activeItems.count > 6 {
                    TextField("Filter", text: $search, prompt: Text("Filter files")).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
                Button { store.chooseFiles() } label: { Label("Add Files…", systemImage: "plus") }.help("Add files or folders")
                Menu {
                    Button("Open Floating Basket") { BasketController.shared.show() }
                    Divider()
                    Button("Clear Unpinned Items") { store.clearUnpinned() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More actions")
            }
            if store.activeItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(targeted ? "Release to Add" : "Drop Files Here").font(.title3.weight(.semibold))
                    Text("Files stay where they are. Drag them from here into any app,\nand pin the ones you want to keep handy.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Add Files…") { store.chooseFiles() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(visibleItems) { item in
                            shelfTile(item)
                        }
                    }.padding(3)
                }.frame(minHeight: 100, maxHeight: .infinity)
                if visibleItems.isEmpty { Text("No matching files").foregroundStyle(.secondary) }
                HStack {
                    Text("Drag to any app · Double-click to open · Right-click for more").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.activeItems.filter(\.pinned).count) pinned").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = store.message {
                InlineMessage(text: message, tone: .orange) { store.message = nil }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(.fill.quinary)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: store.activeItems.isEmpty ? [6, 4] : [])))
        .onChange(of: store.activeBasketID) { _, _ in search = ""; selectedID = nil }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            let destination = store.activeBasketID
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                    var url: URL?
                    if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let direct = value as? URL { url = direct }
                    else if let string = value as? String { url = URL(string: string) }
                    if let url { Task { @MainActor in store.add(urls: [url], to: destination) } }
                }
            }
            return !providers.isEmpty
        }
    }
    private func shelfTile(_ item: ShelfItem) -> some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                FileThumbnailView(url: item.url, size: 44)
                if item.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.orange).offset(x: 10, y: -3) }
            }
            Text(item.name).font(.callout).lineLimit(2).multilineTextAlignment(.center).frame(height: 32, alignment: .top)
                .padding(.horizontal, 4)
                .background(selectedID == item.id ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(selectedID == item.id ? .white : .primary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selectedID == item.id ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) { store.open(item) }
        .onTapGesture { selectedID = item.id }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("Open") { store.open(item) }
            Button("Quick Look") { ShelfQuickLook.shared.show(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button(item.pinned ? "Unpin" : "Pin to shelf") { store.togglePin(item) }
            ShelfMoveMenu(store: store, item: item)
            Button("Copy file") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item.url as NSURL]) }
            Menu("Share") {
                Button("AirDrop") { NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [item.url]) }
                Button("Mail") { NSSharingService(named: .composeEmail)?.perform(withItems: [item.url]) }
                Button("Messages") { NSSharingService(named: .composeMessage)?.perform(withItems: [item.url]) }
            }
            Divider()
            Button("Remove from shelf") { store.remove(item) }
        }
        .help(item.path)
    }
}

@MainActor private final class ShelfQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = ShelfQuickLook()
    private var url: URL?
    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}

private final class ShelfFloatingPanel: NSPanel {
    var dismissHandler: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismissHandler?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class BasketController: NSObject {
    static let shared = BasketController()
    private var panel: NSPanel?
    private var dragMonitor: Any?
    private var previousX: CGFloat = 0
    private var direction: CGFloat = 0
    private var reversalTimes: [TimeInterval] = []
    private var lastShown: TimeInterval = 0
    var isVisible: Bool { panel?.isVisible == true }
    func show(takeFocus: Bool = true) {
        if panel == nil {
            let window = ShelfFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "SuperNotch Basket"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.level = .floating
            window.isFloatingPanel = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.dismissHandler = { [weak self] in self?.hide() }
            window.contentView = nil
            panel = window
        }
        guard let panel else { return }
        if panel.contentView == nil {
            let host = NSHostingView(rootView: BasketSurfaceView(onClose: { [weak self] in self?.hide() }).preferredColorScheme(.dark))
            host.sizingOptions = []
            panel.contentView = host
        }
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let frame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            panel.setFrameOrigin(NSPoint(x: min(max(point.x - panel.frame.width / 2, frame.minX), frame.maxX - panel.frame.width), y: min(max(point.y - panel.frame.height - 20, frame.minY), frame.maxY - panel.frame.height)))
        }
        if takeFocus { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
    }
    func toggle() { isVisible ? hide() : show() }
    func hide() { panel?.orderOut(nil); panel?.contentView = nil }
    func enableDragSummon(_ enabled: Bool = true) {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor); self.dragMonitor = nil }
        guard enabled else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in self?.observeDrag() }
        }
    }
    private func observeDrag() {
        let now = Date.timeIntervalSinceReferenceDate
        let x = NSEvent.mouseLocation.x
        let delta = x - previousX
        previousX = x
        guard abs(delta) > 4, now - lastShown > 3 else { return }
        let nextDirection: CGFloat = delta > 0 ? 1 : -1
        if direction != 0 && nextDirection != direction { reversalTimes.append(now) }
        direction = nextDirection
        reversalTimes.removeAll { now - $0 > 1.2 }
        guard reversalTimes.count >= 5, NSPasteboard(name: .drag).canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        reversalTimes.removeAll(); lastShown = now
        show(takeFocus: false)
    }
}
