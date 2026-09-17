import SwiftUI
import AppKit

/// A small, local notes editor for the expanded island.
///
/// The workspace has the full notes experience. This view intentionally keeps
/// the same `ProductivityStore` and note model while making the common actions
/// available without opening another window.
@MainActor
struct CompactNotesView: View {
    @ObservedObject private var store: ProductivityStore

    // App storage preserves drafts in the AppKit-hosted panel across collapse and relaunch.
    // The mode and note id are stored alongside the text so an in-progress edit
    // can be restored as the same edit instead of becoming an accidental new note.
    @AppStorage("supernotch.compactNotes.draft") private var draft = ""
    @AppStorage("supernotch.compactNotes.editingID") private var storedEditingID = ""
    @AppStorage("supernotch.compactNotes.mode") private var storedMode = "list"

    @FocusState private var editorFocused: Bool
    private let accent = Color(red: 0.92, green: 0.69, blue: 0.22)

    init(store: ProductivityStore) {
        self.store = store
    }

    init() {
        self.store = .shared
    }

    private var isEditing: Bool {
        storedMode == "editor"
    }

    private var editingID: UUID? {
        UUID(uuidString: storedEditingID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Group {
                if isEditing {
                    editor
                } else {
                    noteList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: 600, minHeight: 188, maxHeight: .infinity, alignment: .topLeading)
        .tint(accent)
        .onAppear(perform: restoreDraftIfNeeded)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isEditing ? "square.and.pencil" : "note.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)

            Text(isEditing ? (editingID == nil ? "New note" : "Edit note") : "Notes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            Text("\(store.notes.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                beginNewNote()
            } label: {
                Label("New", systemImage: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(accent.opacity(0.16), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent)
            .accessibilityLabel("New note")
            .help("Start a new note")
        }
        .accessibilityElement(children: .contain)
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.notes.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(store.notes) { note in
                            noteCard(note)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            listFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "note.text.badge.plus")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(accent.opacity(0.85))

            Text("No notes yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))

            Text("Capture a thought without leaving the island.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No notes yet. Use New to capture a thought.")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft)
                .focused($editorFocused)
                .onAppear { editorFocused = true }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 88, maxHeight: .infinity)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.6)
                }
                .accessibilityLabel("Note text")
                .accessibilityHint("Enter the text for this note")

            HStack(spacing: 7) {
                Button {
                    cancelEditing()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Cancel note editing")

                Spacer(minLength: 5)

                fullNotesButton

                Button {
                    saveDraft()
                } label: {
                    Label("Save", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(canSave ? accent : Color.white.opacity(0.09), in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSave ? .black : .secondary)
                .disabled(!canSave)
                .accessibilityLabel(editingID == nil ? "Save note" : "Save note changes")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var listFooter: some View {
        HStack(spacing: 8) {
            Text(store.notes.isEmpty ? "Saved locally on this Mac" : "Select a note to edit")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 6)
            fullNotesButton
        }
    }

    private var fullNotesButton: some View {
        Button {
            openFullNotes()
        } label: {
            Label("Full Notes", systemImage: "arrow.up.right")
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.58))
        .accessibilityLabel("Open full Notes workspace")
        .help("Open full Notes workspace")
    }

    private func noteCard(_ note: SavedNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                beginEditing(note)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    RelativeTimeText(date: note.updated)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit note: \(note.text.prefix(100))")
            .accessibilityHint("Open this saved note for editing")

            Button {
                copy(note)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.58))
            .accessibilityLabel("Copy note")
            .accessibilityHint("Copy this note to the clipboard")
            .help("Copy note")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.6)
        }
        .accessibilityElement(children: .contain)
    }

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func restoreDraftIfNeeded() {
        // A draft should only disappear after an explicit save, cancel, or new
        // action. Recovering a non-empty draft also handles older storage where
        // the mode key was not written.
        if storedMode != "editor", !draft.isEmpty {
            storedMode = "editor"
        }
    }

    private func beginNewNote() {
        draft = ""
        storedEditingID = ""
        storedMode = "editor"
        editorFocused = true
    }

    private func beginEditing(_ note: SavedNote) {
        draft = note.text
        storedEditingID = note.id.uuidString
        storedMode = "editor"
    }

    private func saveDraft() {
        guard canSave else { return }
        store.saveNote(draft, id: editingID)
        clearDraftAndShowList()
    }

    private func cancelEditing() {
        clearDraftAndShowList()
    }

    private func clearDraftAndShowList() {
        draft = ""
        storedEditingID = ""
        storedMode = "list"
    }

    private func copy(_ note: SavedNote) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
    }

    private func openFullNotes() {
        AppState.shared.page = .productivity
        AppState.shared.toolDetail = "Notes"
        AppDelegate.shared?.openWorkspace()
    }
}
