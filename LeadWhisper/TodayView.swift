import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var followUps: [FollowUpTask]
    @Query private var activity: [ActivityEvent]
    @State private var sheet: TodaySheet?
    @State private var pendingDeleteTask: FollowUpTask?
    @State private var actionError: PresentableError?

    private var openFollowUps: [FollowUpTask] {
        followUps
            .filter { $0.state == .open }
            .sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (left?, right?):
                    left < right
                case (_?, nil):
                    true
                case (nil, _?):
                    false
                case (nil, nil):
                    lhs.createdAt < rhs.createdAt
                }
            }
    }

    private var recentActivity: [ActivityEvent] {
        activity.sorted { $0.createdAt > $1.createdAt }.prefix(8).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Open Follow-ups") {
                    if openFollowUps.isEmpty {
                        ContentUnavailableView("No open follow-ups", systemImage: "checkmark.circle")
                    } else {
                        ForEach(openFollowUps) { task in
                            FollowUpRow(task: task)
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button {
                                        perform { try $0.markFollowUpDone(task) }
                                    } label: {
                                        Label("Done", systemImage: "checkmark")
                                    }
                                    .tint(.green)

                                    Button {
                                        perform { try $0.archiveFollowUp(task) }
                                    } label: {
                                        Label("Archive", systemImage: "archivebox")
                                    }
                                    .tint(.orange)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        pendingDeleteTask = task
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }

                                    Button {
                                        sheet = .editFollowUp(task.id)
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }

                Section("Recent Activity") {
                    if recentActivity.isEmpty {
                        ContentUnavailableView("No activity yet", systemImage: "clock")
                    } else {
                        ForEach(recentActivity) { event in
                            ActivityRow(event: event)
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .talkFloatingAction {
                sheet = .agent
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .agent:
                    AgentComposerSheetView()
                case .editFollowUp(let id):
                    if let task = followUps.first(where: { $0.id == id }) {
                        FollowUpEditView(task: task)
                    }
                }
            }
            .confirmationDialog(
                "Delete follow-up?",
                isPresented: Binding(
                    get: { pendingDeleteTask != nil },
                    set: { if !$0 { pendingDeleteTask = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Follow-up", role: .destructive) {
                    if let pendingDeleteTask {
                        perform { try $0.deleteFollowUp(pendingDeleteTask) }
                    }
                    pendingDeleteTask = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteTask = nil
                }
            } message: {
                Text("This removes the task and writes an activity entry.")
            }
            .crmErrorAlert($actionError)
        }
    }

    private func perform(_ action: (CRMRepository) throws -> Void) {
        do {
            try action(CRMRepository(context: modelContext))
        } catch {
            actionError = PresentableError(error)
        }
    }
}

private enum TodaySheet: Identifiable {
    case agent
    case editFollowUp(UUID)

    var id: String {
        switch self {
        case .agent:
            "agent"
        case .editFollowUp(let id):
            "editFollowUp-\(id.uuidString)"
        }
    }
}

private struct FollowUpRow: View {
    let task: FollowUpTask

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge")
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.headline)
                if let dueDate = task.dueDate {
                    Text(dueDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if !task.dueDateText.isEmpty {
                    Text(task.dueDateText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch event.entityKind {
        case "contact":
            "person.crop.circle"
        case "opportunity":
            "chart.line.uptrend.xyaxis"
        case "followUp":
            "bell"
        case "interaction":
            "text.bubble"
        default:
            "sparkles"
        }
    }
}
