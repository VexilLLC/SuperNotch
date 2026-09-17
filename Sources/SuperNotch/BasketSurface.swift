import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The compact floating presentation of the shared file shelf.
///
/// The panel that hosts this view owns the window chrome and sizing. This view
/// only renders the basket and delegates all file lifetime and persistence
/// decisions to `FileShelfStore.shared`.
@MainActor
struct BasketSurfaceView: View {
    @ObservedObject private var store: FileShelfStore
    @ObservedObject private var preferences = Preferences.shared
    private let onClose: () -> Void

    @State private var isDropTargeted = false
    @State private var selectedID: UUID?
    @State private var shareMessage: String?

    init(onClose: @escaping () -> Void) {
        self.store = .shared
        self.onClose = onClose
    }

    init(store: FileShelfStore, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
    }

    private var accent: Color { preferences.accent }
    private var items: [ShelfItem] { store.sortedItems }
    private var unpinnedCount: Int { store.activeItems.reduce(into: 0) { if !$1.pinned { $0 += 1 } } }

    var body: some View {
        VStack(spacing: 0) {
            header

            if items.isEmpty {
                emptyDropZone
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxHeight: .infinity)
            } else {
                itemGrid
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxHeight: .infinity)
            }

            footer
        }
        .frame(width: 360, height: 300)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.8)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .onChange(of: store.activeBasketID) { _, _ in selectedID = nil; shareMessage = nil }
        .onChange(of: items.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
            }
        }
        .onChange(of: store.message) { _, message in
            if message != nil {
                shareMessage = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File basket")
    }

    private var panelBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.105, green: 0.115, blue: 0.145),
                Color(red: 0.055, green: 0.060, blue: 0.078)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                BasketSwitcher(store: store, compact: true)
                Text(items.isEmpty ? "Drop files to keep them close" : "Drag a file out to any app")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }

            Text("\(items.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.10), in: Capsule())
                .accessibilityLabel("\(items.count) items")

            Spacer(minLength: 6)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.68))
            .background(Color.white.opacity(0.07), in: Circle())
            .contentShape(Circle())
            .help("Close basket")
            .accessibilityLabel("Close basket")
        }
        .padding(.horizontal, 15)
        .frame(height: 48)
        // The host panel also sets `isMovableByWindowBackground`; this small
        // representable makes the header draggable for borderless hosts too.
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.075))
                .frame(height: 0.7)
                .padding(.horizontal, 14)
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: isDropTargeted ? "basket.fill" : "arrow.down.doc")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(isDropTargeted ? accent : .white.opacity(0.42))
                .symbolEffect(.bounce, value: isDropTargeted)
                .accessibilityHidden(true)

            Text(isDropTargeted ? "Drop files here" : "Your basket is empty")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))

            Text("Drag files or folders from Finder, or add them below.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.48))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Button("Add files…") {
                store.chooseFiles()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(accent)
            .accessibilityLabel("Add files to basket")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDropTargeted ? accent.opacity(0.12) : Color.white.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? accent.opacity(0.72) : Color.white.opacity(0.10),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 1.4 : 0.8, dash: [5, 4])
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isDropTargeted ? "Drop files here" : "Empty file basket")
    }

    private var itemGrid: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 78, maximum: 106), spacing: 8)],
                spacing: 8
            ) {
                ForEach(items) { item in
                    basketItem(item)
                }
            }
            .padding(2)
        }
        .scrollContentBackground(.hidden)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isDropTargeted ? accent.opacity(0.72) : Color.clear, lineWidth: 1.2)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDropTargeted ? accent.opacity(0.08) : Color.clear)
        )
        .accessibilityLabel("Basket files")
    }

    private func basketItem(_ item: ShelfItem) -> some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                FileThumbnailView(url: item.url, size: 38).accessibilityHidden(true)

                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(accent)
                        .padding(3)
                        .background(Color.black.opacity(0.78), in: Circle())
                        .offset(x: 5, y: -4)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 47, height: 42)

            Text(item.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .top)
        }
        .frame(maxWidth: .infinity, minHeight: 78, maxHeight: 82)
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selectedID == item.id ? accent.opacity(0.22) : Color.white.opacity(0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    selectedID == item.id ? accent.opacity(0.7) : Color.white.opacity(0.06),
                    lineWidth: selectedID == item.id ? 1 : 0.7
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onTapGesture(count: 2) { store.open(item) }
        .onTapGesture { selectedID = item.id }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("Open") {
                store.open(item)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button(item.pinned ? "Unpin" : "Pin to basket") {
                store.togglePin(item)
            }
            ShelfMoveMenu(store: store, item: item)
            Button("Remove from basket") {
                store.remove(item)
            }
        }
        .help(item.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.pinned ? "\(item.name), pinned" : item.name)
        .accessibilityHint("Double-click to open. Drag to another app for the file.")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                store.chooseFiles()
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(BasketFooterButtonStyle(accent: accent, prominent: true))
            .help("Add files or folders to basket")
            .accessibilityLabel("Add files to basket")

            Button {
                store.clearUnpinned()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(BasketFooterButtonStyle(accent: accent, prominent: false))
            .disabled(unpinnedCount == 0)
            .help("Remove unpinned files from basket")
            .accessibilityLabel("Clear unpinned files")

            Spacer(minLength: 2)

            Menu {
                Button("AirDrop") { share(using: .sendViaAirDrop) }
                Button("Mail") { share(using: .composeEmail) }
                Button("Messages") { share(using: .composeMessage) }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.white.opacity(0.70))
            .disabled(items.isEmpty)
            .help("Share basket files")
            .accessibilityLabel("Share basket files")
        }
        .padding(.horizontal, 13)
        .frame(height: 45)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.075))
                .frame(height: 0.7)
                .padding(.horizontal, 14)
        }
        .overlay(alignment: .bottomLeading) {
            if let shareMessage {
                Text(shareMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.95))
                    .lineLimit(1)
                    .padding(.leading, 13)
                    .offset(y: -46)
                    .accessibilityLabel(shareMessage)
            }
        }
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

    private func share(using serviceName: NSSharingService.Name) {
        let urls = items
            .map(\.url)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            shareMessage = "No available files to share."
            return
        }
        guard let service = NSSharingService(named: serviceName) else {
            shareMessage = "This sharing service is unavailable."
            return
        }
        let payload: [Any] = urls.map { $0 as NSURL }
        guard service.canPerform(withItems: payload) else {
            shareMessage = "These files cannot be shared right now."
            return
        }
        shareMessage = nil
        service.perform(withItems: payload)
    }
}

private struct BasketFooterButtonStyle: ButtonStyle {
    let accent: Color
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(prominent ? .white.opacity(0.92) : .white.opacity(0.68))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                prominent ? accent.opacity(configuration.isPressed ? 0.42 : 0.28) : Color.white.opacity(configuration.isPressed ? 0.12 : 0.07),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// A transparent AppKit view lets a borderless panel begin a window drag from
/// the header while SwiftUI controls layered above it remain clickable.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
