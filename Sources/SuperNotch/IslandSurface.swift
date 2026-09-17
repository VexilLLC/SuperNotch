import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Island sizes derived from the display's real notch, so the collapsed shape covers it exactly.
@MainActor struct IslandGeometry: Equatable {
    /// Hardware notch size, or a menu-bar-height tab on displays without one.
    let notch: CGSize
    let hasNotch: Bool
    let floating: Bool

    static let ear: CGFloat = 38
    static let shadowMargin: CGFloat = 36
    static let pillsGap: CGFloat = 10
    static let pillsHeight: CGFloat = 44
    static let pillsWidth: CGFloat = 250

    init(screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: (screen.frame.width - left.width - right.width).rounded(), height: top)
            hasNotch = true
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notch = CGSize(width: 190, height: min(32, max(24, menuBar)))
            hasNotch = false
        }
        floating = Preferences.shared.island
    }

    var topGap: CGFloat { floating ? notch.height + 8 : 0 }
    var headerHeight: CGFloat { floating ? 34 : notch.height }

    static var hasLiveContent: Bool { (MediaController.shared.enabled && MediaController.shared.playing) || ProductivityStore.shared.running || AIUsageStore.shared.pinnedMetric != nil }

    /// Compact content area below the notch for each island page: Home (player), Tray, Widgets.
    static func contentSize(tab: Int) -> CGSize {
        switch tab {
        case 1: return CGSize(width: 520, height: 226)
        case 2: return CGSize(width: 480, height: 238)
        default: return CGSize(width: 372, height: 150)
        }
    }
    static let largestContent = CGSize(width: 520, height: 238)

    /// Body size of the island, excluding the concave shoulders drawn outside it.
    func shapeSize(expanded: Bool, tab: Int, hovering: Bool, activity: Bool, live: Bool) -> CGSize {
        if expanded {
            let content = Self.contentSize(tab: tab)
            return CGSize(width: max(content.width, notch.width + 120), height: headerHeight + content.height)
        }
        var width = floating ? max(200, notch.width) : notch.width
        var height = headerHeight
        if live { width += Self.ear * 2 }
        if activity { width = max(width, 420); height += 56 }
        if hovering { width += 22; height += 6 }
        return CGSize(width: width, height: height)
    }

    /// Fixed panel size large enough for every state, the navigation pills and the shadow.
    var canvasSize: CGSize {
        CGSize(width: Self.largestContent.width + 2 * (IslandRadii.expanded.top + Self.shadowMargin),
               height: topGap + headerHeight + Self.largestContent.height + Self.pillsGap + Self.pillsHeight + Self.shadowMargin)
    }
}

struct IslandRadii: Equatable {
    var top: CGFloat
    var bottom: CGFloat
    static let collapsed = IslandRadii(top: 6, bottom: 10)
    static let hovering = IslandRadii(top: 8, bottom: 13)
    static let activity = IslandRadii(top: 10, bottom: 18)
    static let expanded = IslandRadii(top: 12, bottom: 24)
}

enum IslandMotion {
    private static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var open: Animation { reduced ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.76) }
    static var close: Animation { reduced ? .easeIn(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.9) }
    static var hover: Animation { reduced ? .easeInOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.68) }
}

/// A notch outline: concave shoulders flare into the menu bar, rounded corners at the bottom.
/// `rect` includes the shoulders, so the body is `rect.width - 2 * topRadius` wide.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, t = topRadius
        let b = max(0, min(bottomRadius, h - t, (w - 2 * t) / 2))
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addQuadCurve(to: CGPoint(x: w - t, y: t), control: CGPoint(x: w - t, y: 0))
        p.addLine(to: CGPoint(x: w - t, y: h - b))
        p.addQuadCurve(to: CGPoint(x: w - t - b, y: h), control: CGPoint(x: w - t, y: h))
        p.addLine(to: CGPoint(x: t + b, y: h))
        p.addQuadCurve(to: CGPoint(x: t, y: h - b), control: CGPoint(x: t, y: h))
        p.addLine(to: CGPoint(x: t, y: t))
        p.addQuadCurve(to: .zero, control: CGPoint(x: t, y: 0))
        p.closeSubpath()
        return p
    }
}

