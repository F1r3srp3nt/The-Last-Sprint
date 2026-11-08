import RelayCore
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var channel: LogChannel?
    @State private var search = ""

    private var filtered: [LogEvent] {
        model.logEntries.reversed().filter { event in
            (channel == nil || event.channel == channel)
                && (search.isEmpty || event.message.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                SectionHeader(title: "Activity",
                              subtitle: "Append-only record of what Relay did. Credentials are redacted before anything is stored.")
                Button { model.exportLog() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            }
            HStack {
                Picker("Channel", selection: $channel) {
                    Text("All").tag(LogChannel?.none)
                    ForEach(LogChannel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(LogChannel?.some($0)) }
                }
                .frame(width: 220)
                TextField("Filter", text: $search).textFieldStyle(.ds)
                Text("\(filtered.count) entries").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            List(filtered) { event in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(event.timestamp, format: .dateTime.hour().minute().second())
                        .font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                    Text(event.channel.rawValue).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                        .frame(width: 72, alignment: .leading)
                    StatusPill(text: event.kind.rawValue, color: Theme.color(event.kind))
                    if let mode = event.mode {
                        Text(mode.label).font(.caption2.bold())
                            .foregroundStyle(mode == .simulation ? Theme.simulation : Theme.warning)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.message).font(.callout).textSelection(.enabled)
                        if !event.details.isEmpty {
                            Text(event.details.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
        }
        .padding(18)
    }
}
