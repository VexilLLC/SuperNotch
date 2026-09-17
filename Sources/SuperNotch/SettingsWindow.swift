import SwiftUI
import AppKit
import ServiceManagement

/// A custom, island-styled Settings window.
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible == true }

    func show(section: SettingsSection? = nil) {
        if let section { SettingsNavigation.shared.section = section }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 580), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "SuperNotch Settings"
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(white: 0.035, alpha: 1)
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.tabbingMode = .disallowed
            let host = NSHostingView(rootView: SettingsRootView())
            host.sizingOptions = []
            w.contentView = host
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("SuperNotchSettings")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Release the view tree while Settings is closed.
        let closing = window
        window = nil
        DispatchQueue.main.async { closing?.contentView = nil; AppDelegate.shared?.updateActivationPolicy() }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, island, menuBar, music, shelf, widgets, aiUsage, shortcuts, privacy, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .island: return "Island"
        case .menuBar: return "Menu Bar"
        case .music: return "Music"
        case .shelf: return "Shelf"
        case .widgets: return "Widgets"
        case .aiUsage: return "AI Usage"
        case .shortcuts: return "Shortcuts"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }
    var subtitle: String {
        switch self {
        case .general: return "Startup, colors and the main window."
        case .island: return "How the notch looks and behaves."
        case .menuBar: return "Live stats and usage next to the clock."
        case .music: return "Where Now Playing comes from."
        case .shelf: return "Files, baskets and retention."
        case .widgets: return "Choose and order island widgets."
        case .aiUsage: return "Track limits for your coding subscriptions."
        case .shortcuts: return "Keys that reach SuperNotch from anywhere."
        case .privacy: return "What stays on this Mac."
        case .about: return "An open-source home for your notch."
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .island: return "capsule.fill"
        case .menuBar: return "menubar.rectangle"
        case .music: return "music.note"
        case .shelf: return "tray.fill"
        case .widgets: return "square.grid.2x2.fill"
        case .aiUsage: return "chart.bar.fill"
        case .shortcuts: return "command"
        case .privacy: return "hand.raised.fill"
        case .about: return "sparkles"
        }
    }
    var color: Color {
        switch self {
        case .general: return .gray
        case .island: return .blue
        case .menuBar: return .cyan
        case .music: return .pink
        case .shelf: return .purple
        case .widgets: return .orange
        case .aiUsage: return .purple
        case .shortcuts: return .teal
        case .privacy: return .green
        case .about: return .indigo
        }
    }
}

@MainActor final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var section: SettingsSection = .general
}

// MARK: - Root

private struct SettingsRootView: View {
    @ObservedObject private var navigation = SettingsNavigation.shared
    @ObservedObject private var preferences = Preferences.shared
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            ZStack(alignment: .top) {
                RadialGradient(colors: [navigation.section.color.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 420)
                    .frame(height: 320).allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.35), value: navigation.section)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(navigation.section.title).font(.system(size: 28, weight: .bold, design: .rounded))
                            Text(navigation.section.subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.bottom, 4)
                        content.id(navigation.section)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                    }
                    .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(white: 0.035))
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .tint(preferences.accent)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SuperNotch").font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("Settings").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 10).padding(.top, 48).padding(.bottom, 18)

            ForEach(SettingsSection.allCases) { section in
                let selected = navigation.section == section
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { navigation.section = section }
                } label: {
                    HStack(spacing: 10) {
                        SymbolTile(systemImage: section.symbol, color: section.color, size: 24)
                        Text(section.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.09))
                                .matchedGeometryEffect(id: "section", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(IslandPressStyle())
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Local by design").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 12).padding(.bottom, 18)
        }
        .padding(.horizontal, 10)
        .frame(width: 214)
        .background(Color.white.opacity(0.02))
    }

    @ViewBuilder private var content: some View {
        switch navigation.section {
        case .general: GeneralSettingsPage()
        case .island: IslandSettingsPage()
        case .menuBar: MenuBarSettingsPage()
        case .music: MusicSettingsPage()
        case .shelf: ShelfSettingsPage()
        case .widgets: WidgetSettingsPage()
        case .aiUsage: AIUsageSettingsPage()
        case .shortcuts: ShortcutSettingsPage()
        case .privacy: PrivacySettingsPage()
        case .about: AboutSettingsPage()
        }
    }
}

