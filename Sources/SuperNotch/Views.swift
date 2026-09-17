import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case page(AppState.Page)
    case tool(ToolGroup)
}

extension AppState.Page {
    var color: Color {
        switch self {
        case .home: return .blue
        case .files: return .purple
        case .clipboard: return .indigo
        case .media: return .pink
        case .productivity: return .orange
        case .tools: return .gray
        case .extensions: return .teal
        }
    }
    var tileIcon: String {
        switch self {
        case .home: return "square.grid.2x2.fill"
        case .files: return "tray.full.fill"
        case .clipboard: return "list.clipboard.fill"
        case .media: return "music.note"
        case .productivity: return "timer"
        case .tools: return "wrench.and.screwdriver.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        }
    }
}

/// A window-sized accent wash for the workspace. The previous implementation
/// used a fixed-height gradient, which exposed a horizontal edge in tall or
/// fullscreen windows. GeometryReader keeps the fade continuous at any size.
struct WorkspaceAccentBackground: View {
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let radius = max(geometry.size.width, geometry.size.height) * 1.05
            RadialGradient(
                stops: [
                    .init(color: color.opacity(0.16), location: 0),
                    .init(color: color.opacity(0.07), location: 0.34),
                    .init(color: .clear, location: 1)
                ],
                center: .top,
                startRadius: 0,
                endRadius: radius
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The main window, styled like the island and Settings: dark, full-bleed, custom sidebar.
struct WorkspaceView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var shelf = FileShelfStore.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var productivity = ProductivityStore.shared
    @ObservedObject private var media = MediaController.shared
    @Namespace private var selectionNamespace

    private var selection: SidebarItem { state.page == .tools ? .tool(currentTool) : .page(state.page) }
    private var currentTool: ToolGroup { ToolGroup(rawValue: state.toolGroup) ?? .capture }
    private var accentColor: Color { state.page == .tools ? currentTool.color : state.page.color }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            ZStack(alignment: .top) {
                WorkspaceAccentBackground(color: accentColor)
                    .animation(.easeInOut(duration: 0.35), value: selection)
                VStack(alignment: .leading, spacing: 14) {
                    header.padding(.horizontal, 28).padding(.top, 40)
                    detail
                        .id(selection)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(Color(white: 0.035))
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .tint(preferences.accent)
        .preferredColorScheme(.dark)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Group {
                    if let icon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "rectangle.topthird.inset.filled").resizable().scaledToFit().padding(5).foregroundStyle(.blue)
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SuperNotch").font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(media.enabled && media.playing ? "♪ \(media.title)" : "Your notch, upgraded").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            .padding(.horizontal, 18).padding(.top, 46).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.page(.home), AppState.Page.home.rawValue, AppState.Page.home.tileIcon, AppState.Page.home.color)
                    row(.page(.files), AppState.Page.files.rawValue, AppState.Page.files.tileIcon, AppState.Page.files.color, badge: shelf.activeItems.count)
                    row(.page(.clipboard), AppState.Page.clipboard.rawValue, AppState.Page.clipboard.tileIcon, AppState.Page.clipboard.color, badge: clipboard.items.count)
                    sectionLabel("Focus & Media")
                    row(.page(.productivity), AppState.Page.productivity.rawValue, AppState.Page.productivity.tileIcon, AppState.Page.productivity.color, badgeText: productivity.running ? productivity.focusRemainingText : nil)
                    row(.page(.media), AppState.Page.media.rawValue, AppState.Page.media.tileIcon, AppState.Page.media.color, live: media.enabled && media.playing)
                    sectionLabel("Tools")
                    ForEach(ToolGroup.allCases) { group in row(.tool(group), group.title, group.icon, group.color) }
                    sectionLabel("More")
                    row(.page(.extensions), AppState.Page.extensions.rawValue, AppState.Page.extensions.tileIcon, AppState.Page.extensions.color)
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            .scrollIndicators(.never)

            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Stored on this Mac").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button { AppDelegate.shared?.openSettings() } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(IslandPressStyle()).help("Settings (⌘,)")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 230)
        .background(Color.white.opacity(0.02))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.1).foregroundStyle(.white.opacity(0.35))
            .padding(.leading, 10).padding(.top, 14).padding(.bottom, 4)
    }

    private func row(_ item: SidebarItem, _ title: String, _ icon: String, _ color: Color, badge: Int? = nil, badgeText: String? = nil, live: Bool = false) -> some View {
        let selected = selection == item
        return Button { select(item) } label: {
            HStack(spacing: 10) {
                SymbolTile(systemImage: icon, color: color, size: 24)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .medium)).foregroundStyle(.white.opacity(selected ? 1 : 0.72)).lineLimit(1)
                Spacer(minLength: 4)
                if live { LevelBars(playing: true, color: color, count: 3, barWidth: 2, spacing: 1.5, maxHeight: 11) }
                if let badgeText {
                    Text(badgeText).font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.orange.opacity(0.16), in: Capsule())
                } else if let badge, badge > 0 {
                    Text("\(badge)").font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.white.opacity(0.08), in: Capsule())
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.09))
                        .matchedGeometryEffect(id: "workspaceSelection", in: selectionNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ item: SidebarItem) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            state.toolDetail = ""
            switch item {
            case .page(let page): state.page = page
            case .tool(let group): state.toolGroup = group.rawValue; state.page = .tools
            }
        }
    }

    // MARK: Header and detail

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 8) {
                headerButton("list.clipboard.fill", help: "Clipboard strip (⇧⌘V)") { AppDelegate.shared?.openClipboard() }
                headerButton("basket.fill", help: "Floating basket (⇧⌘B)") { BasketController.shared.show() }
                Button { AppDelegate.shared?.toggleShelf() } label: { Label("Island", systemImage: "capsule.fill") }
                    .buttonStyle(PillButtonStyle(prominent: true)).help("Show or hide the island (⇧⌘Space)")
            }
        }
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
                .background(.white.opacity(0.08), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.7))
        }
        .buttonStyle(IslandPressStyle()).help(help).accessibilityLabel(help)
    }

    @ViewBuilder private var detail: some View {
        switch state.page {
        case .home: DashboardView()
        case .files: FileShelfView().padding(.horizontal, 20).padding(.bottom, 20)
        case .clipboard: ClipboardHistoryView()
        case .media: MediaView()
        case .productivity: ProductivityView(initialTool: state.toolDetail)
        case .tools: currentTool.content(detail: state.toolDetail)
        case .extensions: ExtensionsView()
        }
    }

    private var title: String { state.page == .tools ? currentTool.title : state.page.rawValue }

    private var subtitle: String {
        switch state.page {
        case .home: return Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .files: return "\(shelf.activeItems.count) \(shelf.activeItems.count == 1 ? "item" : "items") in \(shelf.activeBasket.name)"
        case .clipboard: return clipboard.isPaused ? "Capture paused" : "\(clipboard.items.count) saved \(clipboard.items.count == 1 ? "item" : "items")"
        case .media: return media.isAutomatic ? (media.appName.map { "Playing in \($0)" } ?? "Any player") : (media.source == "Music" ? "Apple Music" : "Spotify")
        case .productivity: return productivity.running ? "Focusing · \(productivity.focusRemainingText) left" : "Timer, notes, agenda and Keep Awake"
        case .tools: return currentTool.subtitle
        case .extensions: return "\(ExtensionItem.all.filter { $0.page != nil }.count) available · \(ExtensionItem.all.filter { $0.page == nil }.count) planned"
        }
    }
}

