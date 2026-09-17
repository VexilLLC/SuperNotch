import Foundation
import SwiftUI

/// The editor used by clipboard cards to add, remove, and save tags.
///
/// The view only mutates the store through `setTags(_:for:)` when Save is
/// pressed. In particular, editing a tag never copies the clipboard item or
/// writes to the system pasteboard.
@MainActor
struct ClipboardTagEditor: View {
    private static let maximumTagCount = 8
    private static let maximumTagLength = 24

    @ObservedObject private var store: ClipboardStore
    private let entry: ClipboardEntry
    @Environment(\.dismiss) private var dismiss

    @State private var draftTags: [String]
    @State private var tagInput = ""
    @State private var validationMessage: String?
    @FocusState private var tagInputFocused: Bool

    init(store: ClipboardStore, entry: ClipboardEntry) {
        self.store = store
        self.entry = entry
        _draftTags = State(initialValue: entry.tagNames)
    }

    private var trimmedInput: String {
        tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddInput: Bool {
        Self.validateTag(trimmedInput, existingTags: draftTags) == nil
    }

    private var suggestions: [String] {
        let lowercasedDraft = Set(draftTags.map { $0.lowercased() })
        return store.allTags.filter { !lowercasedDraft.contains($0.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            tagList
            inputSection

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Tag error: \(validationMessage)")
            }

            HStack(spacing: 10) {
                Spacer(minLength: 0)

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveTags()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 350, idealWidth: 390, maxWidth: 450)
        .background(.regularMaterial)
        .onAppear {
            tagInputFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit clipboard tags")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Edit tags")
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            Text("Use up to \(Self.maximumTagCount) tags to keep this item easy to find.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tagList: some View {
        if draftTags.isEmpty {
            Text("No tags yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(draftTags.enumerated()), id: \.offset) { _, tag in
                        tagChip(tag)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Current tags")
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                TextField("Add a tag", text: $tagInput)
                    .textFieldStyle(.plain)
                    .focused($tagInputFocused)
                    .onSubmit {
                        addInputTag()
                    }
                    .onChange(of: tagInput) { _, _ in
                        validationMessage = nil
                    }
                    .accessibilityLabel("New tag")

                Button {
                    addInputTag()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canAddInput ? Color.accentColor : .secondary)
                .disabled(!canAddInput)
                .help("Add tag")
                .accessibilityLabel("Add tag")
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tagInputFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 0.8)
            }

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                addTag(suggestion)
                            } label: {
                                Label(suggestion, systemImage: "tag")
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .frame(height: 25)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .background(Color.primary.opacity(0.055), in: Capsule())
                            .help("Add \(suggestion)")
                            .accessibilityLabel("Add suggested tag \(suggestion)")
                        }
                    }
                    .padding(.vertical, 1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Existing tags")
            }
        }
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Button {
                removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 15, height: 15)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 25)
        .foregroundStyle(Color.accentColor)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().stroke(Color.accentColor.opacity(0.22), lineWidth: 0.6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tag \(tag)")
    }

    private var canSave: Bool {
        draftTags.count <= Self.maximumTagCount
            && draftTags.allSatisfy { Self.validateTag($0, existingTags: []) == nil }
    }

    private func addInputTag() {
        addTag(trimmedInput)
    }

    private func addTag(_ rawTag: String) {
        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let error = Self.validateTag(tag, existingTags: draftTags) else {
            draftTags.append(tag)
            tagInput = ""
            validationMessage = nil
            tagInputFocused = true
            return
        }
        validationMessage = error
    }

    private func removeTag(_ tag: String) {
        draftTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        validationMessage = nil
    }

    private func saveTags() {
        guard canSave else {
            validationMessage = "Review the tags before saving."
            return
        }
        guard store.setTags(draftTags, for: entry) else {
            validationMessage = store.status ?? "Could not save tags."
            return
        }
        dismiss()
    }

    private static func validateTag(_ tag: String, existingTags: [String]) -> String? {
        guard !tag.isEmpty else { return "Enter a tag first." }
        guard tag.count <= maximumTagLength else {
            return "Tags can be up to \(maximumTagLength) characters."
        }
        guard !tag.contains(",") else { return "Tags cannot contain commas." }
        guard !tag.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return "Tags cannot contain control characters."
        }
        guard !existingTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else {
            return "That tag is already on this item."
        }
        guard existingTags.count < maximumTagCount else {
            return "Each item can have up to \(maximumTagCount) tags."
        }
        return nil
    }
}

/// Compact tag labels for clipboard cards and list rows.
@MainActor
struct ClipboardTagBadges: View {
    let tags: [String]

    private let maximumVisibleBadges = 3
    private let maximumBadgeWidth: CGFloat = 84

    private var visibleTags: [String] {
        Array(tags.prefix(maximumVisibleBadges))
    }

    var body: some View {
        if tags.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                ForEach(Array(visibleTags.enumerated()), id: \.offset) { _, tag in
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: maximumBadgeWidth, alignment: .leading)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .foregroundStyle(.secondary)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay {
                            Capsule().stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
                        }
                }

                if tags.count > maximumVisibleBadges {
                    Text("+\(tags.count - maximumVisibleBadges)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(Color.primary.opacity(0.045), in: Capsule())
                        .accessibilityLabel("\(tags.count - maximumVisibleBadges) more tags")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
        }
    }
}

/// A compact menu for selecting one of the tags known by the clipboard store.
@MainActor
struct ClipboardTagFilter: View {
    @ObservedObject private var store: ClipboardStore
    @Binding private var selection: String?

    init(store: ClipboardStore, selection: Binding<String?>) {
        self.store = store
        _selection = selection
    }

    private var selectedTagLabel: String {
        selection ?? "All tags"
    }

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                if selection == nil {
                    Label("All tags", systemImage: "checkmark")
                } else {
                    Text("All tags")
                }
            }

            if !store.allTags.isEmpty {
                Divider()

                ForEach(store.allTags, id: \.self) { tag in
                    Button {
                        selection = tag
                    } label: {
                        if isSelected(tag) {
                            Label(tag, systemImage: "checkmark")
                        } else {
                            Text(tag)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "tag")
                    .font(.system(size: 10, weight: .medium))
                Text(selectedTagLabel)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(minWidth: 88, minHeight: 29)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("Filter clipboard by tag")
        .accessibilityLabel("Clipboard tag filter")
        .accessibilityValue(selectedTagLabel)
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: store.allTags) { _, _ in
            reconcileSelection()
        }
    }

    private func isSelected(_ tag: String) -> Bool {
        guard let selection else { return false }
        return selection.caseInsensitiveCompare(tag) == .orderedSame
    }

    private func reconcileSelection() {
        guard let selection else { return }
        guard let canonical = store.allTags.first(where: { $0.caseInsensitiveCompare(selection) == .orderedSame }) else {
            self.selection = nil
            return
        }
        if canonical != selection {
            self.selection = canonical
        }
    }
}