// MARK: - Components

struct SettingsCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(.white.opacity(0.38)).padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 0.7))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SymbolTile(systemImage: symbol, color: color, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            if divider { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 54) }
        }
    }
}

/// A glowing capsule switch.
struct NotchToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.white.opacity(0.14)))
                    .shadow(color: isOn ? Color.accentColor.opacity(0.55) : .clear, radius: 8)
                Circle().fill(.white).padding(2.5).shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            }
            .frame(width: 42, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct ChipPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var namespace
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let selected = option.0 == selection
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option.0 } } label: {
                    Text(option.1).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background {
                            if selected { Capsule().fill(Color.accentColor.opacity(0.85)).matchedGeometryEffect(id: "chip", in: namespace) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(IslandPressStyle())
            }
        }
        .padding(3)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.white.opacity(0.1)), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct Keycaps: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1).fixedSize()
                    .frame(minWidth: 24, minHeight: 24).padding(.horizontal, key.count > 1 ? 6 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.07)], startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.4), radius: 0, y: 1.5)
            }
        }
    }
}

// MARK: - Pages

private struct GeneralSettingsPage: View {
    @ObservedObject private var preferences = Preferences.shared
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var message: String?
    private let swatches: [(String, Color)] = [("Blue", .blue), ("Violet", .purple), ("Mint", .mint), ("Orange", .orange), ("Pink", .pink)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Startup") {
                SettingsRow(symbol: "power", color: .green, title: "Launch at login", detail: message ?? "Start SuperNotch quietly when you sign in.", divider: false) {
                    NotchToggle(isOn: $login)
                }
            }
            .onChange(of: login) { _, value in
                do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { message = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
            }

            SettingsCard(title: "Appearance") {
                SettingsRow(symbol: "paintpalette.fill", color: .pink, title: "Highlight color", detail: "Used by the island, basket and workspace.", divider: false) {
                    HStack(spacing: 8) {
                        swatch("System", AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
                        ForEach(swatches, id: \.0) { name, color in swatch(name, color) }
                    }
                }
            }

            SettingsCard(title: "Workspace") {
                SettingsRow(symbol: "macwindow", color: .blue, title: "Main window", detail: "Your shelf, clipboard, player and tools in one place.", divider: false) {
                    Button("Open") { AppDelegate.shared?.openWorkspace() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
        }
    }

    private func swatch<S: ShapeStyle>(_ name: String, _ fill: S) -> some View {
        let selected = preferences.accentName == name
        return Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { preferences.accentName = name } } label: {
            Circle().fill(fill).frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().stroke(.white.opacity(selected ? 0.9 : 0), lineWidth: 2))
                .scaleEffect(selected ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .help(name == "System" ? "System accent" : name)
        .accessibilityLabel(name == "System" ? "System accent" : name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct IslandSettingsPage: View {
    @ObservedObject private var preferences = Preferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            IslandPreview(floating: preferences.island, outline: preferences.outline)

            SettingsCard(title: "Shape") {
                SettingsRow(symbol: "rectangle.topthird.inset.filled", color: .blue, title: "Style", detail: preferences.island ? "A floating pill below the menu bar." : "Merged into the hardware notch.") {
                    ChipPicker(options: [(false, "Notch"), (true, "Floating")], selection: $preferences.island)
                }
                SettingsRow(symbol: "circle.dashed", color: .gray, title: "Subtle outline", detail: "A faint edge around the open island.", divider: false) {
                    NotchToggle(isOn: $preferences.outline)
                }
            }

            SettingsCard(title: "Behavior") {
                SettingsRow(symbol: "display.2", color: .indigo, title: "Show on every display", detail: "Add an island to each connected screen.") {
                    NotchToggle(isOn: $preferences.allDisplays)
                }
                SettingsRow(symbol: "bolt.fill", color: .yellow, title: "Live activities", detail: "Charging, Caps Lock, connectivity, files and focus appear briefly.", divider: false) {
                    NotchToggle(isOn: $preferences.liveActivities)
                }
            }

            SettingsCard(title: "Home") {
                HStack(spacing: 10) {
                    ForEach(IslandHomeLayout.allCases) { layout in layoutCard(layout) }
                }
                .padding(12)
            }
        }
    }

    private func layoutCard(_ layout: IslandHomeLayout) -> some View {
        let selected = preferences.homeLayout == layout
        let symbols: [String] = {
            switch layout {
            case .musicFocus: return ["music.note", "timer"]
            case .focusMusic: return ["timer", "music.note"]
            case .music: return ["music.note"]
            case .focus: return ["timer"]
            }
        }()
        return Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { preferences.homeLayout = layout } } label: {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(symbols, id: \.self) { symbol in
                        Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
                .padding(6).frame(height: 50)
                .background(.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(layout.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(selected ? 1 : 0.55))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? Color.accentColor : .white.opacity(0.08), lineWidth: selected ? 1.5 : 0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle())
    }
}

/// A miniature menu bar with a live island that reflects the current shape settings.
private struct IslandPreview: View {
    let floating: Bool
    let outline: Bool
    @ObservedObject private var media = MediaController.shared
    @State private var expanded = false
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.26, blue: 0.5), Color(red: 0.45, green: 0.3, blue: 0.55), Color(red: 0.95, green: 0.55, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack {
                Image(systemName: "apple.logo").font(.system(size: 11))
                Text("Finder").font(.system(size: 11, weight: .bold))
                Spacer()
                Image(systemName: "wifi").font(.system(size: 10))
                Text(Date.now, style: .time).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14).frame(height: 22)
            .background(.black.opacity(0.18))

            let width: CGFloat = expanded ? 250 : (media.playing ? 160 : 110)
            let height: CGFloat = expanded ? 92 : 22
            Group {
                if floating {
                    RoundedRectangle(cornerRadius: expanded ? 20 : 11, style: .continuous).fill(.black)
                } else {
                    NotchShape(topRadius: expanded ? 8 : 5, bottomRadius: expanded ? 18 : 8).fill(.black)
                }
            }
            .overlay {
                Group {
                    if floating { RoundedRectangle(cornerRadius: expanded ? 20 : 11, style: .continuous).stroke(.white.opacity(outline ? 0.25 : 0), lineWidth: 0.8) }
                    else { NotchShape(topRadius: expanded ? 8 : 5, bottomRadius: expanded ? 18 : 8).stroke(.white.opacity(outline && expanded ? 0.25 : 0), lineWidth: 0.8) }
                }
            }
            .overlay(alignment: expanded ? .center : .top) {
                if expanded {
                    HStack(spacing: 10) {
                        MediaArtworkView(size: 40, cornerRadius: 9)
                        VStack(alignment: .leading, spacing: 5) {
                            Capsule().fill(.white.opacity(0.85)).frame(width: 90, height: 6)
                            Capsule().fill(.white.opacity(0.35)).frame(width: 60, height: 5)
                            Capsule().fill(.white.opacity(0.2)).frame(width: 130, height: 3)
                        }
                    }
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
                }
            }
            .frame(width: width + (floating ? 0 : 16), height: height)
            .padding(.top, floating ? 28 : 0)
            .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 12, y: 6)
            .onTapGesture { withAnimation(IslandMotion.open) { expanded.toggle() } }
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 0.7))
        .overlay(alignment: .bottomTrailing) {
            Text(expanded ? "Click to close" : "Click the island")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.35), in: Capsule()).padding(10)
        }
        .animation(IslandMotion.open, value: floating)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(IslandMotion.open) { expanded = true }
        }
    }
}

