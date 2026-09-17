import ImageIO
import AppKit
import CryptoKit
import SwiftUI
import ApplicationServices
import UniformTypeIdentifiers

enum ClipboardTagRules {
    static func key(_ tag: String) -> String { tag.lowercased() }
    static func validName(_ tag: String) -> Bool {
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return !tag.isEmpty && tag.count <= 24 && !tag.contains(",") && !tag.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func normalize(_ tags: [String], limit: Int = 8) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validName(tag), seen.insert(key(tag)).inserted else { continue }
            result.append(tag)
            if result.count >= limit { break }
        }
        return result
    }
}

struct ClipboardEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable { case text, link, image, files, richText }
    let id: UUID
    let createdAt: Date
    var kind: Kind
    var text: String
    var payload: Data?
    /// Name of the separately persisted payload. Legacy archives may still have `payload` inline.
    var payloadFileName: String? = nil
    var payloadByteCount: Int? = nil
    var payloadType: String? = nil
    /// Stable content identity used for duplicate detection without loading archived payloads.
    var payloadDigest: String? = nil
    var paths: [String]
    var isPinned: Bool
    var tags: [String]? = nil
    var tagNames: [String] { ClipboardTagRules.normalize(tags ?? []) }
    var isProtected: Bool { isPinned || !tagNames.isEmpty }
    var colorValue: ClipboardColorValue? {
        [.text, .richText].contains(kind) ? ClipboardColorValue.parse(text) : nil
    }
    func matchesSearch(_ query: String, tag: String? = nil) -> Bool {
        if let tag, !tagNames.contains(where: { ClipboardTagRules.key($0) == ClipboardTagRules.key(tag) }) { return false }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || text.localizedCaseInsensitiveContains(query)
            || paths.contains { $0.localizedCaseInsensitiveContains(query) }
            || tagNames.contains { $0.localizedCaseInsensitiveContains(query) }
            || sourceAppName?.localizedCaseInsensitiveContains(query) == true
            || colorValue?.canonicalHex.localizedCaseInsensitiveContains(query) == true
    }
    var sourceAppName: String? = nil
    var sourceBundleIdentifier: String? = nil
    /// A small JPEG preview for image entries, generated once so lists never decode the original.
    var thumbnail: Data? = nil
    /// Runtime-only location of external payloads. It is deliberately excluded from Codable.
    var payloadDirectoryURL: URL? = nil
    var title: String {
        switch kind {
        case .image: return "Image"
        case .files: return paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "\(paths.count) files"
        default: return String(text.prefix(160))
        }
    }
    var symbol: String {
        if colorValue != nil { return "paintpalette.fill" }
        switch kind { case .text: return "text.alignleft"; case .link: return "link"; case .image: return "photo"; case .files: return "doc.on.doc"; case .richText: return "textformat" }
    }
}

