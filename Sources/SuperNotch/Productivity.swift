import SwiftUI
import EventKit
import AppKit

struct SavedNote: Identifiable, Codable {
    var id = UUID()
    var text: String
    var updated = Date()
}

@MainActor
final class ProductivityStore: ObservableObject {
    static let shared = ProductivityStore()
    @Published var selectedMinutes: Double = 25
    @Published private(set) var remaining: TimeInterval = 25 * 60
    @Published private(set) var running = false
    @Published private(set) var notes: [SavedNote] = []
    @Published private(set) var awake = false
    @Published var status = ""
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var reminders: [EKReminder] = []
    @Published private(set) var calendarConnected = false
    @Published private(set) var remindersConnected = false
    private let eventStore = EKEventStore()
    private var deadline: Date?
    private var ticker: Timer?
    private var agendaTicker: Timer?
    private var agendaObservers: [NSObjectProtocol] = []
    private var remindersRevision = 0
    private var caffeinate: Process?
    private let defaults = UserDefaults.standard
    var focusRemainingText: String {
        let seconds = max(0, Int(ceil(remaining)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    private init() {
        if let data = defaults.data(forKey: "productivity.notes"), let decoded = try? JSONDecoder().decode([SavedNote].self, from: data) { notes = decoded }
        let savedMinutes = defaults.double(forKey: "productivity.minutes")
        if savedMinutes > 0 { selectedMinutes = savedMinutes }
        remaining = defaults.object(forKey: "productivity.remaining") as? Double ?? selectedMinutes * 60
        if let savedDeadline = defaults.object(forKey: "productivity.deadline") as? Date {
            if savedDeadline > Date() { deadline = savedDeadline; running = true; remaining = savedDeadline.timeIntervalSinceNow }
            else { remaining = 0; defaults.removeObject(forKey: "productivity.deadline") }
        }
        calendarConnected = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersConnected = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        updateTicker()
        if calendarConnected { reloadEvents() }
        if remindersConnected { reloadReminders() }
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification] {
            agendaObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshAuthorizationAndContent() }
            })
        }
        updateAgendaTicker()
    }
    /// Refresh existing grants without presenting a permission request.
    func refreshAuthorizationAndContent() {
        calendarConnected = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersConnected = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        reloadEvents()
        reloadReminders()
        updateAgendaTicker()
    }
    /// Keep minute-bound agenda data fresh only after the user has connected a source.
    /// Permission and store-change notifications handle the disconnected state without polling.
    private func updateAgendaTicker() {
        guard calendarConnected || remindersConnected else {
            agendaTicker?.invalidate(); agendaTicker = nil
            return
        }
        guard agendaTicker == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAuthorizationAndContent() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        agendaTicker = timer
    }
    /// The countdown ticks only while a session runs.
    private func updateTicker() {
        if running {
            guard ticker == nil else { return }
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else {
            ticker?.invalidate(); ticker = nil
        }
    }
    private func tick() {
        guard running, let deadline else { updateTicker(); return }
        remaining = max(0, deadline.timeIntervalSinceNow)
        if remaining == 0 {
            running = false; self.deadline = nil; persistTimer(); updateTicker()
            status = "Focus session complete. Take a moment to recharge."
            NSSound(named: "Glass")?.play()
        }
    }
    func toggleTimer() {
        if running {
            remaining = max(0, deadline?.timeIntervalSinceNow ?? remaining)
            running = false; deadline = nil
        } else {
            if remaining <= 0 { remaining = selectedMinutes * 60 }
            deadline = Date().addingTimeInterval(remaining); running = true
        }
        persistTimer(); updateTicker()
    }
    func resetTimer(minutes: Double? = nil) {
        if let minutes { selectedMinutes = minutes }
        running = false; deadline = nil; remaining = selectedMinutes * 60; persistTimer(); updateTicker()
    }
    private func persistTimer() {
        defaults.set(selectedMinutes, forKey: "productivity.minutes")
        defaults.set(remaining, forKey: "productivity.remaining")
        if let deadline { defaults.set(deadline, forKey: "productivity.deadline") }
        else { defaults.removeObject(forKey: "productivity.deadline") }
    }
    func saveNote(_ text: String, id: UUID? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let id, let index = notes.firstIndex(where: { $0.id == id }) { notes[index].text = text; notes[index].updated = Date() }
        else { notes.insert(SavedNote(text: text), at: 0) }
        notes.sort { $0.updated > $1.updated }; persistNotes()
    }
    func deleteNote(_ id: UUID) { notes.removeAll { $0.id == id }; persistNotes() }
    private func persistNotes() { if let data = try? JSONEncoder().encode(notes) { defaults.set(data, forKey: "productivity.notes") } }
    func toggleAwake() {
        if awake { caffeinate?.terminate(); caffeinate = nil; awake = false; return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-di", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        do { try process.run(); caffeinate = process; awake = true }
        catch { status = "Could not enable Keep Awake: \(error.localizedDescription)" }
    }
    func connectCalendar() {
        Task {
            do { calendarConnected = try await eventStore.requestFullAccessToEvents(); if calendarConnected { reloadEvents() } else { events = []; status = "Calendar access was declined. You can enable it in System Settings → Privacy & Security → Calendars." } }
            catch { status = error.localizedDescription }
        }
    }
    func connectReminders() {
        Task {
            do { remindersConnected = try await eventStore.requestFullAccessToReminders(); if remindersConnected { reloadReminders() } else { reminders = []; status = "Reminders access was declined. You can enable it in System Settings → Privacy & Security → Reminders." } }
            catch { status = error.localizedDescription }
        }
    }
    func reloadEvents() {
        calendarConnected = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard calendarConnected else { events = []; return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        events = eventStore.events(matching: eventStore.predicateForEvents(withStart: now, end: end, calendars: nil)).sorted { $0.startDate < $1.startDate }
    }
    func reloadReminders() {
        remindersRevision += 1
        let revision = remindersRevision
        remindersConnected = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        guard remindersConnected else { reminders = []; return }
        eventStore.fetchReminders(matching: eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)) { [weak self] result in
            Task { @MainActor in
                guard let self, self.remindersRevision == revision else { return }
                guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                    self.remindersConnected = false; self.reminders = []; return
                }
                self.reminders = (result ?? []).sorted {
                    let left = $0.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                    let right = $1.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? .distantFuture
                    return left == right ? ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) : left < right
                }
            }
        }
    }
    @discardableResult
    func addReminder(_ title: String) -> Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { refreshAuthorizationAndContent(); return false }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else { status = "Create a Reminders list in the Reminders app first."; return false }
        let reminder = EKReminder(eventStore: eventStore); reminder.title = clean; reminder.calendar = calendar
        do { try eventStore.save(reminder, commit: true); reloadReminders(); return true }
        catch { status = error.localizedDescription; return false }
    }
    func completeReminder(_ reminder: EKReminder) {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { refreshAuthorizationAndContent(); return }
        reminder.isCompleted = true
        do { try eventStore.save(reminder, commit: true); reloadReminders() }
        catch { reminder.isCompleted = false; status = error.localizedDescription }
    }
}

