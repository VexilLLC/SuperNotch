import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum CommandPaletteBuiltinAction: String, CaseIterable, Codable, Hashable, Sendable {
    case clipboard
    case island
    case shelf
    case basket
    case notes
    case agenda
    case focus
    case workspace
    case settings
    case commandRunner
    case allFeatures
    case extensionManager
    case extensionsFolder
}

struct SavedPaletteCommand: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var command: String
    var workingDirectory: String?
    var keywords: [String] = []
    var symbol: String = "terminal.fill"
}

struct CommandPaletteExtensionDocument: Codable, Equatable, Sendable {
    let version: Int
    let id: String
    let name: String
    let description: String?
    let commands: [CommandPaletteExtensionCommand]
}

struct CommandPaletteExtensionCommand: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let subtitle: String?
    let symbol: String?
    let keywords: [String]?
    let action: CommandPaletteManifestAction
}

struct InstalledPaletteExtension: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let commandCount: Int
    let fileURL: URL
}

private enum ExtensionInstallationError: LocalizedError {
    case alreadyInstalled(String)
    case limitReached

    var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let name): "\(name) is already installed."
        case .limitReached: "SuperNotch supports up to 50 extensions and 200 extension commands."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct CommandPaletteManifestAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case builtin, shell, url }
    let type: Kind
    let value: String
    let workingDirectory: String?
}

enum CommandPaletteExtensionValidation {
    enum Failure: LocalizedError, Equatable {
        case unsupportedVersion
        case invalidIdentifier
        case invalidName
        case tooManyCommands
        case duplicateCommandIdentifier
        case invalidAction

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "Only extension manifest version 1 is supported."
            case .invalidIdentifier: "Extension and command IDs must use letters, numbers, dots, dashes, or underscores."
            case .invalidName: "Extension and command names must contain 1–80 visible characters."
            case .tooManyCommands: "An extension can contain at most 50 commands."
            case .duplicateCommandIdentifier: "Every command in an extension must have a unique ID."
            case .invalidAction: "An extension action is invalid or exceeds its size limit."
            }
        }
    }

    static func validate(_ document: CommandPaletteExtensionDocument) throws {
        guard document.version == 1 else { throw Failure.unsupportedVersion }
        guard validIdentifier(document.id) else { throw Failure.invalidIdentifier }
        guard validName(document.name) else { throw Failure.invalidName }
        guard document.commands.count <= 50 else { throw Failure.tooManyCommands }
        var identifiers = Set<String>()
        for command in document.commands {
            guard validIdentifier(command.id) else { throw Failure.invalidIdentifier }
            guard identifiers.insert(command.id).inserted else { throw Failure.duplicateCommandIdentifier }
            guard validName(command.name) else { throw Failure.invalidName }
            guard command.action.value.count <= 4_096 else { throw Failure.invalidAction }
            switch command.action.type {
            case .builtin:
                guard CommandPaletteBuiltinAction(rawValue: command.action.value) != nil else { throw Failure.invalidAction }
            case .shell:
                guard !command.action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidAction }
            case .url:
                guard let url = URL(string: command.action.value), let scheme = url.scheme?.lowercased(),
                      !["file", "javascript", "data"].contains(scheme) else { throw Failure.invalidAction }
            }
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0) }
    }

    private static func validName(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.count <= 80 && !clean.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

enum CommandPaletteSearch {
    static func score(query: String, title: String, subtitle: String, keywords: [String]) -> Int? {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return 0 }
        let title = title.lowercased()
        let subtitle = subtitle.lowercased()
        let keywords = keywords.map { $0.lowercased() }
        var total = 0
        for term in terms {
            if title == term { total += 240 }
            else if title.hasPrefix(term) { total += 170 }
            else if title.split(separator: " ").contains(where: { $0.hasPrefix(term) }) { total += 130 }
            else if title.contains(term) { total += 95 }
            else if keywords.contains(where: { $0.hasPrefix(term) }) { total += 80 }
            else if keywords.contains(where: { $0.contains(term) }) { total += 55 }
            else if subtitle.contains(term) { total += 35 }
            else if isSubsequence(term, of: title) { total += 20 }
            else { return nil }
        }
        return total
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var index = needle.startIndex
        for character in haystack where index < needle.endIndex && character == needle[index] {
            index = needle.index(after: index)
        }
        return index == needle.endIndex
    }
}

fileprivate enum CommandPaletteAction {
    case builtin(CommandPaletteBuiltinAction)
    case application(URL)
    case shell(command: String, workingDirectory: String?)
    case url(URL)
}

fileprivate enum CommandPaletteItemKind: String {
    case command = "Command"
    case custom = "Custom Command"
    case application = "Application"
    case extensionCommand = "Extension"
}

fileprivate struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let kind: CommandPaletteItemKind
    let keywords: [String]
    let applicationURL: URL?
    let action: CommandPaletteAction
    /// Tint of the rounded icon tile; applications draw their own icon instead.
    var tint: Color = PaletteTheme.accent
}

fileprivate struct CommandPaletteDisplayItem: Identifiable {
    let item: CommandPaletteItem
    let section: String
    var id: String { item.id }
}

/// Raw values are persisted so the palette can reopen where it was left.
enum CommandPaletteLevel: String, Equatable { case root, clipboard }

enum CommandPaletteClipboardFilter: String, CaseIterable, Identifiable {
    case all = "All Types"
    case text = "Text"
    case links = "Links"
    case images = "Images"
    case files = "Files"
    var id: String { rawValue }
}

@MainActor
final class CommandPaletteStore: ObservableObject {
    static let shared = CommandPaletteStore()

    @Published var query = ""
    @Published var selectedID: String?
    @Published var level: CommandPaletteLevel = .root
    @Published var clipboardFilter: CommandPaletteClipboardFilter = .all
    @Published var selectedClipboardID: UUID?
    @Published private(set) var customCommands: [SavedPaletteCommand] = []
    @Published private(set) var extensionCount = 0
    @Published private(set) var installedExtensions: [InstalledPaletteExtension] = []
    @Published var showingExtensionBuilder = false
    @Published var message: String?

    private let commandsURL: URL
    private let defaults: UserDefaults
    let extensionsURL: URL
    private var applications: [URL] = []
    private var extensionItems: [CommandPaletteItem] = []
    private var customLoadFailed = false
    private var recentIDs: [String]

