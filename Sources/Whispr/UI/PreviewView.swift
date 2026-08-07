import SwiftUI

/// Editable transcript preview shown after dictation stops.
/// Nothing is inserted anywhere until the user explicitly confirms.
struct PreviewView: View {
    @ObservedObject var state: AppState
    @FocusState private var editorFocused: Bool

    private var trimmedText: String {
        state.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Preview")
                    .font(.headline)
                if let target = state.targetAppName {
                    Label("will insert into \(target)", systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let error = state.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            TextEditor(text: $state.previewText)
                .font(.system(size: 16))
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Text("\(trimmedText.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.accessibilityTrusted {
                    Label("No Accessibility — Insert copies instead",
                          systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Cancel") {
                    state.cancelPreview()
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button("Copy") {
                    state.copyPreview()
                }
                .disabled(trimmedText.isEmpty)
                Button("Insert ⌘↵") {
                    state.confirmInsert()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(trimmedText.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
        .onAppear {
            editorFocused = true
        }
    }
}
