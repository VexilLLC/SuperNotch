import AppKit
import SwiftUI

/// A compact, horizontal clipboard surface for the floating bottom strip.
///
/// The strip deliberately keeps paste as an explicit action. Selecting a card
/// only changes the keyboard target; it never sends input to another app.
@MainActor
struct ClipboardStripView: View {
    @ObservedObject private var store: ClipboardStore
    private let onClose: () -> Void
    private let onOpenLibrary: () -> Void

    @State private var search = ""
    @State private var scope: ClipboardStripScope = .clipboard
    @State private var typeFilter: ClipboardStripTypeFilter = .all
    @State private var tagFilter: String?
    @State private var selectedID: UUID?
    @FocusState private var searchFocused: Bool
    @FocusState private var stripFocused: Bool

    init(
        store: ClipboardStore? = nil,
        onClose: @escaping () -> Void,
        onOpenLibrary: @escaping () -> Void
    ) {
        self.store = store ?? .shared
        self.onClose = onClose
        self.onOpenLibrary = onOpenLibrary
    }

    private let accent = Color(red: 0.43, green: 0.54, blue: 1.0)
    private let charcoal = Color(red: 0.075, green: 0.083, blue: 0.105)

    private var visibleItems: [ClipboardEntry] {
        store.items.filter { item in
            let matchesScope = scope == .clipboard || item.isPinned
            let matchesType: Bool
            switch typeFilter {
            case .all:
                matchesType = true
            case .text:
                matchesType = [.text, .link, .richText].contains(item.kind)
            case .images:
                matchesType = item.kind == .image
            case .files:
                matchesType = item.kind == .files
            case .colors:
                matchesType = item.colorValue != nil
            }
            let matchesSearch = item.matchesSearch(search, tag: tagFilter)
            return matchesScope && matchesType && matchesSearch
        }
    }

    private var visibleIDs: [UUID] {
        visibleItems.map(\.id)
    }

