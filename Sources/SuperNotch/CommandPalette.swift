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
}

fileprivate struct CommandPaletteDisplayItem: Identifiable {
    let item: CommandPaletteItem
    let section: String
    var id: String { item.id }
}

enum CommandPaletteLevel: Equatable { case root, clipboard }

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
    let extensionsURL: URL
    private var applications: [URL] = []
    private var extensionItems: [CommandPaletteItem] = []
    private var customLoadFailed = false
    private var recentIDs: [String]

    init(baseURL: URL? = nil, defaults: UserDefaults = .standard) {
        let base = baseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SuperNotch", isDirectory: true)
        commandsURL = base.appendingPathComponent("palette-commands.json")
        extensionsURL = base.appendingPathComponent("Extensions", isDirectory: true)
        recentIDs = defaults.stringArray(forKey: "palette.recentIDs") ?? []
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

    func beginSession() {
        query = ""
        level = .root
        clipboardFilter = .all
        selectedClipboardID = nil
        reloadExtensions()
        selectedID = displayItems.first?.id
        message = nil
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
                        applicationURL: nil, action: action
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
                applicationURL: nil, action: .shell(command: command.command, workingDirectory: command.workingDirectory)
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
        builtin(.clipboard, "Clipboard History", "Search and paste recent clipboard items", "list.clipboard.fill", ["copy", "paste", "history"]),
        builtin(.island, "Open Island", "Expand SuperNotch", "rectangle.topthird.inset.filled", ["notch", "home"]),
        builtin(.shelf, "File Shelf", "Open saved files and baskets", "tray.full.fill", ["files", "tray", "stash"]),
        builtin(.basket, "Floating Basket", "Open the active basket", "basket.fill", ["files", "drop"]),
        builtin(.notes, "Quick Notes", "Capture or edit a note", "note.text", ["write", "memo"]),
        builtin(.agenda, "Agenda", "Show calendar events and reminders", "calendar", ["events", "tasks"]),
        builtin(.focus, "Focus Timer", "Start or manage a focus session", "timer", ["pomodoro", "break"]),
        builtin(.workspace, "Open Workspace", "Browse every SuperNotch tool", "square.grid.2x2.fill", ["dashboard", "home"]),
        builtin(.commandRunner, "Command Runner", "Run a shell command and inspect its output", "terminal.fill", ["shell", "terminal", "zsh"]),
        builtin(.allFeatures, "All Features", "Browse available and planned tools", "puzzlepiece.extension.fill", ["extensions", "tools"]),
        builtin(.extensionManager, "Add Extension", "Create or import a command palette extension", "puzzlepiece.extension.badge.plus", ["install", "plugin", "custom", "manifest"]),
        builtin(.settings, "SuperNotch Settings", "Change appearance, widgets and preferences", "gearshape.fill", ["preferences", "configure"]),
        builtin(.extensionsFolder, "Open Extensions Folder", "Install or inspect local command manifests", "folder.badge.gearshape", ["plugins", "custom", "manifest"])
    ]

    private static func builtin(_ action: CommandPaletteBuiltinAction, _ title: String, _ subtitle: String, _ symbol: String, _ keywords: [String]) -> CommandPaletteItem {
        CommandPaletteItem(id: "builtin.\(action.rawValue)", title: title, subtitle: subtitle, symbol: symbol, kind: .command, keywords: keywords, applicationURL: nil, action: .builtin(action))
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
        UserDefaults.standard.set(recentIDs, forKey: "palette.recentIDs")
    }

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
        let host = NSHostingView(rootView: CommandPaletteView(store: .shared, onClose: { [weak self] in self?.hide() }).preferredColorScheme(.dark))
        host.sizingOptions = []
        panel.contentView = host
        position(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.alphaValue = 1 }
        else { NSAnimationContext.runAnimationGroup { context in context.duration = 0.12; panel.animator().alphaValue = 1 } }
    }

    func hide() {
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
        let width = min(780, max(520, visible.width - 60))
        let height = min(540, max(360, visible.height - 100))
        let origin = NSPoint(x: visible.midX - width / 2, y: visible.midY - height * 0.43)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }
}

