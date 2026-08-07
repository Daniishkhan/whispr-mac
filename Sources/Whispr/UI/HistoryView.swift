import SwiftUI

struct HistoryView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.historyItems.isEmpty {
                ContentUnavailableView(
                    "No Transcripts Yet",
                    systemImage: "text.quote",
                    description: Text("Inserted transcripts will appear here.")
                )
            } else {
                List(state.historyItems) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text)
                                .lineLimit(3)
                                .textSelection(.enabled)
                            Text(entry.date, format: .dateTime.day().month().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            state.copyHistoryItem(entry)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Clear All", role: .destructive) {
                    state.clearHistory()
                }
                .disabled(state.historyItems.isEmpty)
            }
        }
    }
}