    var body: some View {
        let items = visibleItems
        VStack(alignment: .leading, spacing: 10) {
            topBar

            if items.isEmpty {
                emptyState
            } else {
                itemStrip(items)
            }

            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 11)
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 290, maxHeight: 340, alignment: .top)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(charcoal.opacity(0.94))
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.26)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.105), lineWidth: 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .focusable()
        .focused($stripFocused)
        .onKeyPress(phases: .down, action: handleKeyPress)
        .onAppear {
            resetSearchAndFocus()
            store.startMonitoring()
        }
        .onChange(of: items.map(\.id)) { _, ids in
            reconcileSelection(with: ids)
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)

                Text("Clipboard")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Text("\(store.items.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

            scopePicker
            typeFilterMenu
            ClipboardTagFilter(store: store, selection: $tagFilter)

            ClipboardWindowDragHandle()
                .frame(minWidth: 12, maxWidth: .infinity, minHeight: 29, maxHeight: 29)
                .contentShape(Rectangle())
                .help("Drag to move the clipboard window")
                .accessibilityHidden(true)

            searchField

            Button {
                store.isPaused.toggle()
            } label: {
                Image(systemName: store.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(store.isPaused ? .orange : .secondary)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help(store.isPaused ? "Resume clipboard capture" : "Pause clipboard capture")
            .accessibilityLabel(store.isPaused ? "Resume clipboard capture" : "Pause clipboard capture")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("Close clipboard strip")
            .accessibilityLabel("Close clipboard strip")
        }
        .foregroundStyle(.white.opacity(0.92))
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            ForEach(ClipboardStripScope.allCases) { value in
                Button {
                    scope = value
                } label: {
                    Text(value.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(scope == value ? .white : .secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 25)
                        .background(
                            scope == value ? accent.opacity(0.28) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(scope == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard scope")
    }

    private var typeFilterMenu: some View {
        Menu {
            ForEach(ClipboardStripTypeFilter.allCases) { value in
                Button {
                    typeFilter = value
                } label: {
                    if typeFilter == value {
                        Label(value.rawValue, systemImage: "checkmark")
                    } else {
                        Text(value.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: typeFilter.symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(typeFilter.shortName)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 29)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter clipboard types")
        .accessibilityLabel("Clipboard type filter")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($searchFocused)
                .onSubmit {
                    copySelectedItem()
                }
                .onKeyPress(.downArrow) {
                    searchFocused = false
                    stripFocused = true
                    return .handled
                }
                .onKeyPress(.escape) {
                    onClose()
                    return .handled
                }

            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 125, idealWidth: 190, maxWidth: 220, minHeight: 29)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(searchFocused ? accent.opacity(0.6) : Color.white.opacity(0.04), lineWidth: searchFocused ? 1 : 0.6)
        }
        .accessibilityLabel("Search clipboard")
    }

    private func itemStrip(_ items: [ClipboardEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 9) {
                    ForEach(items) { item in
                        ClipboardStripCard(
                            item: item,
                            store: store,
                            isSelected: item.id == selectedID,
                            accent: accent,
                            onSelect: {
                                selectedID = item.id
                                searchFocused = false
                                stripFocused = true
                            }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
            .onChange(of: selectedID) { _, id in
                guard let id, !searchFocused else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 189, maxHeight: 189)
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: store.items.isEmpty && search.isEmpty && scope == .clipboard ? "clipboard" : "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.items.isEmpty && search.isEmpty && scope == .clipboard ? "Your clipboard is empty" : "No matching items")
                    .font(.system(size: 12, weight: .semibold))
                Text(store.items.isEmpty && search.isEmpty && scope == .clipboard ? "Copy text, images or files to see them here." : "Try another search or filter.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 189, maxHeight: 189, alignment: .leading)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onOpenLibrary()
            } label: {
                Label("Open Library", systemImage: "rectangle.stack")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.85))
            .background(Color.white.opacity(0.08), in: Capsule())
            .help("Open full clipboard library")

            if store.isPaused {
                Label("Capture paused", systemImage: "pause.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.9))
            } else if let status = store.status {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 5)

            Text(searchFocused ? "↓ browse cards  ·  Return copy  ·  Esc close" : "← → select  ·  Return copy  ·  Esc close")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(height: 26)
    }

    private func resetSearchAndFocus() {
        search = ""
        stripFocused = false
        reconcileSelection(with: visibleIDs)
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func reconcileSelection(with ids: [UUID]) {
        guard !ids.isEmpty else {
            selectedID = nil
            return
        }
        if let selectedID, ids.contains(selectedID) {
            return
        }
        selectedID = ids[0]
    }

    private func moveSelection(by offset: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        let current = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : items.count)
        let next = min(max(current + offset, 0), items.count - 1)
        selectedID = items[next].id
    }

    private func copySelectedItem() {
        guard let selectedID, let item = visibleItems.first(where: { $0.id == selectedID }) else { return }
        store.copy(item)
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.key == .escape {
            onClose()
            return .handled
        }
        if keyPress.key == .downArrow, searchFocused {
            searchFocused = false
            stripFocused = true
            return .handled
        }
        guard !searchFocused else { return .ignored }
        if keyPress.key == .leftArrow {
            moveSelection(by: -1)
            return .handled
        }
        if keyPress.key == .rightArrow {
            moveSelection(by: 1)
            return .handled
        }
        if keyPress.key == .return {
            copySelectedItem()
            return .handled
        }
        return .ignored
    }
}

/// Gives the borderless clipboard panel a real title-bar-like drag region.
/// Controls layered above this transparent view keep their own click handling.
private struct ClipboardWindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private enum ClipboardStripScope: String, CaseIterable, Identifiable {
    case clipboard = "Clipboard"
    case pinned = "Pinned"

    var id: Self { self }
}

private enum ClipboardStripTypeFilter: String, CaseIterable, Identifiable {
    case all = "All types"
    case text = "Text"
    case images = "Images"
    case files = "Files"
    case colors = "Colors"

    var id: Self { self }

    var shortName: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .images: return "Images"
        case .files: return "Files"
        case .colors: return "Colors"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .text: return "text.alignleft"
        case .images: return "photo"
        case .files: return "doc.on.doc"
        case .colors: return "paintpalette"
        }
    }
}

@MainActor
private struct ClipboardStripCard: View {
    let item: ClipboardEntry
    @ObservedObject var store: ClipboardStore
    let isSelected: Bool
    let accent: Color
    let onSelect: () -> Void
    @State private var tagEditor: ClipboardEntry?

    private var sourceIcon: NSImage? {
        item.sourceBundleIdentifier.flatMap(SmallIconCache.applicationIcon(for:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)

                Text(item.colorValue != nil ? "COLOR" : item.kind == .richText ? "FORMATTED" : item.kind.rawValue.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 3)

                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }

                if let sourceAppName = item.sourceAppName, !sourceAppName.isEmpty {
                    HStack(spacing: 3) {
                        if let sourceIcon {
                            Image(nsImage: sourceIcon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 12, height: 12)
                        }
                        Text(sourceAppName)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .help("Copied from \(sourceAppName)")
                } else {
                    RelativeTimeText(date: item.createdAt)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            preview
                .frame(maxWidth: .infinity, maxHeight: item.tagNames.isEmpty ? 111 : 87, alignment: .topLeading)

            if !item.tagNames.isEmpty { ClipboardTagBadges(tags: item.tagNames) }

            HStack(spacing: 6) {
                Button {
                    store.copy(item)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .stripClipboardAction(tint: .white.opacity(0.82))
                .help("Copy to clipboard")

                Button {
                    store.paste(item)
                } label: {
                    Label("Paste", systemImage: "arrow.down.doc")
                }
                .stripClipboardAction(tint: accent)
                .help("Paste into the previous app")

                Spacer(minLength: 0)

                Button { tagEditor = item } label: {
                    Image(systemName: "tag").frame(width: 22, height: 22)
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Edit tags").accessibilityLabel("Edit tags")
                Button {
                    store.togglePin(item)
                } label: {
                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.isPinned ? .orange : .secondary)
                .background(Color.white.opacity(0.055), in: Circle())
                .help(item.isPinned ? "Unpin" : "Pin")
                .accessibilityLabel(item.isPinned ? "Unpin item" : "Pin item")
            }
        }
        .padding(10)
        .frame(width: 218, height: 181, alignment: .topLeading)
        .background(
            isSelected ? accent.opacity(0.16) : Color.white.opacity(0.048),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? accent.opacity(0.78) : Color.white.opacity(0.075), lineWidth: isSelected ? 1.15 : 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            onSelect()
        }
        .sheet(item: $tagEditor) { entry in ClipboardTagEditor(store: store, entry: entry).preferredColorScheme(.dark) }
        .contextMenu {
            Button("Copy") { store.copy(item) }
            Button("Edit tags…") { tagEditor = item }
            Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item) }
            Button("Delete", role: .destructive) { store.delete(item) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(item.title.isEmpty ? "Clipboard item" : item.title)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .image:
            ClipboardImagePreview(item: item, maxHeight: 105)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .files:
            filePreview
        case .text, .link, .richText:
            if let color = item.colorValue {
                ClipboardColorSwatch(value: color, compact: true)
            } else {
            Text(item.text.isEmpty ? item.title : item.text)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(6)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var filePreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(item.paths.prefix(3)), id: \.self) { path in
                HStack(spacing: 6) {
                    Image(nsImage: SmallIconCache.fileIcon(for: path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)

                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                }
            }

            if item.paths.count > 3 {
                Text("+\(item.paths.count - 3) more files")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else if item.paths.isEmpty {
                unavailablePreview(symbol: "doc.on-doc", title: item.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unavailablePreview(symbol: String, title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// AppKit supplies large multi-representation icons. Flattening them once prevents every card
/// update from retaining and redrawing full application/file icon resources for a 12–22 pt view.
@MainActor
enum SmallIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    static func applicationIcon(for bundleIdentifier: String) -> NSImage? {
        let key = "app:\(bundleIdentifier)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return cachedRaster(NSWorkspace.shared.icon(forFile: url.path), key: key, pixels: 24)
    }

    static func fileIcon(for path: String, pixels: Int = 44) -> NSImage {
        let key = "file:\(pixels):\(path)" as NSString
        if let image = cache.object(forKey: key) { return image }
        return cachedRaster(NSWorkspace.shared.icon(forFile: path), key: key, pixels: pixels)
    }

    private static func cachedRaster(_ source: NSImage, key: NSString, pixels: Int) -> NSImage {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return source }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        source.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.addRepresentation(representation)
        cache.setObject(image, forKey: key, cost: representation.bytesPerRow * pixels)
        return image
    }
}

private extension View {
    func stripClipboardAction(tint: Color) -> some View {
        self
            .font(.system(size: 9, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Color.white.opacity(0.06), in: Capsule())
    }
}