    init(baseURL: URL? = nil, defaults: UserDefaults = .standard) {
        let base = baseURL ?? SuperNotchStorage.baseDirectory
        commandsURL = base.appendingPathComponent("palette-commands.json")
        extensionsURL = base.appendingPathComponent("Extensions", isDirectory: true)
        self.defaults = defaults
        recentIDs = defaults.stringArray(forKey: Self.recentIDsKey) ?? []
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: extensionsURL, withIntermediateDirectories: true)
        loadCustomCommands()
        loadApplications()
        reloadExtensions()
    }

    fileprivate var displayItems: [CommandPaletteDisplayItem] {
        let all = allItems
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty {
            let scored = all.compactMap { item -> (CommandPaletteItem, Int)? in
                CommandPaletteSearch.score(query: clean, title: item.title, subtitle: item.subtitle, keywords: item.keywords).map { (item, $0) }
            }.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.kind != rhs.0.kind { return kindOrder(lhs.0.kind) < kindOrder(rhs.0.kind) }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            return scored.prefix(80).map { CommandPaletteDisplayItem(item: $0.0, section: section(for: $0.0.kind)) }
        }

        let indexed = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let defaults = ["builtin.clipboard", "builtin.shelf", "builtin.focus", "builtin.commandRunner", "builtin.settings"]
        var seen = Set<String>()
        let suggestions = (recentIDs + defaults).compactMap { id -> CommandPaletteItem? in
            guard seen.insert(id).inserted else { return nil }
            return indexed[id]
        }.prefix(7)
        let suggestionIDs = Set(suggestions.map(\.id))
        let remainder = all.filter { !suggestionIDs.contains($0.id) }
        return suggestions.map { CommandPaletteDisplayItem(item: $0, section: "Suggestions") }
            + remainder.prefix(80).map { CommandPaletteDisplayItem(item: $0, section: section(for: $0.kind)) }
    }

    fileprivate var selectedItem: CommandPaletteItem? {
        guard let selectedID else { return nil }
        return displayItems.first(where: { $0.id == selectedID })?.item
    }

    var clipboardItems: [ClipboardEntry] {
        ClipboardStore.shared.items.filter { item in
            let matchesType: Bool
            switch clipboardFilter {
            case .all: matchesType = true
            case .text: matchesType = [.text, .richText].contains(item.kind)
            case .links: matchesType = item.kind == .link
            case .images: matchesType = item.kind == .image
            case .files: matchesType = item.kind == .files
            }
            return matchesType && item.matchesSearch(query)
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.createdAt > $1.createdAt
        }
    }

    /// Reopens the palette where it was last dismissed, so a command with its
    /// own level — clipboard history today — comes back instead of the root list.
    func beginSession() {
        query = ""
        clipboardFilter = .all
        selectedClipboardID = nil
        reloadExtensions()
        message = nil
        if CommandPaletteLevel(rawValue: defaults.string(forKey: Self.lastLevelKey) ?? "") == .clipboard {
            enterClipboard()
        } else {
            level = .root
            selectedID = displayItems.first?.id
        }
    }

    /// Records the level the palette is dismissed in. Called for every close
    /// path: escape, running a command, and losing key focus.
    func endSession() {
        defaults.set(level.rawValue, forKey: Self.lastLevelKey)
    }

    func queryDidChange() {
        if level == .clipboard {
            reconcileClipboardSelection()
            return
        }
        let ids = displayItems.map(\.id)
        if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.first }
    }

    func moveSelection(by offset: Int) {
        if level == .clipboard {
            let items = clipboardItems
            guard !items.isEmpty else { selectedClipboardID = nil; return }
            let current = selectedClipboardID.flatMap { id in items.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : items.count)
            selectedClipboardID = items[min(max(current + offset, 0), items.count - 1)].id
            return
        }
        let items = displayItems
        guard !items.isEmpty else { selectedID = nil; return }
        let current = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : items.count)
        selectedID = items[min(max(current + offset, 0), items.count - 1)].id
    }

    func executeSelected() {
        if level == .clipboard {
            guard let selectedClipboardID, let item = clipboardItems.first(where: { $0.id == selectedClipboardID }) else { return }
            CommandPaletteController.shared.hide()
            ClipboardStore.shared.paste(item)
            return
        }
        guard let selectedID, let item = displayItems.first(where: { $0.id == selectedID })?.item else { return }
        execute(item)
    }

    func enterClipboard() {
        level = .clipboard
        query = ""
        clipboardFilter = .all
        ClipboardStore.shared.startMonitoring()
        selectedClipboardID = clipboardItems.first?.id
    }

    func leaveClipboard() {
        level = .root
        query = ""
        selectedClipboardID = nil
        selectedID = displayItems.first?.id
    }

    func clipboardFilterDidChange() { reconcileClipboardSelection() }

    func executeCustomCommand(_ command: SavedPaletteCommand) {
        execute(CommandPaletteItem(
            id: "custom.\(command.id.uuidString)", title: command.name, subtitle: command.command,
            symbol: command.symbol, kind: .custom, keywords: command.keywords,
            applicationURL: nil, action: .shell(command: command.command, workingDirectory: command.workingDirectory)
        ))
    }

    @discardableResult
    func addCustomCommand(name: String, command: String, workingDirectory: String? = nil) -> Bool {
        guard !customLoadFailed else { message = "The custom-command archive could not be read, so it was not overwritten."; return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !command.isEmpty, command.count <= 4_096 else {
            message = "Use a name up to 80 characters and a command up to 4,096 characters."
            return false
        }
        customCommands.append(SavedPaletteCommand(name: name, command: command, workingDirectory: normalizedDirectory(workingDirectory), keywords: name.split(separator: " ").map(String.init)))
        customCommands.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistCustomCommands()
        return true
    }

    func deleteCustomCommand(_ command: SavedPaletteCommand) {
        guard !customLoadFailed else { return }
        customCommands.removeAll { $0.id == command.id }
        persistCustomCommands()
    }

    func revealExtensionsFolder() {
        try? FileManager.default.createDirectory(at: extensionsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(extensionsURL)
    }

    func chooseExtensionManifest() {
        let panel = NSOpenPanel()
        panel.title = "Add a SuperNotch Extension"
        panel.message = "Choose a version-1 SuperNotch extension manifest. It will be validated before installation."
        panel.prompt = "Add Extension"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try installExtension(from: url)
        } catch {
            message = "Could not add extension: \(error.localizedDescription)"
        }
    }

    func installExtension(from sourceURL: URL) throws {
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 262_144 else {
            throw CommandPaletteExtensionValidation.Failure.invalidAction
        }
        try installExtension(data: Data(contentsOf: sourceURL))
    }

    func installExtension(data: Data) throws {
        guard data.count <= 262_144 else { throw CommandPaletteExtensionValidation.Failure.invalidAction }
        let document = try JSONDecoder().decode(CommandPaletteExtensionDocument.self, from: data)
        try CommandPaletteExtensionValidation.validate(document)
        guard installedExtensions.count < 50,
              installedExtensions.reduce(0, { $0 + $1.commandCount }) + document.commands.count <= 200 else {
            throw ExtensionInstallationError.limitReached
        }
        guard !installedExtensions.contains(where: { $0.id == document.id }) else {
            throw ExtensionInstallationError.alreadyInstalled(document.name)
        }
        try FileManager.default.createDirectory(at: extensionsURL, withIntermediateDirectories: true)
        let destination = extensionsURL.appendingPathComponent(document.id).appendingPathExtension("json")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExtensionInstallationError.alreadyInstalled(document.name)
        }
        try data.write(to: destination, options: [.atomic])
        reloadExtensions()
        message = "Added \(document.name) with \(document.commands.count) command\(document.commands.count == 1 ? "" : "s")."
    }

    @discardableResult
    func createExtension(
        name: String,
        identifier: String,
        description: String,
        commandName: String,
        commandIdentifier: String,
        subtitle: String,
        symbol: String,
        keywords: String,
        actionType: CommandPaletteManifestAction.Kind,
        actionValue: String,
        workingDirectory: String?
    ) -> Bool {
        let document = CommandPaletteExtensionDocument(
            version: 1,
            id: identifier.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            commands: [CommandPaletteExtensionCommand(
                id: commandIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
                name: commandName.trimmingCharacters(in: .whitespacesAndNewlines),
                subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                keywords: keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                action: CommandPaletteManifestAction(
                    type: actionType,
                    value: actionValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    workingDirectory: workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                )
            )]
        )
        do {
            try CommandPaletteExtensionValidation.validate(document)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try installExtension(data: encoder.encode(document))
            return true
        } catch {
            message = "Could not add extension: \(error.localizedDescription)"
            return false
        }
    }

    func reloadExtensions() {
        extensionItems = []
        extensionCount = 0
        installedExtensions = []
        var failures: [String] = []
        let manager = FileManager.default
        let urls = ((try? manager.contentsOfDirectory(at: extensionsURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(50)
        var totalCommands = 0
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 262_144 else { throw CommandPaletteExtensionValidation.Failure.invalidAction }
                let document = try JSONDecoder().decode(CommandPaletteExtensionDocument.self, from: Data(contentsOf: url))
                try CommandPaletteExtensionValidation.validate(document)
                guard totalCommands + document.commands.count <= 200 else { throw CommandPaletteExtensionValidation.Failure.tooManyCommands }
                totalCommands += document.commands.count
                extensionCount += 1
                installedExtensions.append(InstalledPaletteExtension(
                    id: document.id,
                    name: document.name,
                    description: document.description,
                    commandCount: document.commands.count,
                    fileURL: url
                ))
                for command in document.commands {
                    guard let action = manifestAction(command.action) else { continue }
                    extensionItems.append(CommandPaletteItem(
                        id: "extension.\(document.id).\(command.id)", title: command.name,
                        subtitle: command.subtitle ?? document.name, symbol: command.symbol ?? "puzzlepiece.extension.fill",
                        kind: .extensionCommand, keywords: (command.keywords ?? []) + [document.name, document.id],
                        applicationURL: nil, action: action, tint: .purple
                    ))
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        installedExtensions.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !failures.isEmpty { message = failures.prefix(3).joined(separator: "\n") }
    }

    private var allItems: [CommandPaletteItem] {
        let custom = customCommands.map { command in
            CommandPaletteItem(
                id: "custom.\(command.id.uuidString)", title: command.name, subtitle: command.command,
                symbol: command.symbol, kind: .custom, keywords: command.keywords,
                applicationURL: nil, action: .shell(command: command.command, workingDirectory: command.workingDirectory),
                tint: .green
            )
        }
        let apps = applications.map { url in
            CommandPaletteItem(
                id: "application.\(url.path)", title: url.deletingPathExtension().lastPathComponent,
                subtitle: url.deletingLastPathComponent().path, symbol: "app.fill", kind: .application,
                keywords: ["app", "application", url.lastPathComponent], applicationURL: url, action: .application(url)
            )
        }
        return Self.builtinItems + custom + extensionItems + apps
    }

    private static let builtinItems: [CommandPaletteItem] = [
        builtin(.clipboard, "Clipboard History", "Search and paste recent clipboard items", "list.clipboard.fill", ["copy", "paste", "history"], .blue),
        builtin(.island, "Open Island", "Expand SuperNotch", "rectangle.topthird.inset.filled", ["notch", "home"], PaletteTheme.accent),
        builtin(.shelf, "File Shelf", "Open saved files and baskets", "tray.full.fill", ["files", "tray", "stash"], .teal),
        builtin(.basket, "Floating Basket", "Open the active basket", "basket.fill", ["files", "drop"], .orange),
        builtin(.notes, "Quick Notes", "Capture or edit a note", "note.text", ["write", "memo"], .yellow),
        builtin(.agenda, "Agenda", "Show calendar events and reminders", "calendar", ["events", "tasks"], .red),
        builtin(.focus, "Focus Timer", "Start or manage a focus session", "timer", ["pomodoro", "break"], .pink),
        builtin(.workspace, "Open Workspace", "Browse every SuperNotch tool", "square.grid.2x2.fill", ["dashboard", "home"], .indigo),
        builtin(.commandRunner, "Command Runner", "Run a shell command and inspect its output", "terminal.fill", ["shell", "terminal", "zsh"], Color(white: 0.35)),
        builtin(.allFeatures, "All Features", "Browse available and planned tools", "puzzlepiece.extension.fill", ["extensions", "tools"], .purple),
        builtin(.extensionManager, "Add Extension", "Create or import a command palette extension", "puzzlepiece.extension.badge.plus", ["install", "plugin", "custom", "manifest"], .purple),
        builtin(.settings, "SuperNotch Settings", "Change appearance, widgets and preferences", "gearshape.fill", ["preferences", "configure"], Color(white: 0.35)),
        builtin(.extensionsFolder, "Open Extensions Folder", "Install or inspect local command manifests", "folder.badge.gearshape", ["plugins", "custom", "manifest"], .brown)
    ]

    private static func builtin(_ action: CommandPaletteBuiltinAction, _ title: String, _ subtitle: String, _ symbol: String, _ keywords: [String], _ tint: Color) -> CommandPaletteItem {
        CommandPaletteItem(id: "builtin.\(action.rawValue)", title: title, subtitle: subtitle, symbol: symbol, kind: .command, keywords: keywords, applicationURL: nil, action: .builtin(action), tint: tint)
    }

    private func execute(_ item: CommandPaletteItem) {
        remember(item.id)
        if case .builtin(.clipboard) = item.action {
            enterClipboard()
            return
        }
        CommandPaletteController.shared.hide()
        switch item.action {
        case .application(let url):
            if !NSWorkspace.shared.open(url) { message = "Could not open \(url.lastPathComponent)." }
        case .url(let url):
            if !NSWorkspace.shared.open(url) { message = "Could not open \(url.absoluteString)." }
        case .shell(let command, let directory):
            AppState.shared.toolGroup = ToolGroup.commands.rawValue
            AppState.shared.toolDetail = "Command runner"
            AppState.shared.page = .tools
            AppDelegate.shared?.openWorkspace()
            CommandToolsModel.shared.runPaletteCommand(command, workingDirectory: directory)
        case .builtin(let action):
            perform(action)
        }
    }

    private func perform(_ action: CommandPaletteBuiltinAction) {
        switch action {
        case .clipboard: ExternalActionDispatcher.shared.dispatch(.clipboard)
        case .island: ExternalActionDispatcher.shared.dispatch(.island)
        case .shelf: ExternalActionDispatcher.shared.dispatch(.shelf)
        case .basket: ExternalActionDispatcher.shared.dispatch(.basket)
        case .notes: ExternalActionDispatcher.shared.dispatch(.notes)
        case .agenda: ExternalActionDispatcher.shared.dispatch(.agenda)
        case .focus: ExternalActionDispatcher.shared.dispatch(.focus)
        case .workspace:
            AppState.shared.page = .home; AppDelegate.shared?.openWorkspace()
        case .settings:
            AppDelegate.shared?.openSettings()
        case .commandRunner:
            AppState.shared.toolGroup = ToolGroup.commands.rawValue
            AppState.shared.toolDetail = "Command runner"
            AppState.shared.page = .tools
            AppDelegate.shared?.openWorkspace()
        case .allFeatures:
            AppState.shared.page = .extensions; AppDelegate.shared?.openWorkspace()
        case .extensionManager:
            message = nil
            showingExtensionBuilder = true
            AppState.shared.toolGroup = ToolGroup.commands.rawValue
            AppState.shared.toolDetail = "Command palette"
            AppState.shared.page = .tools
            AppDelegate.shared?.openWorkspace()
        case .extensionsFolder:
            revealExtensionsFolder()
        }
    }

    private func reconcileClipboardSelection() {
        let ids = clipboardItems.map(\.id)
        if selectedClipboardID == nil || !ids.contains(selectedClipboardID!) { selectedClipboardID = ids.first }
    }

    private func manifestAction(_ action: CommandPaletteManifestAction) -> CommandPaletteAction? {
        switch action.type {
        case .builtin:
            return CommandPaletteBuiltinAction(rawValue: action.value).map(CommandPaletteAction.builtin)
        case .shell:
            return .shell(command: action.value, workingDirectory: normalizedDirectory(action.workingDirectory))
        case .url:
            return URL(string: action.value).map(CommandPaletteAction.url)
        }
    }

    private func loadApplications() {
        var seen = Set<String>()
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        let directories = ["/Applications", "/System/Applications", "/System/Applications/Utilities", userApplications]
        var found: [URL] = []
        for directory in directories {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in contents where url.pathExtension.lowercased() == "app" {
                if seen.insert(url.standardizedFileURL.path).inserted { found.append(url) }
            }
        }
        applications = found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func loadCustomCommands() {
        guard FileManager.default.fileExists(atPath: commandsURL.path) else { return }
        do {
            let data = try Data(contentsOf: commandsURL)
            guard data.count <= 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let commands = try JSONDecoder().decode([SavedPaletteCommand].self, from: data)
            guard commands.count <= 100, commands.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 80 && !$0.command.isEmpty && $0.command.count <= 4_096 }) else { throw CocoaError(.fileReadCorruptFile) }
            customCommands = commands.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            customLoadFailed = false
        } catch {
            customLoadFailed = true
            message = "Custom commands could not be loaded: \(error.localizedDescription)"
        }
    }

    private func persistCustomCommands() {
        do {
            try JSONEncoder().encode(customCommands).write(to: commandsURL, options: .atomic)
            message = nil
        } catch { message = "Could not save custom commands: \(error.localizedDescription)" }
    }

    private func normalizedDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        let expanded = (path as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        return !expanded.isEmpty && FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue ? expanded : nil
    }

    private func remember(_ id: String) {
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: 0)
        recentIDs = Array(recentIDs.prefix(12))
        defaults.set(recentIDs, forKey: Self.recentIDsKey)
    }

    private static let recentIDsKey = "palette.recentIDs"
    private static let lastLevelKey = "palette.lastLevel"

    private func kindOrder(_ kind: CommandPaletteItemKind) -> Int {
        switch kind { case .command: 0; case .custom: 1; case .extensionCommand: 2; case .application: 3 }
    }

    private func section(for kind: CommandPaletteItemKind) -> String {
        switch kind { case .command, .custom: "Commands"; case .application: "Applications"; case .extensionCommand: "Extensions" }
    }
}

private final class CommandPalettePanel: NSPanel {
    var dismissHandler: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismissHandler?() }
}

