import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Quartz

/// A small shelf presentation for the expanded island.
///
/// The workspace has a fuller `FileShelfView`; this view keeps the same store and
/// actions while giving the island a single, horizontal strip of real files.
struct CompactShelfView: View {
    @ObservedObject private var store: FileShelfStore
    @State private var selectedID: UUID?
    @FocusState private var shelfFocused: Bool
    @State private var isDropTargeted = false
    @State private var shareError: String?

    init(store: FileShelfStore) {
        self.store = store
    }

    init() {
        self.store = .shared
    }

    private var items: [ShelfItem] {
        // Shelf references survive between launches. Keep stale references out of
        // the compact island while leaving removal to the user's explicit action.
        store.sortedItems.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var selectedItem: ShelfItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    private var accent: Color {
        Color(red: 0.27, green: 0.54, blue: 0.98)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if items.isEmpty {
                emptyState
            } else {
                itemStrip
            }

            quickActions

            if let shareError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(shareError).lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        self.shareError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss AirDrop message")
                }
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.95))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, minHeight: 214, maxHeight: 248, alignment: .top)
        .background(isDropTargeted ? accent.opacity(0.045) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isDropTargeted ? accent.opacity(0.75) : Color.clear, lineWidth: isDropTargeted ? 1.4 : 0.7)
        }
        .focusable()
        .focused($shelfFocused)
        .onKeyPress(phases: .down, action: handlePreviewKeyPress)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .onChange(of: store.activeBasketID) { _, _ in selectedID = nil; shareError = nil }
        .onChange(of: items.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
            }
        }
    }

    private func handlePreviewKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.key == .space,
              press.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              let item = selectedItem else { return .ignored }
        CompactShelfQuickLook.shared.show(item.url)
        return .handled
    }

    private var header: some View {
        HStack(spacing: 8) {
            BasketSwitcher(store: store, compact: true)

            Text("\(items.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(selectedItem == nil ? "Drag out to any app" : "Space to preview")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.white.opacity(0.9))
    }

    private var itemStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(items) { item in
                    shelfItem(item)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .frame(height: 116)
        .scrollClipDisabledIfAvailable()
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "tray")
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(isDropTargeted ? accent : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(isDropTargeted ? "Drop files here" : "This basket is empty")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add files or drag them in from Finder.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Button("Add files…") {
                store.chooseFiles()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(accent)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isDropTargeted ? accent.opacity(0.6) : Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }

    private var quickActions: some View {
        HStack(spacing: 7) {
            Button {
                store.chooseFiles()
            } label: {
                Label("Add files", systemImage: "plus")
            }
            .compactActionStyle()
            .help("Add files or folders to the shelf")

            Button {
                BasketController.shared.show()
            } label: {
                Label("Basket", systemImage: "basket")
            }
            .compactActionStyle()
            .help("Open the floating basket")

            Menu {
                Button("Selected item") {
                    share([selectedItem].compactMap { $0 })
                }
                .disabled(selectedItem == nil)

                Button("All basket items") {
                    share(items)
                }
                .disabled(items.isEmpty)
            } label: {
                Label("AirDrop", systemImage: "airplayaudio")
            }
            .menuStyle(.borderlessButton)
            .compactActionStyle()
            .help("Send the selected item or all items in this basket with AirDrop")
        }
    }

    private func shelfItem(_ item: ShelfItem) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                FileThumbnailView(url: item.url, size: 58)

                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(accent)
                        .padding(3)
                        .background(Color.black.opacity(0.82), in: Circle())
                        .offset(x: 4, y: -3)
                }
            }
            .frame(width: 66, height: 62)

            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 88, height: 26, alignment: .top)
        }
        .frame(width: 92, height: 104)
        .padding(.vertical, 5)
        .background(selectedID == item.id ? accent.opacity(0.2) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(selectedID == item.id ? accent.opacity(0.68) : Color.white.opacity(0.05), lineWidth: selectedID == item.id ? 1 : 0.6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture(count: 2) {
            store.open(item)
        }
        .onTapGesture {
            selectedID = item.id
            NSApp.activate(ignoringOtherApps: true)
            if let panels = AppDelegate.shared?.panels {
                (panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first)?.makeKeyAndOrderFront(nil)
            }
            shelfFocused = true
        }
        .onDrag {
            NSItemProvider(object: item.url as NSURL)
        }
        .contextMenu {
            Button("Open") {
                store.open(item)
            }
            Button("Preview") {
                CompactShelfQuickLook.shared.show(item.url)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button(item.pinned ? "Unpin" : "Pin to shelf") {
                store.togglePin(item)
            }
            ShelfMoveMenu(store: store, item: item)
            Button("Remove from shelf") {
                store.remove(item)
            }
        }
        .help(item.path)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let destination = store.activeBasketID
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                let url: URL?
                if let data = value as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = value as? URL {
                    url = direct
                } else if let string = value as? String {
                    url = URL(string: string)
                } else {
                    url = nil
                }
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    store.add(urls: [url], to: destination)
                }
            }
        }
        return true
    }

    private func share(_ items: [ShelfItem]) {
        let urls = items
            .map(\.url)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            shareError = "There are no available files to send."
            return
        }

        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            shareError = "AirDrop is unavailable on this Mac."
            return
        }

        let payload: [Any] = urls.map { $0 as NSURL }
        guard service.canPerform(withItems: payload) else {
            shareError = "AirDrop cannot send these files right now."
            return
        }

        shareError = nil
        service.perform(withItems: payload)
    }
}

private extension View {
    @ViewBuilder
    func compactActionStyle() -> some View {
        self
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    func scrollClipDisabledIfAvailable() -> some View {
        // Kept as a small local helper so the compact strip remains compatible
        // with the minimum macOS version used by the project.
        self
    }
}

@MainActor
private final class CompactShelfQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = CompactShelfQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url as NSURL?
    }
}