/// Content appears from a soft blur and settles into place.
private struct BlurScaleModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.blur(radius: active ? 8 : 0).scaleEffect(active ? 0.9 : 1, anchor: .top).opacity(active ? 0 : 1)
    }
}
extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurScaleModifier(active: true), identity: BlurScaleModifier(active: false)).animation(IslandMotion.open.delay(0.06)),
            removal: .modifier(active: BlurScaleModifier(active: true), identity: BlurScaleModifier(active: false)).animation(.easeIn(duration: 0.12))
        )
    }
}

struct IslandView: View {
    let geometry: IslandGeometry
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var widgetPreferences = WidgetPreferences.shared
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var activity = IslandActivityController.shared
    @ObservedObject private var focus = ProductivityStore.shared
    @ObservedObject private var shelf = FileShelfStore.shared
    @ObservedObject private var usage = AIUsageStore.shared

    private var usagePinned: Bool { !musicPlaying && !focus.running && usage.pinnedMetric != nil }
    private var live: Bool { musicPlaying || focus.running || usagePinned }
    private var musicPlaying: Bool { media.enabled && media.playing }
    private var hovering: Bool { state.hovering && !state.expanded }
    private var size: CGSize { geometry.shapeSize(expanded: state.expanded, tab: state.islandTab, hovering: hovering, activity: showsActivity, live: live) }
    private var showsActivity: Bool { !state.expanded && activity.current != nil }
    private var radii: IslandRadii { state.expanded ? .expanded : showsActivity ? .activity : hovering ? .hovering : .collapsed }
    private var shoulder: CGFloat { geometry.floating ? 0 : radii.top }
    private var shape: AnyShape {
        geometry.floating
            ? AnyShape(RoundedRectangle(cornerRadius: state.expanded ? 24 : min(size.height / 2, 20), style: .continuous))
            : AnyShape(NotchShape(topRadius: radii.top, bottomRadius: radii.bottom))
    }