extension ClipboardEntry {
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, kind, text, payload, payloadFileName, payloadByteCount, payloadType, payloadDigest
        case paths, isPinned, tags, sourceAppName, sourceBundleIdentifier, thumbnail
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        kind = try values.decode(Kind.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        payload = try values.decodeIfPresent(Data.self, forKey: .payload)
        payloadFileName = try values.decodeIfPresent(String.self, forKey: .payloadFileName)
        payloadByteCount = try values.decodeIfPresent(Int.self, forKey: .payloadByteCount)
        payloadType = try values.decodeIfPresent(String.self, forKey: .payloadType)
        payloadDigest = try values.decodeIfPresent(String.self, forKey: .payloadDigest)
        paths = try values.decode([String].self, forKey: .paths)
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        tags = try values.decodeIfPresent([String].self, forKey: .tags)
        sourceAppName = try values.decodeIfPresent(String.self, forKey: .sourceAppName)
        sourceBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier)
        thumbnail = try values.decodeIfPresent(Data.self, forKey: .thumbnail)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(kind, forKey: .kind)
        try values.encode(text, forKey: .text)
        try values.encodeIfPresent(payload, forKey: .payload)
        try values.encodeIfPresent(payloadFileName, forKey: .payloadFileName)
        try values.encodeIfPresent(payloadByteCount, forKey: .payloadByteCount)
        try values.encodeIfPresent(payloadType, forKey: .payloadType)
        try values.encodeIfPresent(payloadDigest, forKey: .payloadDigest)
        try values.encode(paths, forKey: .paths)
        try values.encode(isPinned, forKey: .isPinned)
        try values.encodeIfPresent(tags, forKey: .tags)
        try values.encodeIfPresent(sourceAppName, forKey: .sourceAppName)
        try values.encodeIfPresent(sourceBundleIdentifier, forKey: .sourceBundleIdentifier)
        try values.encodeIfPresent(thumbnail, forKey: .thumbnail)
    }

    /// Reads an external payload only when an operation actually needs it.
    func resolvedPayloadData() -> Data? {
        if let payload { return payload }
        guard let directory = payloadDirectoryURL,
              let fileName = Self.safePayloadFileName(payloadFileName) else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(fileName), options: .mappedIfSafe)
    }

    var storedPayloadByteCount: Int { payload?.count ?? payloadByteCount ?? 0 }

    static func digest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func safePayloadFileName(_ value: String?) -> String? {
        guard let value, !value.isEmpty,
              value == URL(fileURLWithPath: value).lastPathComponent,
              !value.contains("/") && !value.contains(":") else { return nil }
        return value
    }

    static func == (lhs: ClipboardEntry, rhs: ClipboardEntry) -> Bool {
        let payloadsMatch: Bool
        if let lhsPayload = lhs.payload, let rhsPayload = rhs.payload {
            payloadsMatch = lhsPayload == rhsPayload
        } else if lhs.payload == nil, rhs.payload == nil {
            payloadsMatch = lhs.payloadFileName == rhs.payloadFileName
                && lhs.payloadByteCount == rhs.payloadByteCount
                && lhs.payloadDigest == rhs.payloadDigest
        } else if let lhsDigest = lhs.payloadDigest, let rhsDigest = rhs.payloadDigest {
            payloadsMatch = lhsDigest == rhsDigest && lhs.storedPayloadByteCount == rhs.storedPayloadByteCount
        } else {
            payloadsMatch = false
        }
        return lhs.id == rhs.id && lhs.createdAt == rhs.createdAt && lhs.kind == rhs.kind
            && lhs.text == rhs.text && lhs.paths == rhs.paths && lhs.isPinned == rhs.isPinned
            && lhs.tags == rhs.tags && lhs.sourceAppName == rhs.sourceAppName
            && lhs.sourceBundleIdentifier == rhs.sourceBundleIdentifier && lhs.thumbnail == rhs.thumbnail
            && lhs.payloadType == rhs.payloadType && payloadsMatch
    }
}

