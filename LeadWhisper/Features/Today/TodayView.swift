import FactoryKit
import SwiftData
import SwiftUI

struct TodayView: View {
    @InjectedObject(\.crmRepository) private var crmRepository
    // "open" is FollowUpState.open.rawValue; #Predicate cannot reference the enum.
    @Query(filter: #Predicate<FollowUpTask> { $0.stateRaw == "open" })
    private var openTasks: [FollowUpTask]
    @Query(sort: [SortDescriptor(\Opportunity.updatedAt, order: .reverse)])
    private var opportunities: [Opportunity]
    @Query private var recentActivity: [ActivityEvent]
    @State private var sheet: TodaySheet?
    @State private var pendingDeleteTask: FollowUpTask?
    @State private var actionError: PresentableError?

    init() {
        var descriptor = FetchDescriptor<ActivityEvent>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 3
        _recentActivity = Query(descriptor)
    }

    private var openFollowUps: [FollowUpTask] {
        openTasks.sorted(by: FollowUpTask.dueDateOrder)
    }

    private var followUpSummary: FollowUpSummary {
        FollowUpSummary(tasks: openFollowUps)
    }

    private var followUpSections: [FollowUpSection] {
        let groupedTasks = Dictionary(grouping: openFollowUps) { task in
            FollowUpDueBucket.bucket(for: task)
        }

        return FollowUpDueBucket.allCases.compactMap { bucket in
            guard let tasks = groupedTasks[bucket], !tasks.isEmpty else { return nil }
            return FollowUpSection(bucket: bucket, tasks: tasks.sorted(by: FollowUpTask.dueDateOrder))
        }
    }

    private var opportunitiesNeedingFollowUp: [Opportunity] {
        Array(
            opportunities
                .filter { opportunity in
                    opportunity.stage.isActive && !opportunity.followUps.contains { $0.state == .open }
                }
                .prefix(3)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if !openFollowUps.isEmpty {
                    Section("Action Inbox") {
                        FollowUpPrioritySummary(summary: followUpSummary)
                    }
                }

                if openFollowUps.isEmpty {
                    Section("Open Follow-ups") {
                        ContentUnavailableView("No open follow-ups", systemImage: "checkmark.circle")
                    }
                } else {
                    ForEach(followUpSections) { section in
                        Section(section.bucket.sectionTitle) {
                            ForEach(section.tasks) { task in
                                followUpButton(for: task, bucket: section.bucket)
                            }
                        }
                    }
                }

                if !opportunitiesNeedingFollowUp.isEmpty {
                    Section("Needs Follow-up") {
                        ForEach(opportunitiesNeedingFollowUp) { opportunity in
                            Button {
                                sheet = .agent(initialPrompt: createFollowUpPrompt(for: opportunity))
                            } label: {
                                OpportunityNeedsFollowUpRow(opportunity: opportunity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !recentActivity.isEmpty {
                    Section("Recent Activity") {
                        ForEach(recentActivity) { event in
                            ActivitySummaryRow(event: event)
                        }

                        NavigationLink {
                            ActivityLogView()
                        } label: {
                            Label("View Activity Log", systemImage: "clock.arrow.circlepath")
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

    private func followUpButton(for task: FollowUpTask, bucket: FollowUpDueBucket) -> some View {
        Button {
            sheet = .editFollowUp(task)
        } label: {
            FollowUpRow(task: task, bucket: bucket)
        }
        .buttonStyle(.plain)
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
            Button {
                pendingDeleteTask = task
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
        }
        .accessibilityHint("Opens the follow-up editor.")
    }

    private func perform(_ action: (CRMRepository) throws -> Void) {
        do {
            try action(crmRepository)
        } catch {
            actionError = PresentableError(error)
        }
    }

    private func createFollowUpPrompt(for opportunity: Opportunity) -> String {
        var parts = ["Create a follow-up for the opportunity \(opportunity.title)"]
        if !opportunity.company.isEmpty {
            parts.append("at \(opportunity.company)")
        }
        if let contact = opportunity.contact {
            parts.append("with \(contact.fullName)")
        }
        parts.append("Use the existing opportunity and draft a reviewable CRM change.")
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

private struct FollowUpSummary {
    let overdueCount: Int
    let todayCount: Int
    let laterCount: Int

    init(tasks: [FollowUpTask]) {
        var overdueCount = 0
        var todayCount = 0
        var laterCount = 0

        for task in tasks {
            switch FollowUpDueBucket.bucket(for: task) {
            case .overdue:
                overdueCount += 1
            case .today:
                todayCount += 1
            case .upcoming, .noDate:
                laterCount += 1
            }
        }

        self.overdueCount = overdueCount
        self.todayCount = todayCount
        self.laterCount = laterCount
    }
}

private struct FollowUpSection: Identifiable {
    let bucket: FollowUpDueBucket
    let tasks: [FollowUpTask]

    var id: FollowUpDueBucket { bucket }
}

private enum FollowUpDueBucket: CaseIterable, Hashable, Identifiable {
    case overdue
    case today
    case upcoming
    case noDate

    var id: Self { self }

    var sectionTitle: String {
        switch self {
        case .overdue:
            "Overdue"
        case .today:
            "Today"
        case .upcoming:
            "Upcoming"
        case .noDate:
            "No Date"
        }
    }

    var chipTitle: String {
        switch self {
        case .overdue:
            "Overdue"
        case .today:
            "Today"
        case .upcoming:
            "Upcoming"
        case .noDate:
            "No Date"
        }
    }

    var systemImage: String {
        switch self {
        case .overdue:
            "exclamationmark.circle"
        case .today:
            "calendar"
        case .upcoming:
            "calendar.badge.clock"
        case .noDate:
            "calendar.badge.questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .overdue:
            .red
        case .today:
            .orange
        case .upcoming:
            .blue
        case .noDate:
            .secondary
        }
    }

    static func bucket(for task: FollowUpTask, calendar: Calendar = .current) -> FollowUpDueBucket {
        guard let dueDate = task.dueDate else { return .noDate }
        if calendar.isDateInToday(dueDate) {
            return .today
        }
        if dueDate < calendar.startOfDay(for: .now) {
            return .overdue
        }
        return .upcoming
    }
}

private struct FollowUpPrioritySummary: View {
    let summary: FollowUpSummary

    var body: some View {
        HStack(spacing: 10) {
            FollowUpMetricView(
                title: "Overdue",
                value: summary.overdueCount,
                systemImage: "exclamationmark.circle",
                tint: .red
            )
            FollowUpMetricView(
                title: "Today",
                value: summary.todayCount,
                systemImage: "calendar",
                tint: .orange
            )
            FollowUpMetricView(
                title: "Later",
                value: summary.laterCount,
                systemImage: "calendar.badge.clock",
                tint: .blue
            )
        }
        .padding(.vertical, 4)
    }
}

private struct FollowUpMetricView: View {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(value.formatted())
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct FollowUpRow: View {
    let task: FollowUpTask
    let bucket: FollowUpDueBucket

    private var dueText: String? {
        if let dueDate = task.dueDate {
            return dueDate.formatted(date: .abbreviated, time: .omitted)
        }
        return task.dueDateText.nilIfBlank
    }

    private var contextText: String? {
        switch (task.contact, task.opportunity) {
        case let (contact?, opportunity?):
            return "\(contact.fullName) · \(opportunity.title)"
        case let (contact?, nil):
            return contact.fullName
        case let (nil, opportunity?):
            if opportunity.company.isEmpty {
                return opportunity.title
            }
            return "\(opportunity.title) · \(opportunity.company)"
        case (nil, nil):
            return nil
        }
    }

    private var contextIcon: String {
        if task.contact != nil && task.opportunity != nil {
            return "person.text.rectangle"
        }
        if task.contact != nil {
            return "person.crop.circle"
        }
        return "chart.line.uptrend.xyaxis"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: bucket.systemImage)
                .foregroundStyle(bucket.tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    FollowUpDueChip(bucket: bucket)
                }

                if let contextText {
                    Label(contextText, systemImage: contextIcon)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let dueText {
                    Label(dueText, systemImage: "calendar")
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
        .contentShape(Rectangle())
    }
}

private struct FollowUpDueChip: View {
    let bucket: FollowUpDueBucket

    var body: some View {
        Text(bucket.chipTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(bucket.tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(bucket.tint.opacity(0.12), in: Capsule())
    }
}

private struct OpportunityNeedsFollowUpRow: View {
    let opportunity: Opportunity

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(opportunity.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                StageBadge(stage: opportunity.stage)
            }

            if !opportunity.company.isEmpty {
                Text(opportunity.company)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            OpportunityMetaLine(opportunity: opportunity)

            Label("No open follow-up", systemImage: "plus.circle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.blue)
        }
        .padding(.vertical, 5)
    }
}

private struct ActivitySummaryRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.activityIconName)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

private extension OpportunityStage {
    var isActive: Bool {
        switch self {
        case .won, .lost:
            false
        case .lead, .qualified, .proposalNeeded, .proposalSent:
            true
        }
    }
}

private extension ActivityEvent {
    var activityIconName: String {
        entityKind.systemImage
    }
}
