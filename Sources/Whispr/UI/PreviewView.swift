import SwiftUI

/// Editable transcript preview shown after dictation stops.
/// Nothing is inserted anywhere until the user explicitly confirms.
struct PreviewView: View {
    @ObservedObject var state: AppState
    @FocusState private var editorFocused: Bool
    @FocusState private var focusedQuestion: UUID?

    private var trimmedText: String {
        state.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if state.hasBothPreviewVersions {
                Picker("Version", selection: Binding(
                    get: { state.selectedPreviewVersion },
                    set: { state.selectPreviewVersion($0) }
                )) {
                    ForEach(AppState.PreviewVersion.allCases) { version in
                        Text(version.label).tag(version)
                    }
                }
                .pickerStyle(.segmented)
            }

            if state.hasClarifications {
                clarificationSection
            }

            if state.selectedPreviewVersion == .polished, !state.polishChanges.isEmpty {
                polishChangesRow
            }

            TextEditor(text: $state.previewText)
                .font(.system(size: 16))
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .disabled(state.polishLoading)

            footer
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(8)
        .onAppear {
            if let first = state.clarificationItems.first?.id {
                focusedQuestion = first
            } else {
                editorFocused = true
            }
        }
        .onChange(of: state.clarificationItems.map(\.id)) { _, questionIDs in
            // Answer edits mutate the items but do not change their identities.
            // Only focus when a new question list appears.
            if let first = questionIDs.first {
                focusedQuestion = first
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Preview")
                .font(.headline)
            if state.polishedText != nil {
                Label("Polished", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let target = state.targetAppName {
                Label("will insert into \(target)", systemImage: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    /// Names the polish step swapped in. A wrong "correction" is easy to miss
    /// in a paragraph, so each one is listed and can be put back with a click.
    private var polishChangesRow: some View {
        HStack(spacing: 6) {
            Text("Polish changed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.polishChanges, id: \.self) { change in
                        Button {
                            state.revertPolishChange(change)
                        } label: {
                            Text("\(change.from) → \(change.to)")
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Put back “\(change.from)”")
                        .disabled(state.polishLoading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var clarificationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("A little clarification needed", systemImage: "questionmark.bubble")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if state.polishLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.clarificationItems) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.question)
                                .font(.caption)
                            TextField("Answer, or leave blank to skip", text: state.clarificationAnswerBinding(for: item.id))
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedQuestion, equals: item.id)
                                .disabled(state.polishLoading)
                        }
                    }
                }
            }
            .frame(maxHeight: 145)
            HStack {
                Text("Blank answers use a best-effort assumption.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip All") {
                    state.skipClarifications()
                }
                .disabled(state.polishLoading)
                Button("Submit Answers") {
                    state.submitClarifications()
                }
                .disabled(state.polishLoading)
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = state.previewWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let error = state.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            HStack {
                Text("\(trimmedText.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !state.accessibilityTrusted {
                    Label("No Accessibility — Insert copies instead", systemImage: "lock.shield")
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
                .disabled(trimmedText.isEmpty || state.polishLoading)
                Button("Insert ⌘↵") {
                    state.confirmInsert()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(trimmedText.isEmpty || state.polishLoading)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