@MainActor
final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()
    @Published private(set) var items: [ClipboardEntry] = []
    @Published var isPaused = false { didSet { if loadFailed && !isPaused { isPaused = true } } }
    @Published var status: String?
    private var timer: Timer?
    private let pasteboard: NSPasteboard
    private var changeCount: Int
    private var lastExternalApp: NSRunningApplication?
    private let historyURL: URL
    private let payloadDirectoryURL: URL
    private var loadFailed = false
    private let maxPayload = 5 * 1024 * 1024
    private var persistenceRevision: UInt64 = 0

    init(historyURL: URL? = nil, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.historyURL = historyURL ?? base.appendingPathComponent("SuperNotch/clipboard-history.json")
        self.payloadDirectoryURL = self.historyURL.deletingLastPathComponent().appendingPathComponent("clipboard-payloads-v1", isDirectory: true)
        if FileManager.default.fileExists(atPath: self.historyURL.path) {
            do {
                let entries = try JSONDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: self.historyURL))
                items = Array(entries.prefix(200)).map { item in
                    var item = item
                    if item.tags != nil { item.tags = item.tagNames }
                    item.payloadDirectoryURL = self.payloadDirectoryURL
                    if item.payloadByteCount == nil, let fileName = ClipboardEntry.safePayloadFileName(item.payloadFileName),
                       let size = try? FileManager.default.attributesOfItem(atPath: self.payloadDirectoryURL.appendingPathComponent(fileName).path)[.size] as? NSNumber {
                        item.payloadByteCount = size.intValue
                    }
                    return item
                }
            } catch {
                loadFailed = true
                isPaused = true
                status = "Could not read clipboard history. The file is preserved and capture is paused until it is restored."
            }
        }
        // Legacy inline payloads are migrated after launch. The original archive stays intact
        // until every payload file and the replacement metadata archive are safely written.
        if items.contains(where: { $0.payload != nil || $0.payloadFileName != nil && $0.payloadDigest == nil }) { persist() }
    }

    func startMonitoring() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopMonitoring() { timer?.invalidate(); timer = nil }

    func rememberPasteDestination() {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = front
        }
    }

    var pasteDestinationName: String? {
        guard let lastExternalApp, !lastExternalApp.isTerminated else { return nil }
        return lastExternalApp.localizedName
    }

    private func checkPasteboard() {
        rememberPasteDestination()
        let board = pasteboard
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        guard !isPaused, !loadFailed else { return }
        let types = (board.types ?? []).map { $0.rawValue.lowercased() }
        guard !types.contains(where: { $0.contains("concealed") || $0.contains("transient") || $0.contains("password") || $0.contains("autogenerated") || $0.contains("org.nspasteboard.source") && board.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))?.lowercased().contains("1password") == true }) else { return }
        var kind: ClipboardEntry.Kind = .text
        var text = board.string(forType: .string) ?? ""
        var payload: Data?
        var payloadType: String?
        var paths: [String] = []
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            paths = urls.map(\.path)
            kind = .files
            text = urls.map(\.lastPathComponent).joined(separator: "\n")
        } else if let imageData = board.data(forType: .png) {
            guard imageData.count <= maxPayload else { status = "Image exceeds the 5 MB history limit."; return }
            kind = .image
            payload = imageData
            payloadType = NSPasteboard.PasteboardType.png.rawValue
        } else if let imageData = board.data(forType: .tiff) {
            guard imageData.count <= maxPayload else { status = "Image exceeds the 5 MB history limit."; return }
            kind = .image
            payload = imageData
            payloadType = NSPasteboard.PasteboardType.tiff.rawValue
        } else if let richData = board.data(forType: .rtf), richData.count <= maxPayload {
            kind = .richText
            payload = richData
            payloadType = NSPasteboard.PasteboardType.rtf.rawValue
            if text.isEmpty { text = (try? NSAttributedString(data: richData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string) ?? "Formatted text" }
        } else {
            guard !text.isEmpty else { return }
            guard text.utf8.count <= maxPayload else { status = "Text exceeds the 5 MB history limit."; return }
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""), !text.contains("\n") { kind = .link }
        }
        let payloadDigest = payload.map(ClipboardEntry.digest(for:))
        if let index = items.firstIndex(where: {
            guard $0.kind == kind, $0.text == text, $0.paths == paths else { return false }
            guard let payload else { return $0.storedPayloadByteCount == 0 }
            return $0.storedPayloadByteCount == payload.count && $0.payloadDigest == payloadDigest
        }) {
            let existing = items.remove(at: index)
            items.insert(existing, at: 0)
        } else {
            let sourceApp = NSWorkspace.shared.frontmostApplication
            let entry = ClipboardEntry(id: UUID(), createdAt: Date(), kind: kind, text: text, payload: payload, payloadByteCount: payload?.count, payloadType: payloadType, payloadDigest: payloadDigest, paths: paths, isPinned: false, sourceAppName: sourceApp?.localizedName, sourceBundleIdentifier: sourceApp?.bundleIdentifier, payloadDirectoryURL: payloadDirectoryURL)
            items.insert(entry, at: 0)
            if kind == .image { prepareThumbnail(for: entry) }
        }
        trimHistory()
        persist()
    }

    private func trimHistory() {
        while items.count > 200, let index = items.lastIndex(where: { !$0.isProtected }) { items.remove(at: index) }
        var bytes = items.reduce(0) { $0 + $1.storedPayloadByteCount + $1.text.utf8.count }
        while bytes > 40 * 1024 * 1024, let index = items.lastIndex(where: { !$0.isProtected }) {
            let removed = items.remove(at: index)
            bytes -= removed.storedPayloadByteCount + removed.text.utf8.count
        }
    }

    var allTags: [String] {
        var seen = Set<String>()
        return items.flatMap(\.tagNames).filter { seen.insert(ClipboardTagRules.key($0)).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    @discardableResult func setTags(_ tags: [String], for item: ClipboardEntry) -> Bool {
        guard !loadFailed else { return false }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { status = "This clipboard entry is no longer available."; return false }
        guard tags.allSatisfy(ClipboardTagRules.validName) else { status = "Tags need 1–24 characters, without commas or line breaks."; return false }
        let normalized = ClipboardTagRules.normalize(tags, limit: 9)
        guard normalized.count <= 8 else { status = "Use up to eight tags per entry."; return false }
        guard normalized.isEmpty || items[index].isProtected || items.filter(\.isProtected).count < 30 else { status = "Keep up to 30 pinned or tagged entries. Unpin or untag an entry first."; return false }
        items[index].tags = normalized.isEmpty ? nil : normalized
        status = nil
        trimHistory()
        persist()
        return true
    }
    func togglePin(_ item: ClipboardEntry) {
        guard !loadFailed, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard items[index].isProtected || items.filter(\.isProtected).count < 30 else { status = "Keep up to 30 pinned or tagged entries. Unpin or untag an entry first."; return }
        items[index].isPinned.toggle()
        trimHistory()
        persist()
    }
    func delete(_ item: ClipboardEntry) { guard !loadFailed else { return }; items.removeAll { $0.id == item.id }; persist() }
    func clearUnpinned() { guard !loadFailed else { return }; items.removeAll { !$0.isProtected }; persist() }
    @discardableResult func copy(_ item: ClipboardEntry) -> Bool {
        let imagePayload = item.kind == .image ? item.resolvedPayloadData() : nil
        if item.kind == .image, imagePayload == nil {
            status = "This image payload is missing from clipboard history."
            return false
        }
        let board = pasteboard
        board.clearContents()
        switch item.kind {
        case .files: board.writeObjects(item.paths.map { NSURL(fileURLWithPath: $0) })
        case .image:
            let data = imagePayload!
            board.setData(data, forType: Self.imagePasteboardType(storedType: item.payloadType, data: data))
        case .richText:
            if let data = item.resolvedPayloadData() { board.setData(data, forType: .rtf) }
            board.setString(item.text, forType: .string)
        case .text, .link: board.setString(item.text, forType: .string)
        }
        changeCount = board.changeCount
        status = "Copied to clipboard"
        return true
    }
    private static func imagePasteboardType(storedType: String?, data: Data) -> NSPasteboard.PasteboardType {
        if storedType == NSPasteboard.PasteboardType.png.rawValue { return .png }
        if storedType == NSPasteboard.PasteboardType.tiff.rawValue { return .tiff }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return .png }
        return UTType(type as String)?.conforms(to: .tiff) == true ? .tiff : .png
    }
    func paste(_ item: ClipboardEntry) {
        guard AXIsProcessTrusted() else {
            status = "Enable SuperNotch in System Settings → Privacy & Security → Accessibility to paste directly."
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            return
        }
        guard let app = lastExternalApp, !app.isTerminated else { status = "Switch to a destination app first, then reopen clipboard history."; return }
        guard copy(item) else { return }
        app.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
    private func prepareThumbnail(for entry: ClipboardEntry) {
        Task { [weak self] in
            guard let generated = await ClipboardThumbnailCache.load(entry)?.generated else { return }
            self?.attachThumbnail(generated, to: entry.id)
        }
    }

    /// Stores a generated preview for an image entry. Previews are derived data and never change order or pins.
    func attachThumbnail(_ data: Data, to id: UUID) {
        guard !loadFailed, let index = items.firstIndex(where: { $0.id == id }), items[index].thumbnail == nil else { return }
        items[index].thumbnail = data
        persist()
    }

    /// Coalesces bursts of changes, then encodes and writes the history off the main thread.
    private func persist() {
        guard !loadFailed else { return }
        persistenceRevision &+= 1
        pendingPersist?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeHistory(synchronously: false) }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Writes any pending change now and waits for it; used at termination and by tests.
    func flushPendingWrites() {
        if pendingPersist != nil { writeHistory(synchronously: true) }
        Self.persistQueue.sync {}
    }

    private func writeHistory(synchronously: Bool) {
        pendingPersist?.cancel(); pendingPersist = nil
        let snapshot = items
        let revision = persistenceRevision
        let url = historyURL
        let payloadDirectoryURL = payloadDirectoryURL
        let write: @Sendable () -> PersistResult = {
            do {
                let persisted = try Self.externalizingPayloads(in: snapshot, to: payloadDirectoryURL)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(persisted)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                Self.removeUnreferencedPayloads(in: payloadDirectoryURL, keeping: persisted)
                return .success(persisted)
            } catch {
                return .failure("Could not save clipboard history: \(error.localizedDescription)")
            }
        }
        if synchronously {
            apply(Self.persistQueue.sync(execute: write), revision: revision)
        } else {
            Self.persistQueue.async { [weak self] in
                let result = write()
                DispatchQueue.main.async { self?.apply(result, revision: revision) }
            }
        }
    }

    private enum PersistResult: Sendable {
        case success([ClipboardEntry])
        case failure(String)
    }

    private func apply(_ result: PersistResult, revision: UInt64) {
        switch result {
        case .failure(let message): status = message
        case .success(let persisted):
            // A newer edit owns the current in-memory snapshot. Its queued write will externalize
            // any still-inline data, so an older completion must not overwrite it.
            guard persistenceRevision == revision else { return }
            let byID = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
            for index in items.indices {
                guard let saved = byID[items[index].id] else { continue }
                if items[index].payload != nil {
                    items[index].payload = nil
                    items[index].payloadFileName = saved.payloadFileName
                    items[index].payloadByteCount = saved.payloadByteCount
                    items[index].payloadType = saved.payloadType
                    items[index].payloadDirectoryURL = payloadDirectoryURL
                }
                if items[index].payloadDigest == nil {
                    items[index].payloadDigest = saved.payloadDigest
                }
            }
        }
    }

    private nonisolated static func externalizingPayloads(in entries: [ClipboardEntry], to directory: URL) throws -> [ClipboardEntry] {
        var result: [ClipboardEntry] = []
        result.reserveCapacity(entries.count)
        for original in entries {
            var entry = original
            entry.payloadDirectoryURL = directory
            if let payload = entry.payload {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let fileName = ClipboardEntry.safePayloadFileName(entry.payloadFileName) ?? "\(entry.id.uuidString.lowercased()).payload"
                let payloadURL = directory.appendingPathComponent(fileName)
                try payload.write(to: payloadURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payloadURL.path)
                entry.payloadFileName = fileName
                entry.payloadByteCount = payload.count
                entry.payloadDigest = entry.payloadDigest ?? ClipboardEntry.digest(for: payload)
                entry.payload = nil
            } else if entry.payloadDigest == nil,
                      let fileName = ClipboardEntry.safePayloadFileName(entry.payloadFileName) {
                let payloadURL = directory.appendingPathComponent(fileName)
                entry.payloadDigest = autoreleasepool {
                    (try? Data(contentsOf: payloadURL, options: .mappedIfSafe)).map(ClipboardEntry.digest(for:))
                }
            }
            result.append(entry)
        }
        return result
    }

    private nonisolated static func removeUnreferencedPayloads(in directory: URL, keeping entries: [ClipboardEntry]) {
        let retained = Set(entries.compactMap { ClipboardEntry.safePayloadFileName($0.payloadFileName) })
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        for file in files where !retained.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }

    private nonisolated static let persistQueue = DispatchQueue(label: "app.supernotch.clipboard.persist", qos: .utility)
    private var pendingPersist: DispatchWorkItem?
}

@MainActor
struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardStore
    @State private var search = ""
    @State private var filter = "All"
    @State private var tagFilter: String?
    @State private var confirmClear = false
    init(store: ClipboardStore? = nil) { self.store = store ?? .shared }
    private var filtered: [ClipboardEntry] {
        store.items.filter { item in
            (filter == "All" || filter == "Pinned" && item.isPinned || filter == "Text" && [.text, .richText, .link].contains(item.kind) || filter == "Images" && item.kind == .image || filter == "Files" && item.kind == .files || filter == "Colors" && item.colorValue != nil) && item.matchesSearch(search, tag: tagFilter)
        }.sorted { $0.isPinned && !$1.isPinned }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                WorkspaceSearchField(text: $search, prompt: "Search clipboard")
                ClipboardTagFilter(store: store, selection: $tagFilter).fixedSize()
                Spacer(minLength: 0)
                Button { store.isPaused.toggle() } label: { Label(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill") }
                    .buttonStyle(PillButtonStyle()).help(store.isPaused ? "Resume capture" : "Pause capture")
                Button { confirmClear = true } label: { Label("Clear", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle()).help("Clear unpinned, untagged history")
            }
            ChipPicker(options: ["All", "Pinned", "Text", "Images", "Files", "Colors"].map { ($0, $0) }, selection: $filter)
            if store.isPaused { InlineMessage(text: "Clipboard capture is paused. New copies are not saved until you resume.", tone: .orange) }
            if filtered.isEmpty {
                Group {
                    if store.items.isEmpty {
                        ContentUnavailableView("No Copies Yet", systemImage: "list.clipboard", description: Text("Copy text, links, images or files. Content marked private is ignored."))
                    } else if !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ContentUnavailableView("No Matching Items", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try another kind or tag filter."))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 10, alignment: .top)], spacing: 10) {
                        ForEach(filtered) { item in ClipboardCard(item: item, store: store) }
                    }
                }.frame(minHeight: 150)
            }
            if let status = store.status { InlineMessage(text: status) { store.status = nil } }
        }.padding(.horizontal, 20).padding(.bottom, 20).onAppear { store.startMonitoring() }
        .alert("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { store.clearUnpinned() }
        } message: { Text("Entries without pins or tags will be removed from this Mac. Pinned and tagged entries stay saved.") }
    }
}

@MainActor
private struct ClipboardCard: View {
    let item: ClipboardEntry
    @ObservedObject var store: ClipboardStore
    @State private var tagEditor: ClipboardEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: item.symbol).foregroundStyle(.tint)
                Text(item.colorValue != nil ? "Color" : item.kind == .richText ? "Formatted Text" : item.kind.rawValue.capitalized).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if item.isPinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange) }
                RelativeTimeText(date: item.createdAt).font(.caption).foregroundStyle(.tertiary)
            }
            if let color = item.colorValue {
                ClipboardColorSwatch(value: color, compact: true)
            } else if item.kind == .image {
                ClipboardImagePreview(item: item).clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text(item.title).font(.body).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !item.tagNames.isEmpty { ClipboardTagBadges(tags: item.tagNames) }
            HStack(spacing: 12) {
                Spacer()
                Button { store.delete(item) } label: { Image(systemName: "trash") }
            }.font(.callout).buttonStyle(.borderless).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading).cardStyle(padding: 12)
        .sheet(item: $tagEditor) { entry in ClipboardTagEditor(store: store, entry: entry) }
        .contextMenu {
            Button("Edit tags…") { tagEditor = item }
            Button("Copy") { store.copy(item) }
            Button("Paste into previous app") { store.paste(item) }
            Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Button("Delete", role: .destructive) { store.delete(item) }
        }
    }
}