@MainActor
final class CommandPaletteController: NSObject, NSWindowDelegate {
    static let shared = CommandPaletteController()
    private var panel: CommandPalettePanel?
    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if panel == nil {
            let panel = CommandPalettePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "SuperNotch Command Palette"
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isFloatingPanel = true
            panel.isMovable = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.delegate = self
            panel.dismissHandler = { [weak self] in self?.hide() }
            self.panel = panel
        }
        guard let panel else { return }
        ClipboardStore.shared.rememberPasteDestination()
        CommandPaletteStore.shared.beginSession()
        let root = CommandPaletteView(
            store: .shared,
            onClose: { [weak self] in self?.hide() },
            onHeightChange: { [weak self] height in self?.apply(height: height) }
        ).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        position(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.alphaValue = 1 }
        else { NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; panel.animator().alphaValue = 1 } }
    }

    /// Opens the palette straight onto clipboard history. This is the only
    /// clipboard surface: the menu bar item, ⇧⌘V, the island button, quick
    /// actions and `supernotch://clipboard` all land here.
    func showClipboard() {
        show()
        CommandPaletteStore.shared.enterClipboard()
    }

    func hide() {
        CommandPaletteStore.shared.endSession()
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, notification.object as? NSWindow === panel else { return }
        hide()
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(PaletteTheme.width, max(520, visible.width - 60))
        let height = min(PaletteTheme.clipboardHeight, max(320, visible.height - 100))
        // The palette keeps its top edge fixed while the list grows and shrinks,
        // so anchor the frame from the top the same way `apply(height:)` does.
        let origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height * 0.43)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    /// Resizes the panel around its fixed top edge as the result list changes length.
    private func apply(height: CGFloat) {
        guard let panel else { return }
        let available = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let clamped = min(max(height.rounded(), 200), available - 80)
        var frame = panel.frame
        guard abs(frame.height - clamped) > 0.5 else { return }
        frame.origin.y = frame.maxY - clamped
        frame.size.height = clamped
        panel.setFrame(frame, display: true)
    }
}

