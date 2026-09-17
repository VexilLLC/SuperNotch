import SwiftUI

/// A compact menu for selecting and managing file shelf baskets.
///
/// Basket lifetime and persistence belong to `FileShelfStore`; this view only
/// presents the available actions. Keeping the menu self-contained lets it be
/// used in both the 360px floating basket and the expanded island tray.
@MainActor
struct BasketSwitcher: View {
    @ObservedObject private var store: FileShelfStore
    private let compact: Bool

    @State private var editor: BasketNameEditorMode?
    @State private var mergeTarget: ShelfBasket?

    init(store: FileShelfStore, compact: Bool = false) {
        self.store = store
        self.compact = compact
    }

    init(compact: Bool = false) {
        self.init(store: .shared, compact: compact)
    }

    var body: some View {
        Menu {
            basketChoices

            Divider()

            Button {
                editor = .new
            } label: {
                Label("New basket", systemImage: "plus")
            }
            .disabled(!store.canCreateBasket)
            .help(store.canCreateBasket ? "Create a new basket" : "You can have up to 12 baskets")

            Button {
                editor = .rename(store.activeBasketID)
            } label: {
                Label("Rename basket…", systemImage: "pencil")
            }
            .disabled(store.baskets.isEmpty)

            Divider()

            Button(role: .destructive) {
                mergeTarget = store.activeBasket
            } label: {
                Label("Merge into \(mainBasketName)", systemImage: "arrow.triangle.merge")
            }
            .disabled(!store.canRemoveBasket)
        } label: {
            switcherLabel
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .sheet(item: $editor) { mode in
            BasketNameEditor(
                mode: mode,
                initialName: store.baskets.first { $0.id == mode.basketID }?.name ?? "",
                onSave: { name in
                    switch mode {
                    case .new:
                        return store.createBasket(name: name)
                    case .rename(let id):
                        return store.renameBasket(id, name: name)
                    }
                }
            )
        }
        .alert(item: $mergeTarget) { target in
            Alert(
                title: Text("Merge into \(mainBasketName)?"),
                message: Text("The items in \(target.name) will move to \(mainBasketName). Original files stay untouched."),
                primaryButton: .destructive(Text("Merge into \(mainBasketName)")) { store.removeBasket(target.id) },
                secondaryButton: .cancel()
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Basket: \(store.activeBasket.name)")
        .accessibilityHint("Choose a basket or manage baskets")
    }

    private var mainBasketName: String {
        store.baskets.first?.name ?? "Main"
    }

    @ViewBuilder
    private var basketChoices: some View {
        ForEach(store.baskets) { basket in
            Button {
                store.selectBasket(basket.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: basket.id == store.activeBasketID ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(basket.id == store.activeBasketID ? Color.accentColor : .secondary)
                    Text(basket.name)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text("\(store.basketItemCount(basket.id))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(basket.name), \(store.basketItemCount(basket.id)) \(store.basketItemCount(basket.id) == 1 ? "item" : "items")\(basket.id == store.activeBasketID ? ", selected" : "")")
            }
        }
    }

    private var switcherLabel: some View {
        HStack(spacing: compact ? 4 : 6) {
            Image(systemName: "tray.2.fill")
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .accessibilityHidden(true)

            Text(store.activeBasket.name)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if !compact {
                Text("\(store.basketItemCount(store.activeBasketID))")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("\(store.basketItemCount(store.activeBasketID)) items")
            }

            Image(systemName: "chevron.down")
                .font(.system(size: compact ? 8 : 9, weight: .bold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 4 : 5)
        .frame(maxWidth: compact ? 132 : 188, alignment: .leading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous))
        .help("Switch basket")
        .accessibilityAddTraits(.isButton)
    }
}

private enum BasketNameEditorMode: Identifiable {
    case new
    case rename(UUID)

    var basketID: UUID? { if case .rename(let id) = self { return id }; return nil }
    var id: String { basketID?.uuidString ?? "new" }
    var title: String { basketID == nil ? "New basket" : "Rename basket" }
    var actionTitle: String { basketID == nil ? "Create" : "Save" }
}

/// The focused, keyboard-friendly editor used by `BasketSwitcher`.
@MainActor
private struct BasketNameEditor: View {
    let mode: BasketNameEditorMode
    let initialName: String
    let onSave: (String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name: String
    @State private var submissionError: String?

    init(mode: BasketNameEditorMode, initialName: String, onSave: @escaping (String) -> Bool) {
        self.mode = mode
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        if trimmedName.isEmpty { return "Enter a basket name." }
        if trimmedName.count > 40 { return "Basket names can be up to 40 characters." }
        return nil
    }

    private var canSubmit: Bool { validationError == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mode.title)
                    .font(.headline)
                Text(mode.basketID == nil ? "Keep related files together in their own basket." : "Give this basket a short, memorable name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Basket name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { submit() }
                    .accessibilityLabel("Basket name")
                    .accessibilityHint("Up to 40 characters")

                HStack(spacing: 6) {
                    if let error = submissionError ?? validationError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                        Text(error)
                    } else {
                        Text(" ")
                    }
                    Spacer(minLength: 4)
                    Text("\(name.count)/40")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel("\(name.count) of 40 characters")
                }
                .font(.caption)
                .foregroundStyle((submissionError ?? validationError) == nil ? Color.secondary : Color.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode.actionTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 330)
        .onAppear {
            nameFocused = true
        }
        .onChange(of: name) { _, _ in
            submissionError = nil
        }
    }

    private func submit() {
        guard let error = validationError else {
            if onSave(trimmedName) {
                dismiss()
            } else {
                submissionError = "That basket name could not be saved."
            }
            return
        }
        submissionError = error
        nameFocused = true
    }
}

/// A context-menu item that moves a shelf reference to another basket.
///
/// `ShelfItem.basketID` is optional so references decoded from older shelf
/// files can still be moved; those items are treated as belonging to the
/// active basket until the store migrates them.
@MainActor
struct ShelfMoveMenu: View {
    @ObservedObject private var store: FileShelfStore
    private let item: ShelfItem

    init(store: FileShelfStore, item: ShelfItem) {
        self.store = store
        self.item = item
    }

    init(item: ShelfItem) {
        self.init(store: .shared, item: item)
    }

    private var currentBasketID: UUID {
        item.basketID ?? store.activeBasketID
    }

    private var destinations: [ShelfBasket] {
        store.baskets.filter { $0.id != currentBasketID }
    }

    var body: some View {
        Menu {
            if destinations.isEmpty {
                Text("No other baskets")
            } else {
                ForEach(destinations) { basket in
                    Button {
                        store.move(item, to: basket.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "tray")
                            Text(basket.name)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text("\(store.basketItemCount(basket.id))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Move to \(basket.name), \(store.basketItemCount(basket.id)) \(store.basketItemCount(basket.id) == 1 ? "item" : "items")")
                    }
                }
            }
        } label: {
            Label("Move to basket", systemImage: "arrow.right")
        }
        .menuStyle(.borderlessButton)
        .help("Move \(item.name) to another basket")
        .accessibilityLabel("Move \(item.name) to another basket")
    }
}
