import RelayCore
import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newTitle = ""

    private struct TaskGroup: Identifiable {
        let title: String
        let tasks: [RelayTask]
        var id: String { title }
    }

    private var groups: [TaskGroup] {
        let attention = model.tasks.filter { $0.state == .needsAttention || $0.state == .awaitingApproval }
        let active = model.tasks.filter { $0.state == .queued || $0.state == .inProgress }
        let done = model.tasks.filter { $0.state.isTerminal }
        return [TaskGroup(title: "Needs attention", tasks: attention),
                TaskGroup(title: "Queued and in progress", tasks: active),
                TaskGroup(title: "Finished", tasks: done.reversed())]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Tasks",
                          subtitle: "Everything Relay was asked to do or could not resolve. Every change is logged in Activity.")
            HStack {
                TextField("New task", text: $newTitle)
                    .textFieldStyle(.ds)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.tasks.isEmpty {
                        Text("No tasks yet. Escalated questions, approvals and tasks you add appear here.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(groups) { group in
                        if !group.tasks.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(group.title) · \(group.tasks.count)").font(.headline).foregroundStyle(Theme.textSecondary)
                                ForEach(group.tasks) { task in TaskRow(task: task) }
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        model.addTask(title)
        newTitle = ""
    }
}

struct TaskRow: View {
    @EnvironmentObject private var model: AppModel
    let task: RelayTask

    var body: some View {
        Panel(padding: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.body.weight(.medium)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                    if !task.detail.isEmpty {
                        Text(task.detail).font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(3)
                    }
                    HStack(spacing: 8) {
                        Text(task.source.rawValue.capitalized).font(.caption).foregroundStyle(Theme.textSecondary)
                        Text(task.createdAt, style: .time).font(.caption).foregroundStyle(Theme.textSecondary)
                        if let last = task.history.last, !last.note.isEmpty {
                            Text("· \(last.note)").font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                }
                Spacer()
                StatusPill(text: task.state.displayName, color: Theme.color(task.state))
                if !task.state.allowedNext.isEmpty {
                    Menu("Change") {
                        ForEach(task.state.allowedNext.sorted { $0.rawValue < $1.rawValue }, id: \.self) { state in
                            Button(state.displayName) { model.transition(task, to: state) }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
            }
        }
    }
}