// MARK: - Palette styling

/// Metrics and colours for the command palette surface.
private enum PaletteTheme {
    static let accent = Color(red: 0.42, green: 0.53, blue: 1.0)
    static let surface = Color(red: 0.086, green: 0.090, blue: 0.105)
    static let hairline = Color.white.opacity(0.07)
    static let border = Color.white.opacity(0.11)
    static let selection = Color.white.opacity(0.09)
    static let keyCap = Color.white.opacity(0.08)
    static let control = Color.white.opacity(0.07)

    static let cornerRadius: CGFloat = 16
    static let rowRadius: CGFloat = 8
    static let searchHeight: CGFloat = 56
    static let footerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 42
    static let rowSpacing: CGFloat = 2
    static let headerHeight: CGFloat = 30
    static let listInset: CGFloat = 8
    static let gutter: CGFloat = 16

    static let width: CGFloat = 750
    static let maxListHeight: CGFloat = 392
    static let emptyListHeight: CGFloat = 190
    static let clipboardHeight: CGFloat = 498
}

/// A single key in a shortcut hint, drawn like the caps in Raycast's footer.
private struct PaletteKeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 4)
            .background(PaletteTheme.keyCap, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// A "label + keys" pair, used in the footer and the actions menu.
private struct PaletteHint: View {
    let label: String
    let keys: [String]
    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in PaletteKeyCap(label: key) }
        }
    }
}

/// One entry of the ⌘K actions menu.
private struct PaletteAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var keys: [String] = []
    var destructive = false
    let run: () -> Void
}

@MainActor
private struct CommandPaletteView: View {
    @ObservedObject var store: CommandPaletteStore
    @ObservedObject private var clipboard = ClipboardStore.shared
    let onClose: () -> Void
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @FocusState private var searchFocused: Bool
    @State private var keyboardNavigation = false
    @State private var pointerAnchor = NSEvent.mouseLocation
    @State private var actionsOpen = false
    @State private var actionIndex = 0
    @State private var hoveredClipboardID: UUID?