struct ProductivityView: View {
    @ObservedObject private var store = ProductivityStore.shared
    @State private var tool = "Focus"
    let initialTool: String
    init(initialTool: String = "") {
        self.initialTool = initialTool
        _tool = State(initialValue: Self.toolName(initialTool))
    }
    private static func toolName(_ value: String) -> String {
        switch value {
        case "Notes": return "Notes"
        case "Calendar & reminders": return "Agenda"
        case "Keep awake": return "Awake"
        default: return "Focus"
        }
    }
    @State private var noteText = ""
    @State private var editingID: UUID?
    @State private var reminderTitle = ""
    private let tools = ["Focus", "Notes", "Agenda", "Awake"]
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            Picker("Tool", selection: $tool) { ForEach(tools, id: \.self) { Text($0 == "Awake" ? "Keep Awake" : $0).tag($0) } }.pickerStyle(.segmented).labelsHidden().fixedSize().frame(maxWidth: .infinity)
            switch tool {
            case "Focus": focus
            case "Notes": notes
            case "Agenda": agenda
            default: awake
            }
            if !store.status.isEmpty { InlineMessage(text: store.status) { store.status = "" } }
        }.padding(20).frame(maxWidth: 760, alignment: .topLeading).frame(maxWidth: .infinity) }
            .onChange(of: initialTool) { _, value in
                tool = Self.toolName(value)
            }
    }
    private var focus: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(.fill.tertiary, lineWidth: 10)
                Circle().trim(from: 0, to: max(0.001, 1 - store.remaining / max(1, store.selectedMinutes * 60)))
                    .stroke(Color.orange.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: store.remaining)
                VStack(spacing: 4) {
                    Text(store.focusRemainingText).font(.system(size: 52, weight: .light, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                    Text(store.running ? "Focusing" : "Ready").font(.callout).foregroundStyle(.secondary)
                }
            }.frame(width: 230, height: 230)
            Picker("Duration", selection: Binding(get: { store.selectedMinutes }, set: { store.resetTimer(minutes: $0) })) {
                ForEach([5, 15, 25, 50], id: \.self) { minutes in Text("\(minutes) min").tag(Double(minutes)) }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
            HStack(spacing: 10) {
                Button { store.toggleTimer() } label: { Label(store.running ? "Pause" : "Start Focus", systemImage: store.running ? "pause.fill" : "play.fill").frame(minWidth: 110) }.buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                Button { store.resetTimer() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }.controlSize(.large).help("Reset timer")
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
    }
    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label(editingID == nil ? "New Note" : "Edit Note", systemImage: "note.text").font(.headline); Spacer(); Text("\(store.notes.count) saved").font(.callout).foregroundStyle(.secondary) }
            TextEditor(text: $noteText).font(.body).frame(height: 110).editorStyle()
            HStack {
                Text("Saved locally on this Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if editingID != nil { Button("Cancel") { editingID = nil; noteText = "" } }
                Button(editingID == nil ? "Save Note" : "Save Changes") { store.saveNote(noteText, id: editingID); noteText = ""; editingID = nil }.buttonStyle(.borderedProminent).disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Group {
                LazyVStack(spacing: 8) {
                    if store.notes.isEmpty { empty("No notes yet", detail: "Capture a thought, link, or reminder above.", symbol: "note.text") }
                    ForEach(store.notes) { note in
                        HStack(alignment: .top) {
                            Button { editingID = note.id; noteText = note.text } label: {
                                VStack(alignment: .leading, spacing: 4) { Text(note.text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading); RelativeTimeText(date: note.updated).font(.caption2).foregroundStyle(.secondary) }
                            }.buttonStyle(.plain)
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy note")
                            Button { store.deleteNote(note.id); if editingID == note.id { editingID = nil; noteText = "" } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete note")
                        }.cardStyle(padding: 12)
                    }
                }
            }
        }
    }
    private var agenda: some View {
        Group {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Label("Next Seven Days", systemImage: "calendar").font(.headline); Spacer(); if store.calendarConnected { Button { store.reloadEvents() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain) } }
                if !store.calendarConnected {
                    Text("Connect your calendars to see upcoming events.").font(.caption).foregroundStyle(.secondary)
                    Button("Connect Calendar") { store.connectCalendar() }
                } else if store.events.isEmpty { Text("No upcoming events.").foregroundStyle(.secondary) }
                else {
                    ForEach(Array(store.events.prefix(20).enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .top) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: event.calendar.cgColor)).frame(width: 3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title ?? "Untitled event").font(.subheadline.weight(.medium))
                                Text(event.isAllDay ? event.startDate.formatted(date: .abbreviated, time: .omitted) + " · All day" : event.startDate.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                if let location = event.location, !location.isEmpty { Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }; Spacer()
                        }.rowStyle()
                    }
                }
                Divider()
                HStack { Label("Reminders", systemImage: "checklist").font(.headline); Spacer(); if store.remindersConnected { Button { store.reloadReminders() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain) } }
                if !store.remindersConnected { Button("Connect Reminders") { store.connectReminders() } }
                else {
                    HStack { TextField("Add a reminder…", text: $reminderTitle).onSubmit(addReminder); Button(action: addReminder) { Image(systemName: "plus.circle.fill") }.disabled(reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    if store.reminders.isEmpty { Text("All caught up.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(store.reminders.prefix(30).enumerated()), id: \.offset) { _, reminder in
                        HStack { Button { store.completeReminder(reminder) } label: { Image(systemName: "circle") }.buttonStyle(.plain).help("Mark complete"); Text(reminder.title ?? "Untitled reminder"); Spacer() }.padding(.vertical, 5)
                    }
                }
            }
        }
    }
    private func addReminder() { if store.addReminder(reminderTitle) { reminderTitle = "" } }
    private var awake: some View {
        VStack(spacing: 18) {
            Image(systemName: store.awake ? "cup.and.saucer.fill" : "cup.and.saucer").font(.system(size: 54)).foregroundStyle(store.awake ? .orange : .secondary).symbolEffect(.pulse, isActive: store.awake)
            Text(store.awake ? "Your Mac is staying awake" : "Stay in the moment").font(.title3.weight(.semibold))
            Text("Keep the display on and prevent idle sleep while SuperNotch is running. Closing your Mac’s lid still allows it to sleep.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            Button { store.toggleAwake() } label: { Label(store.awake ? "Allow Sleep" : "Keep Awake", systemImage: store.awake ? "moon.zzz" : "sun.max.fill").frame(width: 150) }.buttonStyle(.borderedProminent).tint(store.awake ? .gray : .orange).controlSize(.large)
        }.frame(maxWidth: .infinity).padding(.vertical, 18)
    }
    private func empty(_ title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 8) { Image(systemName: symbol).font(.title).foregroundStyle(.secondary); Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(20)
    }
}