/// A dark capsule search field used in place of toolbar search.
struct WorkspaceSearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.45)) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: 280)
        .background(.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(focused ? Color.accentColor.opacity(0.8) : .white.opacity(0.08), lineWidth: focused ? 1.5 : 0.7))
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

struct DashboardView: View {
    @ObservedObject private var system = SystemMonitor.shared
    @ObservedObject private var shelf = FileShelfStore.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var productivity = ProductivityStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    metric("File Shelf", value: "\(shelf.activeItems.count)", caption: "in \(shelf.activeBasket.name)", icon: "tray.full.fill", color: .blue) { AppState.shared.page = .files }
                    metric("Clipboard", value: "\(clipboard.items.count)", caption: clipboard.isPaused ? "Capture paused" : "Saved copies", icon: "list.clipboard.fill", color: .purple) { AppState.shared.page = .clipboard }
                    metric("Focus", value: productivity.focusRemainingText, caption: productivity.running ? "In progress" : "Ready to start", icon: "timer", color: .orange) { AppState.shared.page = .productivity }
                    metric(system.hasBattery ? "Battery" : "Uptime", value: system.hasBattery ? "\(system.battery)%" : system.uptime, caption: system.hasBattery ? (system.charging ? "Charging" : "On battery") : "Since last restart", icon: system.hasBattery ? (system.charging ? "battery.100percent.bolt" : "battery.75percent") : "clock", color: .green) {
                        AppState.shared.toolDetail = system.hasBattery ? "Battery" : "Performance"
                        AppState.shared.toolGroup = ToolGroup.activity.rawValue; AppState.shared.page = .tools
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick Actions").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                        action("Island", icon: "rectangle.topthird.inset.filled", shortcut: "⇧⌘Space") { AppDelegate.shared?.toggleShelf() }
                        action("Clipboard", icon: "list.clipboard", shortcut: "⇧⌘V") { AppDelegate.shared?.openClipboard() }
                        action("Basket", icon: "tray", shortcut: "⇧⌘B") { BasketController.shared.show() }
                        action("Quick Note", icon: "note.text", shortcut: "⇧⌘N") { AppDelegate.shared?.openNotesWidget() }
                        action("Agenda", icon: "calendar", shortcut: "⇧⌘A") { AppDelegate.shared?.openAgendaWidget() }
                        action("Cursor Ring", icon: "circle.hexagongrid", shortcut: "⇧⌘R") { QuickRingController.shared.show() }
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    nowPlaying
                    yourMac
                }

