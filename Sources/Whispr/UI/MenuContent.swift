import SwiftUI

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        Text(state.statusText)
            .font(.callout)

        Divider()

        if state.phase == .idle {
            Button("Start Dictating  ⌃⌥Space") {
                state.startFromMenu()
            }
        } else if state.isSessionActive {
            Button("Stop Dictating") {
                state.stopFromMenu()
            }
        }

        if !state.historyItems.isEmpty {
            Menu("Recent") {
                ForEach(state.historyItems.prefix(5)) { entry in
                    Button(entry.text.truncated(to: 48)) {
                        state.copyHistoryItem(entry)
                    }
                }
            }
        }

        Divider()

        Button("History…") {
            state.openHistoryWindow()
        }
        Button("Settings…") {
            state.openSettingsWindow()
        }

        Divider()

        Button("Quit Whispr") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
