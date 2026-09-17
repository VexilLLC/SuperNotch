import SwiftUI
import CoreFoundation

/// The widgets that can be shown in the expanded island.
///
/// Raw values are persisted, so keep these values stable when adding or
/// removing widgets. New widgets can be appended with a new raw value.
enum IslandWidgetID: Int, CaseIterable, Identifiable {
    case notes = 0
    case agenda = 1
    case focus = 2
    case system = 3
    case usage = 4

    var id: Self { self }

    var title: String {
        switch self {
        case .notes: "Notes"
        case .agenda: "Agenda"
        case .focus: "Focus"
        case .system: "System"
        case .usage: "Usage"
        }
    }

    /// The SF Symbol used by the island and by the widget settings editor.
    var symbol: String {
        switch self {
        case .notes: "note.text"
        case .agenda: "calendar"
        case .focus: "timer"
        case .system: "chart.bar.xaxis"
        case .usage: "chart.bar.fill"
        }
    }

    /// A conventional SwiftUI name for the same symbol metadata.
    var systemImage: String { symbol }
}

/// Stores which island widgets are visible and the order in which they appear.
///
/// The stored value is an array of raw integer widget IDs under ``key``. A
/// missing, malformed, or empty value falls back to every known widget. Valid
/// IDs are deduplicated while invalid IDs are ignored, which lets future
/// versions safely read settings written by an older or newer build.
@MainActor
final class WidgetPreferences: ObservableObject {
    static let shared = WidgetPreferences()

    static let defaultKey = "island.visibleWidgets"
    private static let usageSeedKey = "island.widgets.seededUsage.v1"

    private let defaults: UserDefaults
    private let key: String

    /// The visible widgets, in display order.
    @Published private(set) var visibleWidgets: [IslandWidgetID]

    /// Every known widget in the order used by the settings editor. Visible
    /// widgets come first, followed by hidden widgets in their stable enum
    /// order.
    var editorWidgets: [IslandWidgetID] {
        visibleWidgets + IslandWidgetID.allCases.filter { !visibleWidgets.contains($0) }
    }

    init(defaults: UserDefaults = .standard, key: String = "island.visibleWidgets") {
        self.defaults = defaults
        self.key = key
        self.visibleWidgets = Self.load(from: defaults, key: key)
        if key == Self.defaultKey, !defaults.bool(forKey: Self.usageSeedKey) {
            if !visibleWidgets.contains(.usage) {
                visibleWidgets.append(.usage)
                defaults.set(visibleWidgets.map(\.rawValue), forKey: key)
            }
            defaults.set(true, forKey: Self.usageSeedKey)
        }
    }

    /// Returns whether the widget is currently visible.
    func contains(_ widget: IslandWidgetID) -> Bool {
        visibleWidgets.contains(widget)
    }

    /// Makes a widget visible if it is hidden. This is a no-op when it is
    /// already visible.
    func ensureVisible(_ widget: IslandWidgetID) {
        guard !contains(widget) else { return }
        visibleWidgets.append(widget)
        persist()
    }

    /// Changes a widget's visibility. At least one widget is always kept
    /// visible, so disabling the final visible widget is ignored.
    func setVisible(widget: IslandWidgetID, _ visible: Bool) {
        if visible {
            ensureVisible(widget)
            return
        }

        guard contains(widget), visibleWidgets.count > 1 else { return }
        visibleWidgets.removeAll { $0 == widget }
        persist()
    }

    /// Unlabeled forwarding overload for compact call sites such as
    /// setVisible(widget, true).
    func setVisible(_ widget: IslandWidgetID, _ visible: Bool) {
        setVisible(widget: widget, visible)
    }

    /// Moves a visible widget by ``offset`` places. Negative values move it
    /// toward the beginning; positive values move it toward the end.
    func move(_ widget: IslandWidgetID, by offset: Int) {
        guard offset != 0, let index = visibleWidgets.firstIndex(of: widget) else { return }

        let destination: Int
        if offset < 0 {
            // Avoid negating Int.min, and subtract only a distance that can
            // fit between the current index and the beginning of the array.
            let distance = offset == Int.min ? index : min(index, -offset)
            destination = index - distance
        } else {
            let distance = min(visibleWidgets.count - 1 - index, offset)
            destination = index + distance
        }
        guard destination != index else { return }
        visibleWidgets.move(fromOffsets: IndexSet(integer: index), toOffset: destination > index ? destination + 1 : destination)
        persist()
    }