private struct MusicSettingsPage: View {
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var spotifyDock = SpotifyDockManager.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Now Playing") {
                HStack(spacing: 14) {
                    MediaArtworkView(size: 64, cornerRadius: 12, showsAppBadge: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(media.enabled ? media.title : "Nothing playing").font(.system(size: 15, weight: .bold)).lineLimit(1)
                        Text(media.enabled ? media.artist : "Play something in any app").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        if let app = media.appName { Text("Playing in \(app)").font(.system(size: 11, weight: .medium)).foregroundStyle(.tint) }
                    }
                    Spacer()
                }
                .padding(14)
            }

            SettingsCard(title: "Source") {
                SettingsRow(symbol: "waveform", color: .pink, title: "Player", detail: media.isAutomatic ? "Follows any app: browsers, Spotify, Apple Music and video players." : "Uses AppleScript. macOS may ask for Automation access.", divider: false) {
                    ChipPicker(options: [("Automatic", "Any Player"), ("Music", "Apple Music"), ("Spotify", "Spotify")], selection: $media.source)
                }
            }
            SettingsCard(title: "Spotify Dock Icon") {
                SettingsRow(symbol: "dock.rectangle", color: .green, title: spotifyDock.isPrepared ? "Hidden while Spotify runs" : "Hide Spotify from the Dock", detail: spotifyDockDetail, divider: false) {
                    if spotifyDock.isBusy {
                        ProgressView().controlSize(.small)
                    } else if spotifyDock.isPrepared {
                        HStack(spacing: 8) {
                            Button("Open Spotify") { spotifyDock.focusSpotify() }.buttonStyle(PillButtonStyle(prominent: true))
                            Button("Restore") { spotifyDock.restore() }.buttonStyle(PillButtonStyle())
                        }
                    } else {
                        Button("Set Up") { spotifyDock.prepare() }.buttonStyle(PillButtonStyle(prominent: true)).disabled(spotifyDock.state == .unavailable)
                    }
                }
                if case .failed(let message) = spotifyDock.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange).padding(.horizontal, 14).padding(.bottom, 8)
                }
                Text("SuperNotch installs its own small local helper into Spotify and re-signs the app. A complete original backup is kept for Restore; Spotify updates may require Set Up again.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.42)).padding(.horizontal, 14).padding(.bottom, 14)
            }
            if let error = media.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
            }
            if !media.enabled && !media.isAutomatic {
                Button("Connect player") { media.connect() }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .task { spotifyDock.refresh() }
    }

    private var spotifyDockDetail: String {
        switch spotifyDock.state {
        case .unavailable: return "Spotify is not installed."
        case .ready: return "Keep playback and the full Spotify window, without its Dock or ⌘Tab icon."
        case .preparing: return "Backing up and preparing Spotify \(spotifyDock.spotifyVersion)…"
        case .prepared: return "Use Open Spotify whenever you want the full window."
        case .restoring: return "Restoring the untouched signed Spotify app…"
        case .failed: return "Setup needs attention."
        }
    }
}