/// Clipboard image previews.
///
/// Entries carry a small persisted JPEG thumbnail. Only entries without one decode their original,
/// once, on a serial background queue; the result is saved so it never happens again.
enum ClipboardThumbnailCache {
    private static let queue = DispatchQueue(label: "app.supernotch.clipboard.thumbnails", qos: .userInitiated)
    nonisolated(unsafe) private static let cache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    static let maxPixel = 480

    static func cached(_ id: UUID) -> NSImage? { cache.object(forKey: id as NSUUID) }

    /// Returns the preview, plus JPEG data when a new thumbnail had to be generated.
    static func load(_ item: ClipboardEntry) async -> (image: NSImage, generated: Data?)? {
        if let cached = cached(item.id) { return (cached, nil) }
        let id = item.id, thumbnail = item.thumbnail
        return await withCheckedContinuation { continuation in
            queue.async {
                let result: (NSImage, Data?)? = autoreleasepool {
                    if let thumbnail, let decoded = decodePreview(thumbnail) {
                        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                        store(image, id: id, cost: decoded.bytesPerRow * decoded.height)
                        return (image, nil)
                    }
                    guard let payload = item.resolvedPayloadData(),
                          let generated = makeThumbnail(from: payload),
                          let decoded = decodePreview(generated) else { return nil }
                    let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                    store(image, id: id, cost: decoded.bytesPerRow * decoded.height)
                    return (image, generated)
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Downsamples image data to a small JPEG.
    static func makeThumbnail(from data: Data) -> Data? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            // JPEG has no alpha: flatten onto a dark ground that suits the clipboard surfaces.
            let width = cgImage.width, height = cgImage.height
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.setFillColor(CGColor(gray: 0.12, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let flattened = context.makeImage() else { return nil }
            CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }
    }

    /// Forces the bounded JPEG raster to decode on the thumbnail queue instead of during SwiftUI drawing.
    private static func decodePreview(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private static func store(_ image: NSImage, id: UUID, cost: Int) {
        cache.setObject(image, forKey: id as NSUUID, cost: cost)
    }
}

/// An asynchronously decoded clipboard image preview.
struct ClipboardImagePreview: View {
    let item: ClipboardEntry
    var maxHeight: CGFloat = 130
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image = image ?? ClipboardThumbnailCache.cached(item.id) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo").font(.title2).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05)).frame(height: min(maxHeight, 90)).overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .task(id: item.id) {
            guard image == nil else { return }
            let result = await ClipboardThumbnailCache.load(item)
            image = result?.image
            failed = result == nil
            if let generated = result?.generated { ClipboardStore.shared.attachThumbnail(generated, to: item.id) }
        }
    }
}
