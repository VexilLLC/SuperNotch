import SwiftUI
import AppKit

// Shared building blocks for the workspace and Settings windows.
// These follow the system appearance; the island, strip, basket and ring keep their own dark surfaces.

extension View {
    /// A grouped content surface in the style of System Settings boxes.
    func cardStyle(padding: CGFloat = 16, cornerRadius: CGFloat = 10) -> some View {
        self.padding(padding)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    /// A list-like row surface, optionally highlighted when selected.
    func rowStyle(selected: Bool = false, padding: CGFloat = 10, cornerRadius: CGFloat = 8) -> some View {
        self.padding(padding)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.fill.quaternary), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A text-entry surface that matches native text views in both appearances.
    func editorStyle(cornerRadius: CGFloat = 8) -> some View {
        self.scrollContentBackground(.hidden)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// A rounded, tinted SF Symbol tile, similar to the icons in System Settings.
struct SymbolTile: View {
    let systemImage: String
    var color: Color = .accentColor
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A section title with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var accessory: Accessory
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let systemImage { Label(title, systemImage: systemImage).font(.headline) } else { Text(title).font(.headline) }
            Spacer()
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil) { self.init(title: title, systemImage: systemImage) { EmptyView() } }
}

/// A dismissible inline status message.
struct InlineMessage: View {
    let text: String
    var tone: Color = .secondary
    var onDismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .secondary ? "info.circle" : "exclamationmark.triangle").foregroundStyle(tone)
            Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss { Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss") }
        }
        .rowStyle()
    }
}

/// Compact rendering of a keyboard shortcut.
struct ShortcutText: View {
    let keys: String
    var body: some View {
        Text(keys)
            .font(.system(.caption, design: .rounded).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// Coarse relative time ("5 min ago") that refreshes every 30 seconds.
///
/// `Text(date, style: .relative)` counts seconds and re-lays out continuously; in long lists that
/// keeps the window rendering. This keeps timestamps current at a fraction of the cost.
struct RelativeTimeText: View {
    let date: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.label(for: date, now: context.date))
        }
    }
    static func label(for date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 45 { return "Just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