    var body: some View {
        VStack(spacing: IslandGeometry.pillsGap) {
            island
            if state.expanded {
                IslandNavigationPills(shelfCount: shelf.activeItems.count)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .top).combined(with: .opacity).animation(IslandMotion.open.delay(0.07)),
                        removal: .scale(scale: 0.8, anchor: .top).combined(with: .opacity).animation(.easeIn(duration: 0.1))
                    ))
            }
        }
        .padding(.top, geometry.topGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(IslandMotion.hover, value: live)
        .animation(IslandMotion.open, value: activity.current)
        .animation(IslandMotion.open, value: state.islandTab)
        .tint(preferences.accent)
    }

    private var island: some View {
        VStack(spacing: 0) {
            if state.expanded {
                Color.clear.frame(height: geometry.headerHeight)
                expandedContent.transition(.islandContent)
            } else {
                collapsedHeader
                if showsActivity, let current = activity.current {
                    IslandActivityStrip(activity: current).padding(.horizontal, 22).frame(height: 56)
                        .transition(.islandContent)
                }
            }
        }
        .padding(.horizontal, shoulder)
        .frame(width: size.width + 2 * shoulder, height: size.height, alignment: .top)
        .background(.black)
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(preferences.outline && (state.expanded || geometry.floating) ? 0.08 : 0), lineWidth: 0.7))
        .shadow(color: .black.opacity(state.expanded ? 0.45 : hovering ? 0.25 : 0), radius: state.expanded ? 18 : 8, y: state.expanded ? 8 : 3)
        .contentShape(shape)
        .onTapGesture {
            if !state.expanded {
                if usagePinned {
                    state.islandTab = 2
                    state.islandWidget = IslandWidgetID.usage.rawValue
                }
                AppDelegate.shared?.setExpanded(true)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            AppDelegate.shared?.setExpanded(true); state.islandTab = 1
            let destination = FileShelfStore.shared.activeBasketID
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url { Task { @MainActor in FileShelfStore.shared.add(urls: [url], to: destination) } }
                }
            }
            return !providers.isEmpty
        }
        .onExitCommand { AppDelegate.shared?.setExpanded(false) }
        .contextMenu { Button("Settings…") { AppDelegate.shared?.openSettings() }; Button("Open SuperNotch") { AppDelegate.shared?.openWorkspace() }; Button("Close Island") { AppDelegate.shared?.setExpanded(false) } }
    }

    /// Ears either side of the notch while something is live.
    private var collapsedHeader: some View {
        HStack(spacing: 0) {
            if live {
                Group {
                    if musicPlaying { MediaArtworkView(size: 20, cornerRadius: 5) }
                    else if focus.running { Image(systemName: "timer").foregroundStyle(.orange) }
                    else if let (provider, _) = usage.pinnedMetric { AIProviderBrandView(provider: provider, size: 17).foregroundStyle(preferences.accent) }
                }.frame(width: IslandGeometry.ear, alignment: .center)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if !geometry.hasNotch || geometry.floating, !live {
                Image(systemName: "sparkle").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            if live {
                Group {
                    if musicPlaying { LevelBars(playing: true, color: preferences.accent) }
                    else if focus.running { Text(focus.focusRemainingText).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.orange).lineLimit(1).minimumScaleFactor(0.7).accessibilityLabel("Focus, \(focus.focusRemainingText) remaining") }
                    else if let headline = usage.pinnedHeadline { Text(headline).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(preferences.accent).lineLimit(1).minimumScaleFactor(0.7).accessibilityLabel("Pinned AI usage, \(headline)") }
                }.frame(width: IslandGeometry.ear, alignment: .center)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(.horizontal, hovering ? 11 : 0)
        .frame(height: geometry.headerHeight + (hovering ? 6 : 0))
    }

    private var expandedContent: some View {
        Group {
            switch state.islandTab {
            case 1: CompactShelfView().padding(.horizontal, 2)
            case 2: compactWidgets.padding(.horizontal, 18).padding(.bottom, 14)
            default:
                if preferences.homeLayout == .focus || (preferences.homeLayout == .focusMusic && focus.running && !musicPlaying) {
                    IslandFocusCompact().padding(.horizontal, 20).padding(.bottom, 16)
                } else {
                    IslandPlayerView().padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .id(state.islandTab)
        .transition(.opacity)
    }

    private var compactWidgets: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(widgetPreferences.visibleWidgets) { widget in
                            Button { state.islandWidget = widget.rawValue } label: {
                                Label(widget.title, systemImage: widget.symbol).font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .foregroundStyle(state.islandWidget == widget.rawValue ? .white : .white.opacity(0.45))
                                    .background(state.islandWidget == widget.rawValue ? Color.white.opacity(0.08) : .clear, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.never)
                Spacer()
                Button { AppDelegate.shared?.openSettings() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Customize widgets")
                    .accessibilityLabel("Customize widgets")
            }
            Group {
                switch state.islandWidget {
                case 3: SystemPerformanceView(chrome: false)
                case 4: AIUsageWidgetView()
                case 1: CompactAgendaView()
                case 2:
                    HStack(spacing: 12) {
                        IslandFocusCard()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Set your rhythm").font(.system(size: 12, weight: .semibold))
                            HStack(spacing: 8) {
                                ForEach([5, 15, 25, 50], id: \.self) { minutes in
                                    Button("\(minutes)m") { focus.resetTimer(minutes: Double(minutes)) }
                                        .font(.system(size: 10)).buttonStyle(.bordered)
                                }
                            }
                            Button("Reset timer", systemImage: "arrow.counterclockwise") { focus.resetTimer() }.buttonStyle(.plain).font(.system(size: 11))
                            Spacer(minLength: 0)
                            Button(focus.awake ? "Stop Keep Awake" : "Keep Awake", systemImage: "cup.and.saucer") { focus.toggleAwake() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(focus.awake ? .orange : .secondary)
                        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
                    }
                default: CompactNotesView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(.vertical, 4)
            .onAppear {
                selectAvailableWidget()
                focus.refreshAuthorizationAndContent()
            }
            .onChange(of: widgetPreferences.visibleWidgets) { _, _ in selectAvailableWidget() }
    }
    private func selectAvailableWidget() {
        if !widgetPreferences.visibleWidgets.contains(where: { $0.rawValue == state.islandWidget }),
           let first = widgetPreferences.visibleWidgets.first {
            state.islandWidget = first.rawValue
        }
    }
}

/// The compact player inside the open island.
private struct IslandPlayerView: View {
    @ObservedObject private var media = MediaController.shared
    @ObservedObject private var clock = MediaProgress.shared
    @ObservedObject private var preferences = Preferences.shared
    @ObservedObject private var focus = ProductivityStore.shared
    @State private var showOutputs = false
    @State private var hoveringTrack = false
    @State private var trackPressed = false
    private var active: Bool { media.enabled && media.duration > 1 && media.title != "Nothing playing" }
    private var playerName: String {
        if media.source == "Spotify" { return "Spotify" }
        return media.appName ?? "the player"
    }

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    MediaArtworkView(size: 58, cornerRadius: 12, showsAppBadge: true)
                        .scaleEffect(media.playing ? 1 : 0.94)
                        .animation(IslandMotion.open, value: media.playing)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.enabled ? media.title : "Nothing playing")
                            .font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        ZStack(alignment: .leading) {
                            Text(media.enabled ? media.artist : "Play something in any app")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
                                .opacity(hoveringTrack ? 0 : 1)
                            // Hint that the track opens the player, shown on hover.
                            Label("Double-click to open \(playerName)", systemImage: "arrow.up.forward.app")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(preferences.accent).lineLimit(1)
                                .opacity(hoveringTrack ? 1 : 0)
                                .offset(y: hoveringTrack ? 0 : 3)
                        }
                    }
                    Spacer(minLength: 6)
                }
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(trackPressed ? preferences.accent.opacity(0.22) : .white.opacity(hoveringTrack ? 0.07 : 0))
                }
                .padding(-6)
                .scaleEffect(trackPressed ? 0.97 : 1)
                .contentShape(Rectangle())
                .onHover { inside in
                    withAnimation(.easeOut(duration: 0.18)) { hoveringTrack = inside }
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onDisappear { if hoveringTrack { NSCursor.pop(); hoveringTrack = false } }
                // Double-click the track to show the app that is playing it.
                .onTapGesture(count: 2) { openPlayerFromTrack() }
                .help("Double-click to open \(playerName)")
                .accessibilityAction(named: "Show player") { NowPlayingAppOpener.openCurrentPlayer(showOnly: true) }
                if focus.running {
                    Label(focus.focusRemainingText, systemImage: "timer").labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.orange).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .onTapGesture { AppState.shared.islandTab = 2; AppState.shared.islandWidget = 2 }
                } else {
                    LevelBars(playing: media.playing, color: preferences.accent, count: 5, maxHeight: 16)
                        .frame(width: 26)
                }
            }

            HStack(spacing: 10) {
                Text(Self.time(media.progress)).frame(width: 36, alignment: .leading)
                IslandScrubber(progress: active ? min(media.progress, media.duration) / media.duration : 0) { fraction in
                    media.seek(fraction * media.duration)
                }.disabled(!active)
                Text("-" + Self.time(max(0, media.duration - media.progress))).frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            .foregroundStyle(.white.opacity(0.45))
            .opacity(active ? 1 : 0.4)

            HStack {
                IslandControl(systemImage: "arrow.up.forward.app", size: 15, help: media.appBundleIdentifier == SpotifyDockManager.bundleIdentifier ? "Toggle Spotify" : (media.appName.map { "Show \($0)" } ?? "Open player")) { openSourceApp() }
                Spacer()
                IslandControl(systemImage: "backward.fill", size: 20, help: "Previous") { media.command("previous track") }
                Spacer()
                IslandControl(systemImage: media.playing ? "pause.fill" : "play.fill", size: 27, help: media.playing ? "Pause" : "Play") { media.command("playpause") }
                    .contentTransition(.symbolEffect(.replace))
                Spacer()
                IslandControl(systemImage: "forward.fill", size: 20, help: "Next") { media.command("next track") }
                Spacer()
                IslandControl(systemImage: "laptopcomputer", size: 16, help: "Audio output") { showOutputs.toggle() }
                    .popover(isPresented: $showOutputs, arrowEdge: .bottom) { AudioDevicesView().frame(width: 360).preferredColorScheme(.dark) }
            }
            .padding(.horizontal, 4)
        }
    }

    /// Press feedback, then open: the flash confirms the double-click landed.
    private func openPlayerFromTrack() {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { trackPressed = true }
        NowPlayingAppOpener.openCurrentPlayer(showOnly: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { trackPressed = false }
        }
    }

    private func openSourceApp() {
        NowPlayingAppOpener.openCurrentPlayer()
    }

    static func time(_ value: Double) -> String { String(format: "%d:%02d", Int(value) / 60, Int(value) % 60) }
}

/// A white capsule progress bar that thickens while hovered and seeks on click or drag.
private struct IslandScrubber: View {
    let progress: Double
    let onSeek: (Double) -> Void
    @State private var hovering = false
    @State private var dragFraction: Double?
    var body: some View {
        GeometryReader { proxy in
            let fraction = dragFraction ?? progress
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white).frame(width: max(0, proxy.size.width * fraction))
            }
            .frame(height: hovering || dragFraction != nil ? 8 : 6)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragFraction = min(max(0, value.location.x / max(1, proxy.size.width)), 1) }
                .onEnded { _ in if let dragFraction { onSeek(dragFraction) }; dragFraction = nil })
        }
        .frame(height: 14)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
    }
}

