import Foundation
import XCTest
@testable import SuperNotch

final class CommandPaletteTests: XCTestCase {
    func testSearchPrioritizesPrefixesAndSupportsFuzzyMatches() throws {
        let prefix = try XCTUnwrap(CommandPaletteSearch.score(query: "clip", title: "Clipboard History", subtitle: "Recent copies", keywords: ["paste"]))
        let contained = try XCTUnwrap(CommandPaletteSearch.score(query: "history", title: "Clipboard History", subtitle: "Recent copies", keywords: ["paste"]))
        let fuzzy = try XCTUnwrap(CommandPaletteSearch.score(query: "clph", title: "Clipboard History", subtitle: "Recent copies", keywords: []))
        XCTAssertGreaterThan(prefix, contained)
        XCTAssertGreaterThan(contained, fuzzy)
        XCTAssertNil(CommandPaletteSearch.score(query: "weather", title: "Clipboard History", subtitle: "Recent copies", keywords: ["paste"]))
    }

    func testExtensionManifestAcceptsSupportedActions() throws {
        let document = CommandPaletteExtensionDocument(
            version: 1,
            id: "com.example.tools",
            name: "Example Tools",
            description: nil,
            commands: [
                .init(id: "clipboard", name: "Clipboard", subtitle: nil, symbol: nil, keywords: nil, action: .init(type: .builtin, value: "clipboard", workingDirectory: nil)),
                .init(id: "site", name: "Open Site", subtitle: nil, symbol: nil, keywords: nil, action: .init(type: .url, value: "https://example.com", workingDirectory: nil)),
                .init(id: "status", name: "Git Status", subtitle: nil, symbol: nil, keywords: nil, action: .init(type: .shell, value: "git status --short", workingDirectory: "~/Developer"))
            ]
        )
        XCTAssertNoThrow(try CommandPaletteExtensionValidation.validate(document))
    }

    func testExtensionManifestRejectsUnsafeOrUnknownActions() {
        let unsafeURL = CommandPaletteExtensionDocument(
            version: 1, id: "example", name: "Example", description: nil,
            commands: [.init(id: "bad", name: "Bad", subtitle: nil, symbol: nil, keywords: nil, action: .init(type: .url, value: "file:///tmp/secret", workingDirectory: nil))]
        )
        let unknownBuiltin = CommandPaletteExtensionDocument(
            version: 1, id: "example", name: "Example", description: nil,
            commands: [.init(id: "bad", name: "Bad", subtitle: nil, symbol: nil, keywords: nil, action: .init(type: .builtin, value: "eraseEverything", workingDirectory: nil))]
        )
        XCTAssertThrowsError(try CommandPaletteExtensionValidation.validate(unsafeURL))
        XCTAssertThrowsError(try CommandPaletteExtensionValidation.validate(unknownBuiltin))
    }

    @MainActor
    func testExtensionInstallerValidatesPersistsAndRejectsDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "CommandPaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suiteName) }
        let store = CommandPaletteStore(baseURL: root, defaults: defaults)
        let document = CommandPaletteExtensionDocument(
            version: 1, id: "local.test-tools", name: "Test Tools", description: "Created in SuperNotch",
            commands: [.init(id: "site", name: "Open Site", subtitle: nil, symbol: "safari", keywords: ["web"], action: .init(type: .url, value: "https://example.com", workingDirectory: nil))]
        )
        let data = try JSONEncoder().encode(document)

        try store.installExtension(data: data)

        XCTAssertEqual(store.extensionCount, 1)
        XCTAssertEqual(store.installedExtensions.first?.id, document.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Extensions/local.test-tools.json").path))
        XCTAssertThrowsError(try store.installExtension(data: data))
    }

    @MainActor
    func testSessionRestoresTheLevelItWasDismissedIn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "CommandPaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suiteName) }
        let store = CommandPaletteStore(baseURL: root, defaults: defaults)

        // A first session that ends in the root list reopens in the root list.
        store.beginSession()
        XCTAssertEqual(store.level, .root)
        store.endSession()
        store.beginSession()
        XCTAssertEqual(store.level, .root)

        // Opening clipboard history and dismissing from there reopens there.
        store.enterClipboard()
        store.endSession()
        let restored = CommandPaletteStore(baseURL: root, defaults: defaults)
        restored.beginSession()
        XCTAssertEqual(restored.level, .clipboard)

        // Stepping back out again clears it for the next launch.
        restored.leaveClipboard()
        restored.endSession()
        restored.beginSession()
        XCTAssertEqual(restored.level, .root)
    }

    @MainActor
    func testInAppExtensionBuilderCreatesValidatedManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CommandPaletteStore(baseURL: root, defaults: .standard)

        XCTAssertTrue(store.createExtension(
            name: "Developer Links",
            identifier: "local.developer-links",
            description: "Useful local URLs",
            commandName: "Open Dashboard",
            commandIdentifier: "open-dashboard",
            subtitle: "Local web app",
            symbol: "safari.fill",
            keywords: "web, local",
            actionType: .url,
            actionValue: "http://localhost:3000",
            workingDirectory: nil
        ))
        XCTAssertEqual(store.installedExtensions.first?.commandCount, 1)

        let data = try Data(contentsOf: root.appendingPathComponent("Extensions/local.developer-links.json"))
        let document = try JSONDecoder().decode(CommandPaletteExtensionDocument.self, from: data)
        XCTAssertNoThrow(try CommandPaletteExtensionValidation.validate(document))
        XCTAssertEqual(document.commands.first?.keywords, ["web", "local"])
    }
}