private struct ShelfSettingsPage: View {
    @ObservedObject private var preferences = Preferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Gathering files") {
                SettingsRow(symbol: "hand.draw.fill", color: .purple, title: "Shake to open the basket", detail: "Wiggle a file drag to summon the floating basket.", divider: false) {
                    NotchToggle(isOn: $preferences.shakeBasket)
                }
            }
            SettingsCard(title: "Retention") {
                SettingsRow(symbol: "clock.arrow.circlepath", color: .orange, title: "Keep unpinned files", detail: "Removes shelf references only. Pinned items stay and originals are never deleted.", divider: false) {
                    ChipPicker(options: [(ShelfRetention.forever, "Always"), (.hour, "1h"), (.day, "1d"), (.week, "1w")], selection: $preferences.shelfRetention)
                }
            }
        }
    }
}

private struct WidgetSettingsPage: View {
    @ObservedObject private var widgets = WidgetPreferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Island widgets") {
                let items = widgets.editorWidgets
                ForEach(Array(items.enumerated()), id: \.element) { index, widget in
                    let visible = widgets.contains(widget)
                    SettingsRow(symbol: widget.symbol, color: visible ? .orange : .gray, title: widget.title, detail: visible ? "Shown in the island" : "Hidden", divider: index < items.count - 1) {
                        HStack(spacing: 10) {
                            HStack(spacing: 0) {
                                reorder(widget, "chevron.up", -1)
                                reorder(widget, "chevron.down", 1)
                            }
                            .background(.white.opacity(0.07), in: Capsule())
                            NotchToggle(isOn: Binding(get: { widgets.contains(widget) }, set: { widgets.setVisible(widget: widget, $0) }))
                                .disabled(visible && widgets.visibleWidgets.count == 1)
                                .opacity(visible && widgets.visibleWidgets.count == 1 ? 0.5 : 1)
                        }
                    }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: widgets.editorWidgets)
            Button { widgets.reset() } label: { Label("Reset layout", systemImage: "arrow.counterclockwise") }.buttonStyle(PillButtonStyle())
        }
    }
    private func reorder(_ widget: IslandWidgetID, _ symbol: String, _ offset: Int) -> some View {
        let enabled: Bool = {
            guard widgets.contains(widget), let index = widgets.visibleWidgets.firstIndex(of: widget) else { return false }
            return min(max(index + offset, 0), widgets.visibleWidgets.count - 1) != index
        }()
        return Button { widgets.move(widget, by: offset) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(offset < 0 ? "Move \(widget.title) up" : "Move \(widget.title) down")
    }
}