/// A borderless white glyph button that springs when pressed.
private struct IslandControl: View {
    let systemImage: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: size, weight: .semibold))
                .frame(width: max(30, size + 12), height: 32).contentShape(Rectangle())
        }
        .buttonStyle(IslandPressStyle())
        .foregroundStyle(.white)
        .help(help).accessibilityLabel(help)
    }
}

struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Floating page navigation below the open island.
private struct IslandNavigationPills: View {
    let shelfCount: Int
    @ObservedObject private var state = AppState.shared
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                tab(0, "house.fill", "Home")
                tab(1, "tray.fill", "Tray", count: shelfCount)
                tab(2, "square.grid.2x2.fill", "Widgets")
            }
            .padding(4)
            .background(.black, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.7))

            Button { AppDelegate.shared?.openClipboard() } label: {
                Image(systemName: "list.clipboard.fill").font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
                    .background(.black, in: Circle()).overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.7))
            }
            .buttonStyle(IslandPressStyle()).help("Clipboard history")

            Button { IslandMoreMenu.shared.show() } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .bold)).frame(width: 44, height: 44)
                    .background(.black, in: Circle()).overlay(Circle().stroke(.white.opacity(0.08), lineWidth: 0.7))
            }
            .buttonStyle(IslandPressStyle()).help("More")
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .frame(height: IslandGeometry.pillsHeight)
    }

    private func tab(_ index: Int, _ symbol: String, _ title: String, count: Int? = nil) -> some View {
        let selected = state.islandTab == index
        return Button { withAnimation(IslandMotion.open) { state.islandTab = index } } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                if let count, count > 0 { Text("\(count)").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit() }
            }
            .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
            .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 36)
            .background {
                if selected { Capsule().fill(.white.opacity(0.16)).matchedGeometryEffect(id: "islandTab", in: namespace) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(IslandPressStyle())
        .help("\(title) (⌘\(index + 1))").accessibilityLabel(title)
    }
    @Namespace private var namespace
}

