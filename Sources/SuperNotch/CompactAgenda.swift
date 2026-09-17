import SwiftUI
import EventKit
import AppKit

/// A small, permission-aware agenda for the expanded island.
///
/// The workspace has the full productivity view. This presentation keeps the
/// island useful at a glance while keeping EventKit access behind an explicit
/// user action.
@MainActor
struct CompactAgendaView: View {
    private enum Section: String, CaseIterable {
        case agenda = "Agenda"
        case reminders = "Reminders"
    }

    @ObservedObject private var store: ProductivityStore
    @State private var section: Section = .agenda
    @State private var reminderTitle = ""

    private let accent = Color.orange

    init(store: ProductivityStore) {
        self.store = store
    }

    init() {
        self.store = .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            sectionPicker

            if section == .agenda {
                agendaContent
            } else {
                remindersContent
            }

            if !store.status.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle.fill")
                    Text(store.status)
                        .lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.86))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: 600, minHeight: 190, maxHeight: 210, alignment: .topLeading)
        .foregroundStyle(.white)
        .tint(accent)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: section == .agenda ? "calendar" : "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)

            Text(section.rawValue)
                .font(.system(size: 12, weight: .semibold))

            Spacer(minLength: 8)

            Button {
                AppState.shared.toolDetail = "Calendar & reminders"
                AppState.shared.page = .productivity
                AppDelegate.shared?.openWorkspace()
            } label: {
                Label("Full Agenda", systemImage: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.62))
            .help("Open Calendar & reminders")
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 3) {
            ForEach(Section.allCases, id: \.self) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        section = item
                    }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(section == item ? .white : .white.opacity(0.48))
                        .background(section == item ? accent.opacity(0.22) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.055), in: Capsule())
    }

    private var agendaContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Next 7 days")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                if store.calendarConnected {
                    Button {
                        store.reloadEvents()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.48))
                    .help("Refresh calendar")
                }
            }

            if !store.calendarConnected {
                connectCard(
                    title: "Connect Calendar",
                    detail: "Allow access to show upcoming events.",
                    symbol: "calendar"
                ) {
                    store.connectCalendar()
                }
            } else if upcomingEvents.isEmpty {
                emptyState(
                    title: "No upcoming events",
                    detail: "Your next seven days are clear.",
                    symbol: "calendar"
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(upcomingEvents.prefix(20).map { (id: eventIdentifier($0), event: $0) }, id: \.id) { entry in
                            eventRow(entry.event)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 96)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var remindersContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Open reminders")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                if store.remindersConnected {
                    Button {
                        store.reloadReminders()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.48))
                    .help("Refresh reminders")
                }
            }

            if !store.remindersConnected {
                connectCard(
                    title: "Connect Reminders",
                    detail: "Allow access to see your open reminders.",
                    symbol: "checklist"
                ) {
                    store.connectReminders()
                }
            } else {
                addReminderRow

                if store.reminders.isEmpty {
                    emptyState(
                        title: "All caught up",
                        detail: "No open reminders.",
                        symbol: "checkmark.circle"
                    )
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(store.reminders.prefix(30), id: \.calendarItemIdentifier) { reminder in
                                reminderRow(reminder)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                    .frame(maxHeight: 60)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func connectCard(
        title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button("Connect", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(accent)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var addReminderRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)

            TextField("Add a reminder", text: $reminderTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit(addReminder)

            Button("Add", action: addReminder)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
                .disabled(reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func eventRow(_ event: EKEvent) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.calendar?.cgColor.map { Color(cgColor: $0) } ?? .orange)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(eventTitle(event))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Text(eventDateTime(event))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func reminderRow(_ reminder: EKReminder) -> some View {
        HStack(spacing: 7) {
            Button {
                store.completeReminder(reminder)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(accent.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("Complete reminder")
            .accessibilityLabel("Complete reminder")

            Text(reminderTitle(for: reminder))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func emptyState(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var upcomingEvents: [EKEvent] {
        let now = Date()
        return store.events.filter { $0.startDate >= now }
    }

    private func eventDateTime(_ event: EKEvent) -> String {
        let date = event.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if event.isAllDay {
            return "\(date) · All day"
        }
        return "\(date) · \(event.startDate.formatted(date: .omitted, time: .shortened))"
    }

    private func eventIdentifier(_ event: EKEvent) -> String {
        "\(event.calendarItemIdentifier)#\(event.startDate.timeIntervalSinceReferenceDate)"
    }

    private func eventTitle(_ event: EKEvent) -> String {
        guard let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Untitled event"
        }
        return title
    }

    private func reminderTitle(for reminder: EKReminder) -> String {
        guard let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Untitled reminder"
        }
        return title
    }

    private func addReminder() {
        if store.addReminder(reminderTitle) {
            reminderTitle = ""
        }
    }
}