                SystemPerformanceView()
            }
            .padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 4)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Now Playing", systemImage: "play.circle") {
                Button("Open Player") { AppState.shared.page = .media }.buttonStyle(.link).font(.callout)
            }
            HStack(spacing: 12) {
                MediaArtworkView(size: 56, cornerRadius: 8, showsAppBadge: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.enabled ? media.title : "Nothing playing").font(.body.weight(.medium)).lineLimit(1)
                    Text(media.enabled ? media.artist : "Play something in any app").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if media.enabled {
                    HStack(spacing: 14) {
                        Button { media.command("previous track") } label: { Image(systemName: "backward.fill") }.help("Previous track")
                        Button { media.command("playpause") } label: { Image(systemName: media.playing ? "pause.fill" : "play.fill").font(.title3) }.help(media.playing ? "Pause" : "Play")
                        Button { media.command("next track") } label: { Image(systemName: "forward.fill") }.help("Next track")
                    }.buttonStyle(.borderless)
                } else {
                    Button("Connect") { media.connect() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var yourMac: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Your Mac", systemImage: "laptopcomputer")
            HStack(alignment: .top) {
                status("Memory", String(format: "%.1f GB", system.memoryUsed))
                Divider().frame(height: 30)
                status("Network", system.connected ? "Online" : "Offline")
                Divider().frame(height: 30)
                status("Uptime", system.uptime)
            }
            Label(system.activity, systemImage: system.connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func status(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, value: String, caption: String, icon: String, color: Color, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SymbolTile(systemImage: icon, color: color, size: 24)
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                Text(value).font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 14)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func action(_ title: String, icon: String, shortcut: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.tint).frame(width: 20)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Keycaps(keys: shortcut.map { String($0) }.reduce(into: [String]()) { keys, char in
                    if ["⇧", "⌘"].contains(char) || keys.isEmpty || ["⇧", "⌘"].contains(keys.last!) { keys.append(char) } else { keys[keys.count - 1] += char }
                })
                .scaleEffect(0.85)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 0.7))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(IslandPressStyle())
    }
}
