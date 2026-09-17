import SwiftUI

/// Tool collections shown as individual sidebar destinations. Raw values match `AppState.toolGroup`.
enum ToolGroup: Int, CaseIterable, Identifiable {
    case capture, commands, sensors, processing, connections, actions, share, prompter, activity
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .capture: return "Capture & OCR"
        case .commands: return "Commands"
        case .sensors: return "Camera & Voice"
        case .processing: return "File Studio"
        case .connections: return "Connections"
        case .actions: return "Quick Actions"
        case .share: return "File Links"
        case .prompter: return "Teleprompter"
        case .activity: return "Activity"
        }
    }
    var icon: String {
        switch self {
        case .capture: return "text.viewfinder"
        case .commands: return "command"
        case .sensors: return "camera"
        case .processing: return "wand.and.rays"
        case .connections: return "link.circle"
        case .actions: return "circle.hexagongrid"
        case .share: return "network"
        case .prompter: return "text.alignleft"
        case .activity: return "gauge.with.dots.needle.33percent"
        }
    }
    var color: Color {
        switch self {
        case .capture: return .indigo
        case .commands: return .gray
        case .sensors: return .red
        case .processing: return .orange
        case .connections: return .cyan
        case .actions: return .teal
        case .share: return .blue
        case .prompter: return .yellow
        case .activity: return .green
        }
    }
    var subtitle: String {
        switch self {
        case .capture: return "Screenshots, text recognition and image conversion"
        case .commands: return "Launcher, shell commands and window layout"
        case .sensors: return "Mirror, voice memos, transcription and emoji"
        case .processing: return "Lighter copies of videos, PDFs and images"
        case .connections: return "Markdown vault, weather and coding agents"
        case .actions: return "Cursor ring, typing sounds and Finder Services"
        case .share: return "Temporary download links on your network"
        case .prompter: return "Your script, at your pace"
        case .activity: return "Battery health, apps, CPU, storage and network"
        }
    }
    @MainActor @ViewBuilder func content(detail: String) -> some View {
        switch self {
        case .capture: CaptureToolsView()
        case .commands: CommandToolsView(initialTool: detail)
        case .sensors: SensorToolsView(initialTool: detail)
        case .processing: FileProcessingView()
        case .connections: IntegrationsView(initialTool: detail)
        case .actions: QuickActionsView()
        case .share: LocalSharingView()
        case .prompter: TeleprompterView()
        case .activity: SystemActivitiesView(initialTab: detail)
        }
    }
}