/// Home page variant for the Focus arrangement.
private struct IslandFocusCompact: View {
    @ObservedObject private var focus = ProductivityStore.shared
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 6)
                Circle().trim(from: 0, to: max(0.001, 1 - focus.remaining / max(1, focus.selectedMinutes * 60)))
                    .stroke(Color.orange.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "timer").font(.system(size: 20, weight: .semibold)).foregroundStyle(.orange)
            }.frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 8) {
                Text(focus.focusRemainingText).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white).contentTransition(.numericText())
                HStack(spacing: 6) {
                    ForEach([15, 25, 50], id: \.self) { minutes in
                        Button("\(minutes)m") { focus.resetTimer(minutes: Double(minutes)) }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(.white.opacity(focus.selectedMinutes == Double(minutes) ? 0.18 : 0.07), in: Capsule())
                            .buttonStyle(IslandPressStyle()).foregroundStyle(.white)
                    }
                }
            }
            Spacer(minLength: 0)
            IslandControl(systemImage: focus.running ? "pause.fill" : "play.fill", size: 26, help: focus.running ? "Pause focus" : "Start focus") { focus.toggleTimer() }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct IslandFocusCard: View {
    @ObservedObject var focus = ProductivityStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: "timer").foregroundStyle(.orange); Text("Focus").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary); Spacer() }
            Text(focus.focusRemainingText).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit()
            Button { focus.toggleTimer() } label: { Label(focus.running ? "Pause" : "Start focus", systemImage: focus.running ? "pause.fill" : "play.fill").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange) }.buttonStyle(.plain)
        }.padding(19).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).background(.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 20))
    }
}

/// AppKit menu for the island's "More" button; SwiftUI menus cannot be styled as plain glyphs here.
@MainActor final class IslandMoreMenu: NSObject {
    static let shared = IslandMoreMenu()
    func show() {
        let menu = NSMenu()
        for (title, action) in [("Open SuperNotch", #selector(openWorkspace)), ("Settings…", #selector(openSettings))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Island", action: #selector(close), keyEquivalent: ""); close.target = self; menu.addItem(close)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    @objc private func openWorkspace() { AppDelegate.shared?.openWorkspace() }
    @objc private func openSettings() { AppDelegate.shared?.openSettings() }
    @objc private func close() { AppDelegate.shared?.setExpanded(false) }
}
