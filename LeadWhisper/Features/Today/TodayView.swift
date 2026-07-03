import FactoryKit
import SwiftData
import SwiftUI

struct TodayView: View {
    @InjectedObject(\.crmRepository) private var crmRepository
    // "open" is FollowUpState.open.rawValue; #Predicate cannot reference the enum.
    @Query(filter: #Predicate<FollowUpTask> { $0.stateRaw == "open" })
    private var openTasks: [FollowUpTask]
    @Query private var latestActivity: [ActivityEvent]
    @State private var sheet: TodaySheet?
    @State private var pendingDeleteTask: FollowUpTask?
    @State private var actionError: PresentableError?

    init() {
        var descriptor = FetchDescriptor<ActivityEvent>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        _latestActivity = Query(descriptor)
    }

    private var openFollowUps: [FollowUpTask] {
        openTasks.sorted(by: FollowUpTask.dueDateOrder)
    }

    private var latestActivityEvent: ActivityEvent? {
        latestActivity.first
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
                                        sheet = .agent(initialPrompt: agentPrompt(for: task))
                                    } label: {
                                        Label("Agent", systemImage: "sparkles")
                                    }
                                    .tint(.blue)

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
                                    Button {
                                        pendingDeleteTask = task
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .tint(.red)

                                    Button {
                                        sheet = .editFollowUp(task)
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }

                if let latestActivityEvent {
                    Section {
                        NavigationLink {
                            ActivityLogView()
                        } label: {
                            ActivitySummaryRow(event: latestActivityEvent)
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .talkFloatingAction {
                sheet = .agent(initialPrompt: nil)
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .agent(let initialPrompt):
                    AgentComposerSheetView(initialPrompt: initialPrompt)
                case .editFollowUp(let task):
                    FollowUpEditView(task: task)
                }
            }
            .confirmationDialog(
                "Delete follow-up?",
                isPresented: .init(isPresenting: $pendingDeleteTask),
                titleVisibility: .visible,
                presenting: pendingDeleteTask
            ) { task in
                Button("Delete Follow-up", role: .destructive) {
                    perform { try $0.deleteFollowUp(task) }
                    pendingDeleteTask = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteTask = nil
                }
            } message: { _ in
                Text("This removes the task and writes an activity entry.")
            }
            .crmErrorAlert($actionError)
        }
    }

    private func perform(_ action: (CRMRepository) throws -> Void) {
        do {
            try action(crmRepository)
        } catch {
            actionError = PresentableError(error)
        }
    }

    private func agentPrompt(for task: FollowUpTask) -> String {
        var parts = ["Update the follow-up \(task.title)"]
        if let contact = task.contact {
            parts.append("for \(contact.fullName)")
        } else if let opportunity = task.opportunity {
            parts.append("for the opportunity \(opportunity.title)")
        }
        return parts.joined(separator: " ")
    }
}

private enum TodaySheet: Identifiable {
    case agent(initialPrompt: String?)
    case editFollowUp(FollowUpTask)

    var id: String {
        switch self {
        case .agent(let initialPrompt):
            "agent-\(initialPrompt ?? "blank")"
        case .editFollowUp(let task):
            "editFollowUp-\(task.id.uuidString)"
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

private struct ActivitySummaryRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: event.activityIconName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recent Activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(event.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ActivityLogView: View {
    @Query(sort: [SortDescriptor(\ActivityEvent.createdAt, order: .reverse)])
    private var activityEvents: [ActivityEvent]

    var body: some View {
        List {
            if activityEvents.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock")
            } else {
                ForEach(activityEvents) { event in
                    ActivityRow(event: event)
                }
            }
        }
        .navigationTitle("Activity Log")
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.activityIconName)
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
}

private extension ActivityEvent {
    var activityIconName: String {
        entityKind.systemImage
    }
}