struct ExtensionItem: Identifiable {
    let name: String
    let icon: String
    let description: String
    let status: String
    let page: AppState.Page?
    var id: String { name }
    var toolGroup: Int {
        switch name {
        case "Launcher", "Command palette", "Command runner", "Window snap": return 1
        case "Camera", "Voice notes", "Emoji picker": return 2
        case "PDF & video compression": return 3
        case "Weather", "Obsidian", "Agent activities": return 4
        case "Cursor ring", "Key sounds": return 5
        case "Local file links": return 6
        case "Teleprompter": return 7
        case "System activities": return 8
        default: return 0
        }
    }
    static let all: [ExtensionItem] = [
        .init(name: "File shelf & basket", icon: "tray.full.fill", description: "Gather files, pin them, preview and share.", status: "Available", page: .files),
        .init(name: "Clipboard", icon: "doc.on.clipboard", description: "Searchable local text, images and files.", status: "Available", page: .clipboard),
        .init(name: "Music & Spotify", icon: "music.note", description: "Playback, seeking and system volume.", status: "Available", page: .media),
        .init(name: "Pomodoro", icon: "timer", description: "Focus and break timers with saved deadlines.", status: "Available", page: .productivity),
        .init(name: "Notes", icon: "note.text", description: "Write, keep and copy quick notes locally.", status: "Available", page: .productivity),
        .init(name: "Calendar & reminders", icon: "calendar", description: "Your agenda and tasks, through EventKit.", status: "Available", page: .productivity),
        .init(name: "Keep awake", icon: "cup.and.saucer.fill", description: "Keep your Mac awake during a session.", status: "Available", page: .productivity),
        .init(name: "Capture & OCR", icon: "text.viewfinder", description: "Capture a region. Extract image and PDF text.", status: "Available", page: .tools),
        .init(name: "Image converter", icon: "arrow.triangle.2.circlepath", description: "PNG, JPEG, TIFF and HEIC on your Mac.", status: "Available", page: .tools),
        .init(name: "Remove background", icon: "person.crop.rectangle", description: "Foreground cutouts with Apple Vision.", status: "Available", page: .tools),
        .init(name: "Launcher", icon: "magnifyingglass", description: "Search indexed files and installed apps.", status: "Available", page: .tools),
        .init(name: "Command palette", icon: "command.square.fill", description: "Open apps, SuperNotch actions and local extensions.", status: "Available", page: .tools),
        .init(name: "Command runner", icon: "terminal", description: "Run shell commands and inspect their output.", status: "Available", page: .tools),
        .init(name: "Window snap", icon: "rectangle.lefthalf.inset.filled", description: "Arrange a window with Accessibility access.", status: "Available", page: .tools),
        .init(name: "Camera", icon: "camera.fill", description: "A small live camera preview.", status: "Available", page: .tools),
        .init(name: "Voice notes", icon: "waveform", description: "Record audio and transcribe with Apple Speech.", status: "Available", page: .tools),
        .init(name: "Emoji picker", icon: "face.smiling", description: "Find a little expression and copy it.", status: "Available", page: .tools),
        .init(name: "System stats", icon: "chart.bar.fill", description: "Live CPU, storage, memory and battery readings.", status: "Available", page: .home),
        .init(name: "Teleprompter", icon: "text.alignleft", description: "Script playback with scrolling, mirror and fullscreen.", status: "Available", page: .tools),
        .init(name: "System activities", icon: "bolt.horizontal.circle", description: "Network interfaces, drive eject and observed events.", status: "Available", page: .tools),
        .init(name: "Local file links", icon: "link", description: "Temporary links for selected files on your network.", status: "Available", page: .tools),
        .init(name: "Cloud sharing", icon: "icloud", description: "Needs an independently hosted sharing service.", status: "Planned", page: nil),
        .init(name: "iPhone sync", icon: "iphone", description: "Needs a companion app and encrypted sync service.", status: "Planned", page: nil),
        .init(name: "Lock screen", icon: "lock", description: "Requires separate secure-session integration.", status: "Planned", page: nil),
        .init(name: "Per-app audio", icon: "speaker.wave.2", description: "Requires audio taps and stream routing.", status: "Planned", page: nil),
        .init(name: "Notification mirror", icon: "bell", description: "System notification and reply integration.", status: "Planned", page: nil),
        .init(name: "Lyrics & queue", icon: "text.quote", description: "Timed lyric providers and richer player adapters.", status: "Planned", page: nil),
        .init(name: "Menu bar manager", icon: "menubar.rectangle", description: "Independent menu bar item management.", status: "Planned", page: nil),
        .init(name: "LocalSend", icon: "antenna.radiowaves.left.and.right", description: "Cross-platform local discovery and transfers.", status: "Planned", page: nil),
        .init(name: "Meeting controls", icon: "video", description: "App-specific mute, camera and sharing adapters.", status: "Planned", page: nil),
        .init(name: "Agent activities", icon: "curlybraces", description: "Coding tool event hooks and live progress.", status: "Available", page: .tools),
        .init(name: "Weather", icon: "cloud.sun", description: "A configured forecast provider and location flow.", status: "Available", page: .tools),
        .init(name: "Obsidian", icon: "diamond", description: "Browse and edit vault notes with save-conflict detection.", status: "Available", page: .tools),
        .init(name: "PDF & video compression", icon: "arrow.down.right.and.arrow.up.left", description: "Video export presets and adjustable PDF compression.", status: "Available", page: .tools),
        .init(name: "Cursor ring", icon: "circle.hexagongrid", description: "Customizable radial shortcuts around the pointer.", status: "Available", page: .tools),
        .init(name: "Key sounds", icon: "keyboard", description: "Optional mechanical feedback while you type.", status: "Available", page: .tools)
    ]
}

struct ExtensionsView: View {
    enum Scope: String, CaseIterable, Identifiable { case all = "All", available = "Available", planned = "Planned"; var id: String { rawValue } }
    @State private var search = ""
    @State private var scope = Scope.all
    private var items: [ExtensionItem] {
        ExtensionItem.all.filter { item in
            let matchesScope = scope == .all || (scope == .available) == (item.page != nil)
            return matchesScope && (search.isEmpty || (item.name + " " + item.description).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                WorkspaceSearchField(text: $search, prompt: "Search features")
                Spacer(minLength: 0)
                ChipPicker(options: Scope.allCases.map { ($0, $0.rawValue) }, selection: $scope)
                Button {
                    CommandPaletteStore.shared.message = nil
                    CommandPaletteStore.shared.showingExtensionBuilder = true
                    AppState.shared.toolGroup = ToolGroup.commands.rawValue
                    AppState.shared.toolDetail = "Command palette"
                    AppState.shared.page = .tools
                } label: {
                    Label("Add Extension", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            }
            .padding(.horizontal, 20).padding(.bottom, 4)
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView.search(text: search).padding(.top, 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(items) { item in card(item) }
                }.padding(20)
            }
        }
        }
    }
    @ViewBuilder private func card(_ item: ExtensionItem) -> some View {
        let available = item.page != nil
        let content = HStack(alignment: .top, spacing: 12) {
            SymbolTile(systemImage: item.icon, color: available ? .accentColor : .gray, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 6)
                    if !available {
                        Text("Planned").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(.fill.tertiary, in: Capsule())
                    } else {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                Text(item.description).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        if let page = item.page {
            Button { AppState.shared.toolDetail = item.name; AppState.shared.toolGroup = item.toolGroup; AppState.shared.page = page } label: { content }
                .buttonStyle(.plain).help("Open \(item.name)")
        } else {
            content.opacity(0.75).help("Not implemented in this build")
        }
    }
}