    var body: some View {
        let items = store.displayItems
        return VStack(spacing: 0) {
            searchBar
            hairline
            if store.level == .clipboard { clipboardBrowser } else { results(items) }
            hairline
            footer
        }
        .background {
            // Blurred backdrop first, then a dark tint on top: the panel stays
            // opaque enough that nothing behind it reads as text.
            ZStack {
                RoundedRectangle(cornerRadius: PaletteTheme.cornerRadius, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: PaletteTheme.cornerRadius, style: .continuous).fill(PaletteTheme.surface.opacity(0.9))
            }
        }
        .overlay(alignment: .bottomTrailing) { actionsOverlay }
        .clipShape(RoundedRectangle(cornerRadius: PaletteTheme.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PaletteTheme.cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.18), PaletteTheme.border], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.55), radius: 34, y: 20)
        .onAppear { searchFocused = true }
        .onChange(of: desiredHeight(for: items), initial: true) { _, height in onHeightChange(height) }
        .onChange(of: store.query) { _, _ in store.queryDidChange() }
        .onChange(of: store.level) { _, _ in actionsOpen = false; searchFocused = true }

        .onChange(of: store.clipboardFilter) { _, _ in store.clipboardFilterDidChange(); searchFocused = true }
        .onChange(of: clipboard.items.map(\.id)) { _, _ in store.clipboardFilterDidChange() }
        .onKeyPress(phases: .down, action: handleKeyPress)
        .accessibilityLabel("SuperNotch command palette")
    }

    private var hairline: some View { Rectangle().fill(PaletteTheme.hairline).frame(height: 1) }

    // MARK: Search bars

    /// One search bar for both levels. The text field must keep a single view
    /// identity: swapping in a second one drops focus, and with it every key
    /// binding (arrows, return, ⌘K).
    private var searchBar: some View {
        let clipboardLevel = store.level == .clipboard
        return HStack(spacing: clipboardLevel ? 10 : 12) {
            if clipboardLevel { backPill }
            TextField(clipboardLevel ? "Search entries…" : "Search apps and commands…", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: clipboardLevel ? 17 : 19, weight: .regular))
                .focused($searchFocused)
                .onSubmit { store.executeSelected() }
                .onKeyPress(phases: .down, action: handleKeyPress)
            if !store.query.isEmpty { clearButton }
            if clipboardLevel { filterMenu } else { PaletteKeyCap(label: "⌥ Space") }
        }
        .padding(.horizontal, clipboardLevel ? 12 : PaletteTheme.gutter)
        .frame(height: PaletteTheme.searchHeight)
    }

    private var backPill: some View {
        Button { store.leaveClipboard() } label: {
            HStack(spacing: 6) {
                Image(systemName: "list.clipboard.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                Text("Clipboard History").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(PaletteTheme.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Back to commands (esc)")
        .accessibilityLabel("Back to commands")
    }

    private var clearButton: some View {
        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)) }
            .buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear search")
    }

    private var filterMenu: some View {
        Menu {
            ForEach(CommandPaletteClipboardFilter.allCases) { filter in
                Button(filter.rawValue) { store.clipboardFilter = filter; searchFocused = true }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.clipboardFilter.rawValue).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(PaletteTheme.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Filter clipboard entries by type")
    }

    // MARK: Results

    private func results(_ items: [CommandPaletteDisplayItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PaletteTheme.rowSpacing) {
                    if items.isEmpty { emptyState(title: "No results", detail: "Try a shorter name, a keyword, or an extension command.") }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, display in
                        if index == 0 || items[index - 1].section != display.section {
                            sectionHeader(display.section)
                        }
                        row(display.item).id(display.id)
                    }
                }
                .padding(.horizontal, PaletteTheme.listInset)
                .padding(.vertical, PaletteTheme.listInset)
            }
            .scrollIndicators(.never)
            .onChange(of: store.selectedID) { _, id in
                if keyboardNavigation, let id { withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .frame(height: PaletteTheme.headerHeight, alignment: .bottomLeading)
            .padding(.bottom, 2)
    }

    private func row(_ item: CommandPaletteItem) -> some View {
        let selected = store.selectedID == item.id
        return HStack(spacing: 10) {
            itemIcon(item)
            Text(item.title).font(.system(size: 13.5)).foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.system(size: 12.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Text(item.kind.rawValue).font(.system(size: 12)).foregroundStyle(.tertiary).fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: PaletteTheme.rowHeight)
        .background(selected ? PaletteTheme.selection : .clear, in: RoundedRectangle(cornerRadius: PaletteTheme.rowRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PaletteTheme.rowRadius, style: .continuous))
        .onHover { hovering in if hovering, pointerMoved() { keyboardNavigation = false; store.selectedID = item.id } }
        .onTapGesture { keyboardNavigation = false; store.selectedID = item.id; store.executeSelected() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.kind.rawValue), \(item.subtitle)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func itemIcon(_ item: CommandPaletteItem) -> some View {
        Group {
            if let url = item.applicationURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    private func emptyState(title: String, detail: String, symbol: String = "magnifyingglass") -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 46)
    }

    // MARK: Clipboard browser

    private var clipboardBrowser: some View {
        HStack(spacing: 0) {
            clipboardList.frame(width: 320)
            Rectangle().fill(PaletteTheme.hairline).frame(width: 1)
            clipboardDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var clipboardList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PaletteTheme.rowSpacing) {
                    let items = store.clipboardItems
                    if items.isEmpty {
                        emptyState(
                            title: clipboard.items.isEmpty ? "Clipboard is empty" : "No results",
                            detail: clipboard.items.isEmpty ? "Copy text, links, images or files to see them here." : "Try another search or type filter.",
                            symbol: clipboard.items.isEmpty ? "clipboard" : "magnifyingglass"
                        )
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let section = clipboardSection(item)
                        if index == 0 || clipboardSection(items[index - 1]) != section { sectionHeader(section) }
                        clipboardRow(item).id(item.id)
                    }
                }
                .padding(.horizontal, PaletteTheme.listInset)
                .padding(.vertical, PaletteTheme.listInset)
            }
            .scrollIndicators(.never)
            .onChange(of: store.selectedClipboardID) { _, id in
                if keyboardNavigation, let id { withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func clipboardRow(_ item: ClipboardEntry) -> some View {
        let selected = store.selectedClipboardID == item.id
        return HStack(spacing: 10) {
            clipboardRowIcon(item)
            VStack(alignment: .leading, spacing: 2) {
                Text(clipboardTitle(item)).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(clipboardKind(item)).font(.system(size: 11)).foregroundStyle(.tertiary)
                    if let source = item.sourceAppName {
                        Text("· \(source)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if hoveredClipboardID == item.id {
                rowButton(symbol: "trash", tint: .secondary, help: "Delete entry (⌘⌫)") { clipboard.delete(item) }
            }
            if item.isPinned || hoveredClipboardID == item.id {
                rowButton(
                    symbol: item.isPinned ? "pin.fill" : "pin",
                    tint: item.isPinned ? .orange : .secondary,
                    help: item.isPinned ? "Unpin entry (⌘P)" : "Pin entry (⌘P)"
                ) { clipboard.togglePin(item) }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(selected ? PaletteTheme.selection : .clear, in: RoundedRectangle(cornerRadius: PaletteTheme.rowRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PaletteTheme.rowRadius, style: .continuous))
        .onHover { hovering in
            if hovering {
                hoveredClipboardID = item.id
                if pointerMoved() { keyboardNavigation = false; store.selectedClipboardID = item.id }
            } else if hoveredClipboardID == item.id {
                hoveredClipboardID = nil
            }
        }
        .onTapGesture(count: 2) { keyboardNavigation = false; store.selectedClipboardID = item.id; store.executeSelected() }
        .onTapGesture { keyboardNavigation = false; store.selectedClipboardID = item.id }
        .contextMenu {
            Button("Paste") { store.selectedClipboardID = item.id; store.executeSelected() }
            Button("Copy") { clipboard.copy(item) }
            Button(item.isPinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            Button("Delete", role: .destructive) { clipboard.delete(item) }
        }
    }

    private func rowButton(symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button { action(); searchFocused = true } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(PaletteTheme.control, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private func clipboardRowIcon(_ item: ClipboardEntry) -> some View {
        if item.kind == .image, let data = item.thumbnail, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.7))
        } else if let color = item.colorValue {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(red: color.r, green: color.g, blue: color.b, opacity: color.a))
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.7))
        } else {
            Image(systemName: item.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(clipboardTint(item).gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func clipboardTint(_ item: ClipboardEntry) -> Color {
        switch item.kind {
        case .link: .blue
        case .files: .orange
        case .image: .pink
        case .richText: .purple
        case .text: PaletteTheme.accent
        }
    }

    private var clipboardDetail: some View {
        Group {
            if let id = store.selectedClipboardID, let item = store.clipboardItems.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 0) {
                    ClipboardPalettePreview(item: item)
                        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 230)
                        .padding(16)
                    Rectangle().fill(PaletteTheme.hairline).frame(height: 1)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Information").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                            infoRow("Source", item.sourceAppName ?? "Unknown", symbol: "app.fill")
                            infoRow("Content type", clipboardKind(item), symbol: item.symbol)
                            infoRow("Copied", item.createdAt.formatted(date: .abbreviated, time: .shortened), symbol: "clock")
                            if item.storedPayloadByteCount > 0 {
                                infoRow("Size", ByteCountFormatter.string(fromByteCount: Int64(item.storedPayloadByteCount), countStyle: .file), symbol: "internaldrive")
                            }
                            if !item.tagNames.isEmpty { infoRow("Tags", item.tagNames.joined(separator: ", "), symbol: "tag.fill") }
                            HStack(spacing: 8) {
                                detailButton(item.isPinned ? "Unpin" : "Pin", symbol: item.isPinned ? "pin.slash" : "pin") { clipboard.togglePin(item) }
                                detailButton("Copy", symbol: "doc.on.doc") { clipboard.copy(item) }
                                detailButton("Delete", symbol: "trash", tint: .red) { clipboard.delete(item) }
                                Spacer(minLength: 0)
                            }
                            .padding(.top, 4)
                        }
                        .padding(16)
                    }
                    .scrollIndicators(.never)
                }
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "clipboard").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                    Text("Select an entry").font(.system(size: 14, weight: .medium))
                    Text("Its preview and details appear here.").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detailButton(_ title: String, symbol: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button { action(); searchFocused = true } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9).frame(height: 26)
            .background(PaletteTheme.control, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func infoRow(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).frame(width: 14).foregroundStyle(.tertiary)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12))
    }

    private func clipboardSection(_ item: ClipboardEntry) -> String {
        if item.isPinned { return "Pinned" }
        return Calendar.current.isDateInToday(item.createdAt) ? "Today" : "Earlier"
    }

    private func clipboardTitle(_ item: ClipboardEntry) -> String {
        switch item.kind {
        case .image: return "Image"
        case .files: return item.title
        default:
            let flattened = item.text.replacingOccurrences(of: "\n", with: " ")
            return flattened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.title : flattened
        }
    }

    private func clipboardKind(_ item: ClipboardEntry) -> String {
        if item.colorValue != nil { return "Color" }
        switch item.kind {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .files: return item.paths.count == 1 ? "File" : "Files"
        case .richText: return "Formatted Text"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: store.level == .clipboard ? "list.clipboard.fill" : "rectangle.topthird.inset.filled")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background((store.level == .clipboard ? Color.blue : PaletteTheme.accent).gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(store.level == .clipboard ? "Clipboard History" : "SuperNotch").font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 12)
            PaletteHint(label: primaryActionLabel, keys: ["↩"])
            Rectangle().fill(PaletteTheme.hairline).frame(width: 1, height: 16)
            Button { toggleActions() } label: {
                PaletteHint(label: "Actions", keys: ["⌘", "K"])
                    .padding(.horizontal, 6).frame(height: 26)
                    .background(actionsOpen ? PaletteTheme.control : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show actions")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: PaletteTheme.footerHeight)
    }

    private var primaryActionLabel: String {
        guard store.level == .clipboard else { return "Open" }
        return "Paste to \(clipboard.pasteDestinationName ?? "previous app")"
    }

    // MARK: Actions menu

    @ViewBuilder private var actionsOverlay: some View {
        if actionsOpen {
            ZStack(alignment: .bottomTrailing) {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { actionsOpen = false }
                actionsMenu
                    .padding(.trailing, 8)
                    .padding(.bottom, PaletteTheme.footerHeight + 6)
            }
            .transition(.opacity)
        }
    }

    private var actionsMenu: some View {
        let actions = currentActions
        return VStack(alignment: .leading, spacing: 1) {
            Text("Actions")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 5)
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let highlighted = index == actionIndex
                HStack(spacing: 9) {
                    Image(systemName: action.symbol).font(.system(size: 11, weight: .medium)).frame(width: 15)
                    Text(action.title).font(.system(size: 12.5))
                    Spacer(minLength: 14)
                    if !action.keys.isEmpty {
                        HStack(spacing: 3) { ForEach(Array(action.keys.enumerated()), id: \.offset) { _, key in PaletteKeyCap(label: key) } }
                    }
                }
                .foregroundStyle(action.destructive ? Color.red.opacity(0.95) : .primary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(highlighted ? PaletteTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { hovering in if hovering, pointerMoved() { actionIndex = index } }
                .onTapGesture { actionsOpen = false; action.run() }
            }
        }
        .padding(5)
        .frame(width: 272)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 0.12, green: 0.125, blue: 0.142).opacity(0.94))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(PaletteTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
    }

    private var currentActions: [PaletteAction] {
        if store.level == .clipboard {
            guard let id = store.selectedClipboardID, let entry = store.clipboardItems.first(where: { $0.id == id }) else { return [] }
            return [
                PaletteAction(id: "paste", title: "Paste to \(clipboard.pasteDestinationName ?? "Previous App")", symbol: "arrow.down.doc", keys: ["↩"]) { store.executeSelected() },
                PaletteAction(id: "copy", title: "Copy to Clipboard", symbol: "doc.on.doc", keys: ["⌘", "C"]) { clipboard.copy(entry) },
                PaletteAction(id: "pin", title: entry.isPinned ? "Unpin Entry" : "Pin Entry", symbol: entry.isPinned ? "pin.slash" : "pin", keys: ["⌘", "P"]) { clipboard.togglePin(entry) },
                PaletteAction(id: "delete", title: "Delete Entry", symbol: "trash", keys: ["⌘", "⌫"], destructive: true) { clipboard.delete(entry) }
            ]
        }
        guard let item = store.selectedItem else { return [] }
        var actions: [PaletteAction] = [
            PaletteAction(id: "open", title: item.kind == .application ? "Open Application" : "Run Command", symbol: "arrow.up.forward.app", keys: ["↩"]) { store.executeSelected() },
            PaletteAction(id: "copyName", title: "Copy Name", symbol: "doc.on.doc", keys: ["⌘", "C"]) { copyToClipboard(item.title) }
        ]
        if let url = item.applicationURL {
            actions.append(PaletteAction(id: "reveal", title: "Show in Finder", symbol: "folder", keys: ["⌘", "⇧", "F"]) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        }
        if case .shell(let command, _) = item.action {
            actions.append(PaletteAction(id: "copyCommand", title: "Copy Shell Command", symbol: "terminal", keys: []) { copyToClipboard(command) })
        }
        return actions
    }

    private func toggleActions() {
        guard !currentActions.isEmpty else { return }
        actionIndex = 0
        withAnimation(.easeOut(duration: 0.1)) { actionsOpen.toggle() }
    }

    private func runAction(_ id: String) {
        guard let action = currentActions.first(where: { $0.id == id }) else { return }
        actionsOpen = false
        action.run()
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Sizing

    private func desiredHeight(for items: [CommandPaletteDisplayItem]) -> CGFloat {
        guard store.level != .clipboard else { return PaletteTheme.clipboardHeight }
        let chrome = PaletteTheme.searchHeight + PaletteTheme.footerHeight + 2
        guard !items.isEmpty else { return chrome + PaletteTheme.emptyListHeight }
        var sections = 0
        for (index, display) in items.enumerated() where index == 0 || items[index - 1].section != display.section { sections += 1 }
        let content = CGFloat(items.count) * PaletteTheme.rowHeight
            + CGFloat(sections) * (PaletteTheme.headerHeight + 2)
            + CGFloat(items.count + sections - 1) * PaletteTheme.rowSpacing
            + PaletteTheme.listInset * 2
        return chrome + min(content, PaletteTheme.maxListHeight)
    }

    /// Hover only claims the selection once the pointer has actually moved, so
    /// scrolling rows under a stationary cursor cannot hijack keyboard navigation.
    private func pointerMoved() -> Bool {
        let location = NSEvent.mouseLocation
        guard location != pointerAnchor else { return false }
        pointerAnchor = location
        return true
    }

    // MARK: Keyboard

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.modifiers.contains(.command) {
            let character = keyPress.characters.lowercased()
            switch character {
            case "k": toggleActions(); return .handled
            case "c":
                if store.level == .clipboard { runAction("copy") } else { runAction("copyName") }
                return .handled
            case "p":
                guard store.level == .clipboard else { return .ignored }
                runAction("pin"); return .handled
            case "f":
                guard keyPress.modifiers.contains(.shift), store.level == .root else { return .ignored }
                runAction("reveal"); return .handled
            default: break
            }
            if keyPress.key == .delete, store.level == .clipboard { runAction("delete"); return .handled }
            return .ignored
        }

        if actionsOpen {
            let actions = currentActions
            switch keyPress.key {
            case .escape: actionsOpen = false; return .handled
            case .downArrow: actionIndex = min(actionIndex + 1, max(actions.count - 1, 0)); return .handled
            case .upArrow: actionIndex = max(actionIndex - 1, 0); return .handled
            case .return:
                actionsOpen = false
                if actions.indices.contains(actionIndex) { actions[actionIndex].run() }
                return .handled
            default: return .ignored
            }
        }

        switch keyPress.key {
        case .escape:
            if store.level == .clipboard { store.leaveClipboard() } else { onClose() }
            return .handled
        case .downArrow: keyboardNavigation = true; store.moveSelection(by: 1); return .handled
        case .upArrow: keyboardNavigation = true; store.moveSelection(by: -1); return .handled
        case .return: store.executeSelected(); return .handled
        default: return .ignored
        }
    }
}

@MainActor
private struct ClipboardPalettePreview: View {
    let item: ClipboardEntry
    @State private var image: NSImage?

    var body: some View {
        Group {
            if item.kind == .image {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ProgressView().controlSize(.small)
                }
            } else if let color = item.colorValue {
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(red: color.r, green: color.g, blue: color.b, opacity: color.a))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                    Text(color.canonicalHex).font(.system(.title3, design: .monospaced).weight(.semibold))
                }
            } else if item.kind == .files {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(item.paths, id: \.self) { path in
                            HStack(spacing: 9) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 25, height: 25)
                                Text(path).font(.system(size: 11)).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView {
                    Text(item.text.isEmpty ? "No text preview" : item.text)
                        .font(.system(size: 14, design: item.kind == .link ? .monospaced : .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.id) {
            image = nil
            if item.kind == .image { image = await ClipboardThumbnailCache.load(item)?.image }
        }
    }
}

@MainActor
struct PaletteCommandsView: View {
    @ObservedObject private var store = CommandPaletteStore.shared
    @State private var name = ""
    @State private var command = ""
    @State private var workingDirectory = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Custom Command", systemImage: "terminal.fill").font(.headline)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    TextField("Shell command", text: $command).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    TextField("Working directory (optional)", text: $workingDirectory).textFieldStyle(.roundedBorder)
                    HStack {
                        Text("Commands run only when selected from the palette; output opens in Command Runner.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Command") {
                            if store.addCustomCommand(name: name, command: command, workingDirectory: workingDirectory.isEmpty ? nil : workingDirectory) {
                                name = ""; command = ""; workingDirectory = ""
                            }
                        }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.cardStyle()

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Saved Commands", systemImage: "command")
                    if store.customCommands.isEmpty {
                        Text("No custom commands yet.").foregroundStyle(.secondary).padding(.vertical, 10)
                    }
                    ForEach(store.customCommands) { saved in
                        HStack(spacing: 10) {
                            SymbolTile(systemImage: saved.symbol, color: .gray, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(saved.name).font(.body.weight(.medium))
                                Text(saved.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Run") { store.executeCustomCommand(saved) }
                            Button(role: .destructive) { store.deleteCustomCommand(saved) } label: { Image(systemName: "trash") }.help("Delete command")
                        }.rowStyle(padding: 9)
                    }
                }.cardStyle()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Local Extensions", systemImage: "puzzlepiece.extension.fill").font(.headline)
                        Spacer()
                        Text("\(store.extensionCount) loaded").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Create an extension in SuperNotch or import a version-1 JSON manifest. Extensions can open a SuperNotch action, URL, or an explicitly selected shell command.").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button { store.message = nil; store.showingExtensionBuilder = true } label: { Label("Add Extension", systemImage: "plus") }
                            .buttonStyle(PillButtonStyle(prominent: true))
                        Button { store.chooseExtensionManifest() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                            .buttonStyle(PillButtonStyle())
                        Button { store.revealExtensionsFolder() } label: { Label("Folder", systemImage: "folder") }
                            .buttonStyle(PillButtonStyle())
                        Button { store.reloadExtensions() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(PillButtonStyle()).help("Reload extensions")
                        Spacer()
                    }
                    if !store.installedExtensions.isEmpty {
                        Divider().padding(.vertical, 2)
                        ForEach(store.installedExtensions) { item in
                            HStack(spacing: 10) {
                                SymbolTile(systemImage: "puzzlepiece.extension.fill", color: .indigo, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.body.weight(.medium))
                                    Text("\(item.commandCount) command\(item.commandCount == 1 ? "" : "s")\(item.description.map { " · \($0)" } ?? "")")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                            }
                            .rowStyle(padding: 8)
                        }
                    }
                    Text("Full manifest format: docs/EXTENSIONS.md").font(.caption2).foregroundStyle(.tertiary)
                }.cardStyle()

                if let message = store.message { InlineMessage(text: message, tone: .orange) { store.message = nil } }
            }
        }
        .sheet(isPresented: $store.showingExtensionBuilder) {
            ExtensionBuilderView(store: store)
        }
    }
}

@MainActor
private struct ExtensionBuilderView: View {
    @ObservedObject var store: CommandPaletteStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var identifier = ""
    @State private var generatedIdentifier = ""
    @State private var description = ""
    @State private var commandName = ""
    @State private var commandIdentifier = ""
    @State private var generatedCommandIdentifier = ""
    @State private var subtitle = ""
    @State private var symbol = "puzzlepiece.extension.fill"
    @State private var keywords = ""
    @State private var actionType: CommandPaletteManifestAction.Kind = .shell
    @State private var actionValue = ""
    @State private var workingDirectory = ""
    @State private var builtinAction: CommandPaletteBuiltinAction = .clipboard

    private var effectiveActionValue: String { actionType == .builtin ? builtinAction.rawValue : actionValue }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !commandIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !effectiveActionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    extensionDetails
                    commandDetails
                }
                .frame(width: 405)
                VStack(spacing: 14) {
                    actionDetails
                    commandPreview
                    if let message = store.message, message.hasPrefix("Could not add extension:") {
                        InlineMessage(text: message, tone: .orange) { store.message = nil }
                    }
                }
            }
            .padding(14)
            .frame(maxHeight: .infinity, alignment: .top)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            footer
        }
        .frame(width: 760, height: 560)
        .background {
            ZStack(alignment: .top) {
                Color(white: 0.055)
                RadialGradient(colors: [Color.blue.opacity(0.13), .clear], center: .topLeading, startRadius: 0, endRadius: 380)
                    .frame(height: 230)
            }
        }
        .foregroundStyle(.white)
        .tint(.blue)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            SymbolTile(systemImage: "puzzlepiece.extension.fill", color: .blue, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Create Extension").font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Add a command to your SuperNotch command center").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Label("Stored locally", systemImage: "lock.fill")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 9).padding(.vertical, 5).background(.white.opacity(0.07), in: Capsule())
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(IslandPressStyle()).help("Close")
        }
        .padding(.horizontal, 16).frame(height: 64)
    }

    private var extensionDetails: some View {
        editorCard("Extension details", symbol: "puzzlepiece.extension.fill", step: "01") {
            HStack(spacing: 10) {
                editorField("Name", prompt: "Developer Tools", text: $name)
                    .onChange(of: name) { _, value in updateGeneratedIdentifier(from: value) }
                editorField("Identifier", prompt: "local.developer-tools", text: $identifier, monospaced: true)
            }
            editorField("Description", prompt: "What this extension adds", text: $description)
        }
    }

    private var commandDetails: some View {
        editorCard("Command details", symbol: "command", step: "02") {
            HStack(spacing: 10) {
                editorField("Name", prompt: "Open Dashboard", text: $commandName)
                    .onChange(of: commandName) { _, value in updateGeneratedCommandIdentifier(from: value) }
                editorField("Command ID", prompt: "open-dashboard", text: $commandIdentifier, monospaced: true)
            }
            HStack(spacing: 10) {
                editorField("Subtitle", prompt: "A short description", text: $subtitle)
                editorField("SF Symbol", prompt: "command", text: $symbol, monospaced: true)
            }
            editorField("Keywords", prompt: "web, local, dashboard", text: $keywords)
        }
    }

    private var actionDetails: some View {
        editorCard("Choose an action", symbol: "bolt.fill", step: "03") {
            ChipPicker(
                options: [(.shell, "Shell"), (.url, "URL"), (.builtin, "SuperNotch")],
                selection: $actionType
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch actionType {
                case .shell:
                    editorField("Command", prompt: "swift test", text: $actionValue, monospaced: true)
                    editorField("Working directory", prompt: "Optional folder path", text: $workingDirectory)
                case .url:
                    editorField("URL", prompt: "https://example.com", text: $actionValue, monospaced: true)
                    actionHint("Opens in your default browser when selected.", symbol: "safari")
                case .builtin:
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("SUPERNOTCH ACTION")
                        Picker("SuperNotch action", selection: $builtinAction) {
                            ForEach(CommandPaletteBuiltinAction.allCases, id: \.self) { action in
                                Text(action.displayName).tag(action)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actionHint("Runs a built-in SuperNotch action.", symbol: "rectangle.topthird.inset.filled")
                }
            }
            actionHint("Extensions run only after you choose their command.", symbol: "checkmark.shield.fill")
        }
    }

    private var commandPreview: some View {
        editorCard("Command center preview", symbol: "sparkles", step: nil) {
            HStack(spacing: 11) {
                SymbolTile(systemImage: symbol.isEmpty ? "puzzlepiece.extension.fill" : symbol, color: .blue, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(commandName.isEmpty ? "Your command" : commandName).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(commandName.isEmpty ? 0.42 : 1))
                    Text(subtitle.isEmpty ? (name.isEmpty ? "Extension command" : name) : subtitle)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
                Spacer()
                Text("Extension").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(11).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                store.chooseExtensionManifest()
                if store.message?.hasPrefix("Added ") == true { dismiss() }
            } label: { Label("Import Manifest", systemImage: "square.and.arrow.down") }
            .buttonStyle(PillButtonStyle())
            Text("For multi-command extensions").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(PillButtonStyle())
            Button {
                if store.createExtension(
                    name: name,
                    identifier: identifier,
                    description: description,
                    commandName: commandName,
                    commandIdentifier: commandIdentifier,
                    subtitle: subtitle,
                    symbol: symbol,
                    keywords: keywords,
                    actionType: actionType,
                    actionValue: effectiveActionValue,
                    workingDirectory: actionType == .shell ? workingDirectory : nil
                ) { dismiss() }
            } label: { Label("Add Extension", systemImage: "plus") }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(!canSave)
        }
        .padding(.horizontal, 16).frame(height: 52)
    }

    private func editorCard<Content: View>(_ title: String, symbol: String, step: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let step { Text(step).font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.3)) }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.085), lineWidth: 0.7))
    }

    private func editorField(_ title: String, prompt: String, text: Binding<String>, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(title.uppercased())
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .padding(.horizontal, 9).frame(height: 30)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.white.opacity(0.09), lineWidth: 0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value).font(.system(size: 9, weight: .bold)).tracking(0.65).foregroundStyle(.white.opacity(0.38))
    }

    private func actionHint(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
    }

    private func updateGeneratedIdentifier(from value: String) {
        guard identifier.isEmpty || identifier == generatedIdentifier else { return }
        generatedIdentifier = "local.\(slug(value, fallback: "extension"))"
        identifier = generatedIdentifier
    }

    private func updateGeneratedCommandIdentifier(from value: String) {
        guard commandIdentifier.isEmpty || commandIdentifier == generatedCommandIdentifier else { return }
        generatedCommandIdentifier = slug(value, fallback: "command")
        commandIdentifier = generatedCommandIdentifier
    }

    private func slug(_ value: String, fallback: String) -> String {
        let mapped = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let clean = String(mapped).split(separator: "-").filter { !$0.isEmpty }.joined(separator: "-")
        return String((clean.isEmpty ? fallback : clean).prefix(60))
    }
}

private extension CommandPaletteBuiltinAction {
    var displayName: String {
        switch self {
        case .clipboard: "Clipboard History"
        case .island: "Open Island"
        case .shelf: "File Shelf"
        case .basket: "Floating Basket"
        case .notes: "Quick Notes"
        case .agenda: "Agenda"
        case .focus: "Focus Timer"
        case .workspace: "Open Workspace"
        case .settings: "Settings"
        case .commandRunner: "Command Runner"
        case .allFeatures: "All Features"
        case .extensionManager: "Add Extension"
        case .extensionsFolder: "Open Extensions Folder"
        }
    }
}
