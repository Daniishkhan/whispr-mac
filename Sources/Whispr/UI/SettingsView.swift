import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    @State private var apiKeyInput = ""
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
                    .disabled(!state.hasAPIKey)
                    if state.hasAPIKey {
                        Button("Remove Key", role: .destructive) {
                            state.deleteAPIKey()
                        }
                    }
                }
                if state.hasAPIKey {
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
                Text("\(keytermCount)/100 keyterms — one per line. These are boosted during recognition (names, jargon, project terms).")
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
        .frame(width: 540, height: 640)
        .onReceive(permissionPoll) { _ in
            state.refreshPermissions()
        }
    }
}
