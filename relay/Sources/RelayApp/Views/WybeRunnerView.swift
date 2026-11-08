import RelayCore
import SwiftUI

struct WybeRunnerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Wybe Runner",
                          subtitle: "Autonomous Night Shift agent. The headless runner works without this window: relay-runner wybe-sim.")
            ModeBanner(mode: .simulation,
                       detail: "Relay's own simulator with invented \u{201C}sim.\u{201D} commands. Scores are not challenge results.")
            liveStatus
            controls
            HStack(alignment: .top, spacing: 14) {
                // Scrolls on its own, so a long task list never makes the page taller than the window.
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        observationPanel
                        reportsPanel
                    }
                }
                .frame(width: 340)
                historyPanel
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var liveStatus: some View {
        Panel(padding: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live mode unavailable").font(.callout.weight(.semibold))
                    Text("The real Wybe command list, endpoints and scoring have not been obtained. Relay will not guess them. "
                         + "Team registration via the organisers' join page is needed first (see docs/WYBE.md).")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Stepper("Seed \(model.wybeSeed)", value: $model.wybeSeed, in: 0...9_999).fixedSize()
            Stepper("Shifts \(model.wybeShifts)", value: $model.wybeShifts, in: 1...10).fixedSize()
            Picker("Faults", selection: $model.wybeFaults) {
                Text("None").tag("none")
                Text("Typical").tag("typical")
                Text("Harsh").tag("harsh")
            }
            .pickerStyle(.segmented).frame(width: 220)
            Spacer()
            if model.wybeRunning {
                ProgressView().controlSize(.small)
                Button(role: .destructive) { model.stopSimulation() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(DSPrimaryButtonStyle(tone: .danger))
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { model.startSimulation() } label: { Label("Run simulation", systemImage: "play.fill") }
                    .buttonStyle(.dsPrimary)
            }
        }
    }

    private var observationPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Latest observation").font(.headline)
                if let obs = model.wybeObservation {
                    Text("Time \(obs.time) / \(obs.shiftEndsAt.map { "\($0)" } ?? "?") min · robot at \(obs.robotLocation ?? "?")")
                        .font(.callout.monospaced())
                    Text("Carrying: \(obs.carrying.isEmpty ? "nothing" : obs.carrying.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    ForEach(obs.tasks) { task in
                        HStack(spacing: 6) {
                            Text(task.id).font(.caption.monospaced()).frame(width: 30, alignment: .leading)
                            Text(task.summary).font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            if obs.locationFlags[task.destination]?.isEmpty == false {
                                Text("DND").font(.caption2.bold()).foregroundStyle(Theme.warning)
                            }
                            if task.priority == "urgent" { Text("urgent").font(.caption2).foregroundStyle(Theme.warning) }
                            Text(task.status.rawValue).font(.caption2)
                                .foregroundStyle(task.status == .open ? Theme.textSecondary : Theme.success)
                        }
                    }
                } else {
                    Text("Not running.").foregroundStyle(Theme.textSecondary)
                }
                if !model.wybeDecision.isEmpty {
                    Divider()
                    Text("Decision").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    Text(model.wybeDecision).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var reportsPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shift results").font(.headline)
                if model.wybeReports.isEmpty { Text("None yet.").foregroundStyle(Theme.textSecondary) }
                ForEach(Array(model.wybeReports.enumerated()), id: \.offset) { index, report in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shift \(index + 1): \(report.score?.displayText ?? "no score")").font(.caption)
                        Text(report.stopReason).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                }
                if let average = model.simulatedAverage {
                    Divider()
                    Text("Average: \(average.displayText)").font(.caption.weight(.semibold)).foregroundStyle(Theme.simulation)
                }
            }
        }
    }

    private var historyPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Action history").font(.headline)
                if model.wybeRecords.isEmpty {
                    Text("No actions yet. Run the simulation to see each decision, attempt and result here.")
                        .font(.callout).foregroundStyle(Theme.textSecondary)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.wybeRecords) { record in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("#\(record.sequence)").font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                                        .frame(width: 34, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.request.displayText).font(.callout.monospaced())
                                        Text(record.message + (record.attempts > 1 ? " · \(record.attempts) attempts" : ""))
                                            .font(.caption).foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer()
                                    StatusPill(text: record.status.rawValue, color: Theme.color(record.status))
                                }
                                .id(record.id)
                            }
                        }
                    }
                    .onChange(of: model.wybeRecords.count) { _, _ in
                        if let last = model.wybeRecords.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
