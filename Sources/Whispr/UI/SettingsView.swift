import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    @State private var apiKeyInput = ""
    @State private var polishAPIKeyInput = ""
    @State private var keytermsText = SettingsStore.shared.keytermsText
    @State private var historyEnabled = SettingsStore.shared.historyEnabled

    private let permissionPoll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var keytermCount: Int {
        SettingsStore.shared.keytermList.count
    }

    var body: some View {
        Form {
            Section {
                SecureField("Paste your Deepgram API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        state.saveAPIKey(apiKeyInput)
                        apiKeyInput = ""
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Test Connection") {
                        state.testConnection()
                    }
                    .disabled(!state.hasDeepgramAPIKey)
                    if state.hasDeepgramAPIKey {
                        Button("Remove Key", role: .destructive) {
                            state.deleteAPIKey()
                        }
                    }
                }
                if state.hasDeepgramAPIKey {
                    Label("Key saved in macOS Keychain", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let result = state.connectionTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Link("Get an API key at console.deepgram.com →",
                     destination: URL(string: "https://console.deepgram.com/signup")!)
                    .font(.caption)
            } header: {
                Text("Deepgram")
            }

            Section {
                Toggle("Polish dictated text before preview", isOn: Binding(
                    get: { state.polishEnabled },
                    set: { state.setPolishEnabled($0) }
                ))
                .disabled(state.phase != .idle)

                TextField("Base URL", text: Binding(
                    get: { state.llmBaseURL },
                    set: { state.setLLMBaseURL($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

                TextField("Model", text: Binding(
                    get: { state.llmModel },
                    set: { state.setLLMModel($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

                Picker("Reasoning effort", selection: Binding(
                    get: { state.llmReasoningEffort },
                    set: { state.setLLMReasoningEffort($0) }
                )) {
                    ForEach(PolishReasoningEffort.allCases, id: \.self) { effort in
                        Text(effort.rawValue).tag(effort)
                    }
                }

                SecureField("Paste your OpenAI-compatible API key", text: $polishAPIKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save") {
                        state.savePolishAPIKey(polishAPIKeyInput)
                        polishAPIKeyInput = ""
                    }
                    .disabled(polishAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Test Connection") {
                        state.testPolishConnection()
                    }
                    .disabled(!state.hasPolishAPIKey)
                    if state.hasPolishAPIKey {
                        Button("Remove Key", role: .destructive) {
                            state.deletePolishAPIKey()
                        }
                    }
                }
                if state.hasPolishAPIKey {
                    Label("Key saved in macOS Keychain", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let result = state.polishConnectionTestResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Effective host: \(state.effectiveLLMHost)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("When polish is on, dictated transcripts and Vocabulary keyterms are sent to this configured endpoint. Turn it off for zero LLM traffic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Get an OpenAI API key →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            } header: {
                Text("LLM Polish")
            }

            Section {
                TextEditor(text: $keytermsText)
                    .font(.system(size: 13))
                    .frame(height: 120)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onChange(of: keytermsText) { _, newValue in
                        SettingsStore.shared.keytermsText = newValue
                    }
                Text("\(keytermCount)/100 keyterms — one per line. These are boosted during recognition and used as LLM polish glossary context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Vocabulary (Nova-3 keyterms)")
            }

            Section {
                Label("Hold **Right ⌥** to talk — release to stop.", systemImage: "hand.raised")
                Label("Press **⌃⌥Space** to toggle hands-free dictation.", systemImage: "keyboard")
                Label("Nothing is typed until you press **Insert**. Whispr never presses Return.", systemImage: "lock.shield")
            } header: {
                Text("How to dictate")
            }

            Section {
                Toggle("Save transcript history on this Mac", isOn: $historyEnabled)
                    .onChange(of: historyEnabled) { _, newValue in
                        SettingsStore.shared.historyEnabled = newValue
                    }
                HStack {
                    Text("\(state.historyItems.count) entries stored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…", role: .destructive) {
                        state.clearHistory()
                    }
                    .disabled(state.historyItems.isEmpty)
                }
            } header: {
                Text("History")
            }

            Section {
                HStack {
                    Label("Microphone", systemImage: "mic")
                    Spacer()
                    if state.micAuthorized {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Settings") {
                            Permissions.openMicrophoneSettings()
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    Label("Accessibility (for auto-insert)", systemImage: "hand.point.up.left")
                    Spacer()
                    if state.accessibilityTrusted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") {
                            Permissions.requestAccessibilityPrompt()
                            Permissions.openAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                }
                Text("Without Accessibility, Whispr copies the transcript to your clipboard instead of pasting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Permissions")
            }

            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 780)
        .onReceive(permissionPoll) { _ in
            state.refreshPermissions()
        }
    }
}