@MainActor
private struct CommandPaletteView: View {
    @ObservedObject var store: CommandPaletteStore
    @ObservedObject private var clipboard = ClipboardStore.shared
    let onClose: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var keyboardNavigation = false
    private let accent = Color(red: 0.42, green: 0.53, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            if store.level == .clipboard { clipboardSearchBar } else { rootSearchBar }
            Divider().overlay(Color.white.opacity(0.08))
            if store.level == .clipboard { clipboardBrowser } else { results }
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.075, green: 0.078, blue: 0.09).opacity(0.98))
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial).opacity(0.22)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.55), radius: 30, y: 18)
        .onAppear { searchFocused = true }
        .onChange(of: store.query) { _, _ in store.queryDidChange() }
        .onChange(of: store.clipboardFilter) { _, _ in store.clipboardFilterDidChange() }
        .onChange(of: clipboard.items.map(\.id)) { _, _ in store.clipboardFilterDidChange() }
        .onKeyPress(phases: .down, action: handleKeyPress)
        .accessibilityLabel("SuperNotch command palette")
    }

    private var rootSearchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search apps and commands…", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($searchFocused)
                .onSubmit { store.executeSelected() }
                .onKeyPress(.downArrow) { keyboardNavigation = true; store.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { keyboardNavigation = true; store.moveSelection(by: -1); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
            }
            Text("⌥ Space").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 5).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 22)
        .frame(height: 74)
    }

    private var clipboardSearchBar: some View {
        HStack(spacing: 12) {
            Button { store.leaveClipboard(); searchFocused = true } label: {
                Image(systemName: "arrow.left").font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help("Back to commands")
            .accessibilityLabel("Back to commands")
            TextField("Type to filter entries…", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .focused($searchFocused)
                .onSubmit { store.executeSelected() }
                .onKeyPress(.downArrow) { keyboardNavigation = true; store.moveSelection(by: 1); return .handled }
                .onKeyPress(.upArrow) { keyboardNavigation = true; store.moveSelection(by: -1); return .handled }
                .onKeyPress(.escape) { store.leaveClipboard(); return .handled }
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear search")
            }
            Picker("Clipboard type", selection: $store.clipboardFilter) {
                ForEach(CommandPaletteClipboardFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 145)
        }
        .padding(.horizontal, 18)
        .frame(height: 74)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    let items = store.displayItems
                    if items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text("No matching commands or applications").font(.headline)
                            Text("Try a shorter name, keyword, or extension command.").font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.top, 90)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, display in
                        if index == 0 || items[index - 1].section != display.section {
                            Text(display.section).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 18).padding(.top, index == 0 ? 12 : 17).padding(.bottom, 5)
                        }
                        row(display.item).id(display.id)
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
            .onChange(of: store.selectedID) { _, id in
                if keyboardNavigation, let id { withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func row(_ item: CommandPaletteItem) -> some View {
        let selected = store.selectedID == item.id
        return HStack(spacing: 13) {
            Group {
                if let url = item.applicationURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                } else {
                    Image(systemName: item.symbol).resizable().scaledToFit().padding(8).foregroundStyle(.white)
                        .background(accent.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Text(item.kind.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if selected { Text("↩").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).frame(height: 55)
        .background(selected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in if hovering { keyboardNavigation = false; store.selectedID = item.id } }
        .onTapGesture(count: 2) { keyboardNavigation = false; store.selectedID = item.id; store.executeSelected() }
        .onTapGesture { keyboardNavigation = false; store.selectedID = item.id }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.kind.rawValue), \(item.subtitle)")
    }

    private var clipboardBrowser: some View {
        HStack(spacing: 0) {
            clipboardList.frame(width: 330)
            Divider().overlay(Color.white.opacity(0.08))
            clipboardDetail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var clipboardList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    let items = store.clipboardItems
                    if items.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: clipboard.items.isEmpty ? "clipboard" : "magnifyingglass").font(.system(size: 26)).foregroundStyle(.secondary)
                            Text(clipboard.items.isEmpty ? "Clipboard is empty" : "No matching entries").font(.headline)
                            Text(clipboard.items.isEmpty ? "Copy text, links, images or files to see them here." : "Try another search or type filter.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.top, 80)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let section = clipboardSection(item)
                        if index == 0 || clipboardSection(items[index - 1]) != section {
                            Text(section).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 13).padding(.top, index == 0 ? 12 : 16).padding(.bottom, 5)
                        }
                        clipboardRow(item).id(item.id)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 12)
            }
            .onChange(of: store.selectedClipboardID) { _, id in
                if keyboardNavigation, let id { withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func clipboardRow(_ item: ClipboardEntry) -> some View {
        let selected = store.selectedClipboardID == item.id
        return HStack(spacing: 10) {
            clipboardRowIcon(item)
            VStack(alignment: .leading, spacing: 3) {
                Text(clipboardTitle(item)).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(clipboardKind(item)).font(.system(size: 10)).foregroundStyle(.secondary)
                    if let source = item.sourceAppName { Text("· \(source)").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
                }
            }
            Spacer(minLength: 4)
            if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 10).frame(height: 54)
        .background(selected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { hovering in if hovering { keyboardNavigation = false; store.selectedClipboardID = item.id } }
        .onTapGesture(count: 2) { keyboardNavigation = false; store.selectedClipboardID = item.id; store.executeSelected() }
        .onTapGesture { keyboardNavigation = false; store.selectedClipboardID = item.id }
        .contextMenu {
            Button("Copy") { clipboard.copy(item) }
            Button(item.isPinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            Button("Delete", role: .destructive) { clipboard.delete(item) }
        }
    }

    @ViewBuilder private func clipboardRowIcon(_ item: ClipboardEntry) -> some View {
        if item.kind == .image, let data = item.thumbnail, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7))
        } else if let color = item.colorValue {
            RoundedRectangle(cornerRadius: 7).fill(Color(red: color.r, green: color.g, blue: color.b, opacity: color.a)).frame(width: 32, height: 32)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.18), lineWidth: 0.7))
        } else {
            Image(systemName: item.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(accent.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var clipboardDetail: some View {
        Group {
            if let id = store.selectedClipboardID, let item = store.clipboardItems.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 0) {
                    ClipboardPalettePreview(item: item).frame(maxWidth: .infinity, minHeight: 220, maxHeight: 250).padding(18)
                    Divider().overlay(Color.white.opacity(0.07))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Information").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                            infoRow("Source", item.sourceAppName ?? "Unknown", symbol: "app.fill")
                            infoRow("Content type", clipboardKind(item), symbol: item.symbol)
                            infoRow("Copied", item.createdAt.formatted(date: .abbreviated, time: .shortened), symbol: "clock")
                            if item.storedPayloadByteCount > 0 { infoRow("Size", ByteCountFormatter.string(fromByteCount: Int64(item.storedPayloadByteCount), countStyle: .file), symbol: "internaldrive") }
                            if !item.tagNames.isEmpty { infoRow("Tags", item.tagNames.joined(separator: ", "), symbol: "tag.fill") }
                            HStack {
                                Button { clipboard.togglePin(item) } label: { Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") }
                                Button("Copy") { clipboard.copy(item) }
                                Spacer()
                            }.buttonStyle(.bordered)
                        }.padding(18)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "clipboard").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Select a clipboard entry").font(.headline)
                    Text("Its preview and details will appear here.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).frame(width: 15).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }.font(.system(size: 12))
    }

    private func clipboardSection(_ item: ClipboardEntry) -> String {
        if item.isPinned { return "Pinned" }
        return Calendar.current.isDateInToday(item.createdAt) ? "Today" : "Earlier"
    }

    private func clipboardTitle(_ item: ClipboardEntry) -> String {
        switch item.kind {
        case .image: return "Image"
        case .files: return item.title
        default: return item.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? item.title : item.text.replacingOccurrences(of: "\n", with: " ")
        }
    }

    private func clipboardKind(_ item: ClipboardEntry) -> String {
        if item.colorValue != nil { return "Color" }
        switch item.kind { case .text: return "Text"; case .link: return "Link"; case .image: return "Image"; case .files: return item.paths.count == 1 ? "File" : "Files"; case .richText: return "Formatted Text" }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Image(systemName: store.level == .clipboard ? "list.clipboard.fill" : "rectangle.topthird.inset.filled").foregroundStyle(store.level == .clipboard ? .red : accent)
            Text(store.level == .clipboard ? "Clipboard History" : "SuperNotch").font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("Navigate").foregroundStyle(.secondary)
            Text("↑ ↓").font(.system(size: 11, weight: .semibold, design: .rounded)).padding(.horizontal, 7).padding(.vertical, 4).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            Text(store.level == .clipboard ? "Paste to \(clipboard.pasteDestinationName ?? "previous app")" : "Open").foregroundStyle(.secondary)
            Text("↩").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 4).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            Text(store.level == .clipboard ? "Back" : "Close").foregroundStyle(.secondary)
            Text("esc").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 4).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 18).frame(height: 46)
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
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