    /// Restores the default order and makes every known widget visible.
    func reset() {
        let defaults = IslandWidgetID.allCases
        guard visibleWidgets != defaults else { return }
        visibleWidgets = defaults
        persist()
    }

    private func persist() {
        defaults.set(visibleWidgets.map(\.rawValue), forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [IslandWidgetID] {
        guard let stored = defaults.object(forKey: key) else {
            return IslandWidgetID.allCases
        }

        // UserDefaults can bridge numeric arrays through NSNumber, so decode
        // each element instead of relying on a direct [Int] cast. A value of
        // another top-level type is malformed and uses the full default set.
        guard let values = stored as? [Any] else {
            return IslandWidgetID.allCases
        }

        var result: [IslandWidgetID] = []
        for value in values {
            guard let widget = Self.decodeWidget(value), !result.contains(widget) else { continue }
            result.append(widget)
        }

        return result.isEmpty ? IslandWidgetID.allCases : result
    }

    private static func decodeWidget(_ value: Any) -> IslandWidgetID? {
        // Swift integer values and values read back from UserDefaults both
        // bridge to NSNumber. Check the Core Foundation type first because
        // NSCFBoolean also bridges to Int and would otherwise make false look
        // like the Notes ID.
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }

        // Compare against the finite, integral raw values directly. This
        // avoids NSNumber.intValue truncating a malformed fractional value or
        // overflowing a very large numeric value into a valid-looking ID.
        let numericValue = number.doubleValue
        guard numericValue.isFinite, numericValue.rounded() == numericValue else { return nil }
        return IslandWidgetID.allCases.first { Double($0.rawValue) == numericValue }
    }
}

/// Settings rows for the island widget layout. Embed this view inside a
/// ``Form`` section, for example ``Section("Island widgets") {
/// WidgetPreferencesEditor() }``.
@MainActor
struct WidgetPreferencesEditor: View {
    @ObservedObject private var preferences: WidgetPreferences

    init() {
        self.preferences = .shared
    }

    init(preferences: WidgetPreferences) {
        self.preferences = preferences
    }

    var body: some View {
        ForEach(preferences.editorWidgets) { widget in
            widgetRow(widget)
        }

        Button("Reset widget layout", systemImage: "arrow.counterclockwise") {
            preferences.reset()
        }
        .accessibilityHint("Shows all island widgets in their default order")
    }

    private func widgetRow(_ widget: IslandWidgetID) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { preferences.contains(widget) },
                set: { preferences.setVisible(widget: widget, $0) }
            )) {
                Label(widget.title, systemImage: widget.symbol)
            }
            .help("Show \(widget.title) widget in the island")
            .accessibilityHint(preferences.contains(widget) ? "Hide this widget" : "Show this widget")
            .disabled(preferences.contains(widget) && preferences.visibleWidgets.count == 1)

            Spacer(minLength: 4)

            HStack(spacing: 2) {
                Button {
                    preferences.move(widget, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMove(widget, by: -1))
                .help("Move \(widget.title) up")
                .accessibilityLabel("Move \(widget.title) up")
                .accessibilityHint("Changes the order of visible island widgets")

                Button {
                    preferences.move(widget, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMove(widget, by: 1))
                .help("Move \(widget.title) down")
                .accessibilityLabel("Move \(widget.title) down")
                .accessibilityHint("Changes the order of visible island widgets")
            }
        }
    }

    private func canMove(_ widget: IslandWidgetID, by offset: Int) -> Bool {
        guard preferences.contains(widget), let index = preferences.visibleWidgets.firstIndex(of: widget) else { return false }
        let destination = min(max(index + offset, 0), preferences.visibleWidgets.count - 1)
        return destination != index
    }
}