private struct ShortcutSettingsPage: View {
    private let shortcuts: [(String, String, Color, [String])] = [
        ("Command palette", "command.square.fill", .indigo, ["⌥", "Space"]),
        ("Toggle island", "capsule.fill", .blue, ["⇧", "⌘", "Space"]),
        ("Clipboard strip", "list.clipboard.fill", .purple, ["⇧", "⌘", "V"]),
        ("Floating basket", "basket.fill", .orange, ["⇧", "⌘", "B"]),
        ("Quick notes", "note.text", .yellow, ["⇧", "⌘", "N"]),
        ("Agenda", "calendar", .red, ["⇧", "⌘", "A"]),
        ("Cursor ring", "circle.hexagongrid.fill", .teal, ["⇧", "⌘", "R"])
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Global") {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, item in
                    SettingsRow(symbol: item.1, color: item.2, title: item.0, divider: index < shortcuts.count - 1) { Keycaps(keys: item.3) }
                }
            }
            SettingsCard(title: "Inside the island") {
                SettingsRow(symbol: "square.grid.3x1.below.line.grid.1x2", color: .gray, title: "Switch pages", detail: "Home, Tray and Widgets") { Keycaps(keys: ["⌘", "1 2 3"]) }
                SettingsRow(symbol: "xmark", color: .gray, title: "Close", divider: false) { Keycaps(keys: ["Esc"]) }
            }
        }
    }
}

private struct PrivacySettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield.fill").font(.system(size: 30)).foregroundStyle(.green.gradient)
                Text("Camera, microphone, calendar and reminders are requested only when you use them. Clipboard history and shelf references stay in this Mac’s Application Support folder, and entries marked concealed or transient are skipped.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(LinearGradient(colors: [.green.opacity(0.14), .green.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.green.opacity(0.2), lineWidth: 0.7))

            SettingsCard(title: "Manage") {
                SettingsRow(symbol: "hand.raised.fill", color: .blue, title: "Permissions", detail: "Review access in System Settings.") {
                    Button("Open") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!) }.buttonStyle(PillButtonStyle())
                }
                SettingsRow(symbol: "folder.fill", color: .cyan, title: "Local data", detail: "Clipboard history, shelf and recordings.", divider: false) {
                    Button("Show") {
                        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SuperNotch")
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(url)
                    }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }
}

private struct AboutSettingsPage: View {
    @State private var glow = false
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
                .shadow(color: .accentColor.opacity(glow ? 0.6 : 0.25), radius: glow ? 34 : 18)
                .onAppear { withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { glow = true } }
            Text("SuperNotch").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Version 0.1.0").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 4).background(.white.opacity(0.08), in: Capsule())
            Text("An independent, open-source Swift app that turns the notch into a little home for your files, music and focus. MIT licensed.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}
