import Foundation
import AppKit

/// Actions that may be requested through SuperNotch's public URL scheme.
///
/// Keep this enum deliberately small. Values from an external URL are never
/// interpreted as a command, file path, or process argument; they must match
/// one of these cases exactly.
enum ExternalAction: String, CaseIterable, Sendable {
    case island
    case clipboard
    case shelf
    case basket
    case notes
    case agenda
    case focus
    /// Bring the app that is playing music to the front.
    case player

    static let scheme = "supernotch"

    /// The canonical URL emitted by integrations such as Alfred.
    var url: URL {
        URL(string: "\(Self.scheme)://\(rawValue)")!
    }
}

/// Parses the intentionally narrow `supernotch://` URL contract.
///
/// Both authority-style (`supernotch://shelf`) and path-style
/// (`supernotch:///shelf`) URLs are accepted so that callers can use either
/// standard custom-scheme spelling. In either form there must be exactly one
/// known action and there may be no query, fragment, credentials, port, or
/// additional path components.
struct ExternalActionParser {
    static func parse(_ url: URL) -> ExternalAction? {
        guard url.scheme?.lowercased() == ExternalAction.scheme else { return nil }
        guard url.user == nil, url.password == nil, url.port == nil else { return nil }
        guard url.query == nil, url.fragment == nil else { return nil }
        // Foundation exposes decoded host/path values. Reject escaped input
        // before decoding so `supernotch://%73helf` cannot become `shelf`.
        guard !url.absoluteString.contains("%") else { return nil }

        if let host = url.host, !host.isEmpty {
            // Authority-style URLs may have an optional trailing slash, but
            // no second path component.
            guard url.path.isEmpty || url.path == "/" else { return nil }
            return action(named: host)
        }

        // A path-style custom URL has exactly one component after the leading
        // slash. Empty components are rejected so `//shelf` cannot be used to
        // smuggle extra structure into the action name.
        let path = url.path
        guard path.first == "/", !path.hasPrefix("//"), !path.hasSuffix("/"),
              path.split(separator: "/", omittingEmptySubsequences: true).count == 1,
              let component = path.split(separator: "/", omittingEmptySubsequences: true).first else {
            return nil
        }
        return action(named: String(component))
    }

    private static func action(named value: String) -> ExternalAction? {
        // URL hosts are case-insensitive. Action names themselves are ASCII
        // identifiers, so lowercasing followed by enum lookup rejects spaces,
        // escapes, Unicode lookalikes, and every unknown value.
        ExternalAction(rawValue: value.lowercased())
    }
}

/// Main-actor bridge from parsed external actions to existing app controllers.
///
/// The default singleton is used by `AppDelegate`'s URL-open callback. The
/// injectable initializer keeps routing side effects out of parser tests and
/// makes it possible to test that malformed URLs are ignored.
@MainActor
final class ExternalActionDispatcher {
    typealias Handler = @MainActor (ExternalAction) -> Void

    static let shared = ExternalActionDispatcher { action in
        ExternalActionDispatcher.perform(action)
    }

    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Dispatch a URL if and only if the strict parser recognizes it.
    /// Returns `true` when a supported action was accepted.
    @discardableResult
    func dispatch(_ url: URL) -> Bool {
        guard let action = ExternalActionParser.parse(url) else { return false }
        handler(action)
        return true
    }

    /// Dispatch a previously parsed action.
    func dispatch(_ action: ExternalAction) {
        handler(action)
    }

    private static func perform(_ action: ExternalAction) {
        switch action {
        case .island:
            guard let delegate = AppDelegate.shared else { return }
            delegate.setExpanded(true)
            // `setExpanded(true)` is intentionally a no-op when already open;
            // an external action must still bring the island to the front.
            delegate.explicitExpansion = true
            delegate.panels.first?.makeKeyAndOrderFront(nil)
        case .clipboard:
            AppDelegate.shared?.openClipboard()
        case .shelf:
            AppState.shared.page = .files
            AppDelegate.shared?.openWorkspace()
        case .basket:
            BasketController.shared.show()
        case .notes:
            AppDelegate.shared?.openNotesWidget()
        case .agenda:
            AppDelegate.shared?.openAgendaWidget()
        case .focus:
            AppDelegate.shared?.openWidget(2)
        case .player:
            NowPlayingAppOpener.openCurrentPlayer(showOnly: true)
        }
    }
}
