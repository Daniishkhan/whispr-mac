import AppKit
import Foundation

/// Central state machine and glue layer.
///
/// Flow: idle → connecting → recording → finishing → preview → idle.
/// A session can be hold-to-talk (Right ⌥) or toggled (⌃⌥Space / menu).
@MainActor
final class AppState: ObservableObject, @unchecked Sendable {

    enum Phase: Equatable {
        case idle
        case connecting
        case recording
        case finishing
        case preview
    }

    enum SessionKind {
        case hold
        case toggle
    }

    // MARK: - Published UI state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusLine: String = ""
    @Published private(set) var liveText: String = ""
    @Published var previewText: String = ""
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var lastError: String?
    @Published private(set) var hasAPIKey: Bool = false
    @Published private(set) var micAuthorized: Bool = false
    @Published private(set) var accessibilityTrusted: Bool = false
    @Published private(set) var targetAppName: String?
    @Published private(set) var historyItems: [HistoryStore.Entry] = []
    @Published private(set) var connectionTestResult: String?

    // MARK: - Internals

    private let settings = SettingsStore.shared
    private let history = HistoryStore.shared
    private let hotkeys = HotkeyManager()
    private let panel = HUDPanelController()
    private let windows = AppWindows()
    private var assembler = TranscriptAssembler()
    private var client: DeepgramClient?
    private var audio: AudioCapture?
    private var sessionKind: SessionKind = .toggle
    private var eventsTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var finishDeadlineTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var lastTargetApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var didBootstrap = false

    private static let maxSessionSeconds: UInt64 = 300
    private static let finishGraceSeconds: UInt64 = 3

    // MARK: - Derived display values

    var menuBarIconName: String {
        switch phase {
        case .idle: return lastError == nil ? "mic" : "exclamationmark.triangle"
        case .connecting, .recording, .finishing: return "mic.fill"
        case .preview: return "text.bubble"
        }
    }

    var statusText: String {
        switch phase {
        case .idle: return lastError ?? "Ready — hold Right ⌥ or press ⌃⌥Space"
        case .connecting: return "Connecting to Deepgram…"
        case .recording: return "Listening…"
        case .finishing: return "Finishing…"
        case .preview: return "Review your transcript"
        }
    }

    var recordingHintText: String {
        sessionKind == .hold ? "Release Right ⌥ to stop" : "Press ⌃⌥Space to stop"
    }

    var isSessionActive: Bool {
        phase == .connecting || phase == .recording || phase == .finishing
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        historyItems = history.load()
        refreshPermissions()
        wireHotkeys()
        observeFrontmostApp()
        hotkeys.start()

        if !hasAPIKey {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                self?.openSettingsWindow()
            }
        }
    }

    func shutdown() {
        hotkeys.stop()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        cancelSession()
        panel.hide()
    }

    func openSettingsWindow() {
        windows.showSettings(state: self)
    }

    func openHistoryWindow() {
        windows.showHistory(state: self)
    }

    // MARK: - Permissions & settings

    func refreshPermissions() {
        hasAPIKey = !(KeychainStore.loadAPIKey()?.isEmpty ?? true)
        micAuthorized = AudioCapture.permissionGranted
        accessibilityTrusted = Permissions.accessibilityTrusted
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainStore.saveAPIKey(trimmed)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshPermissions()
    }

    func deleteAPIKey() {
        KeychainStore.deleteAPIKey()
        refreshPermissions()
    }

    func testConnection() {
        guard let key = KeychainStore.loadAPIKey(), !key.isEmpty else {
            connectionTestResult = "Save an API key first."
            return
        }
        connectionTestResult = "Connecting…"
        Task {
            let client = DeepgramClient()
            do {
                try client.connect(apiKey: key, keyterms: settings.keytermList, endpointingMs: 800)
            } catch {
                connectionTestResult = "Could not build the Deepgram request."
                return
            }
            let result = await Self.firstMeaningfulEvent(from: client, timeoutSeconds: 10)
            client.cancel()
            connectionTestResult = result
        }
    }

    nonisolated private static func firstMeaningfulEvent(from client: DeepgramClient, timeoutSeconds: UInt64) async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask {
                for await event in client.events {
                    switch event {
                    case .opened:
                        return "✓ Connected — your API key works."
                    case .failed(let message):
                        return message
                    case .closed(_, let reason):
                        return "Connection closed: \(reason ?? "no reason given")"
                    case .text:
                        continue
                    }
                }
                return "No response from Deepgram."
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                return "Timed out waiting for Deepgram."
            }
            let first = await group.next() ?? "Unknown result."
            group.cancelAll()
            return first
        }
    }

    // MARK: - Hotkey wiring

    private func wireHotkeys() {
        hotkeys.onHoldDown = { [weak self] in self?.holdDown() }
        hotkeys.onHoldUp = { [weak self] in self?.holdUp() }
        hotkeys.onToggle = { [weak self] in self?.togglePressed() }
    }

    private func observeFrontmostApp() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }
            Task { @MainActor [weak self] in
                self?.lastTargetApp = app
            }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastTargetApp = frontmost
        }
    }

    // MARK: - Session control (hotkeys & menu)

    private func holdDown() {
        guard phase == .idle else { return }
        startSession(kind: .hold)
    }

    private func holdUp() {
        guard sessionKind == .hold else { return }
        guard phase == .recording || phase == .connecting else { return }
        finishSession()
    }

    private func togglePressed() {
        switch phase {
        case .idle:
            startSession(kind: .toggle)
        case .connecting, .recording:
            finishSession()
        case .finishing, .preview:
            break
        }
    }

    func startFromMenu() {
        guard phase == .idle else { return }
        startSession(kind: .toggle)
    }

    func stopFromMenu() {
        guard phase == .connecting || phase == .recording else { return }
        finishSession()
    }

    // MARK: - Session lifecycle

    private func startSession(kind: SessionKind) {
        lastError = nil
        refreshPermissions()

        guard hasAPIKey, let apiKey = KeychainStore.loadAPIKey() else {
            showError("Add your Deepgram API key in Settings first.")
            openSettingsWindow()
            return
        }

        guard AudioCapture.permissionGranted else {
            if !AudioCapture.permissionDetermined {
                Task { [weak self] in
                    let granted = await AudioCapture.requestPermission()
                    guard let self else { return }
                    self.refreshPermissions()
                    if granted {
                        self.startSession(kind: kind)
                    } else {
                        self.showError("Microphone access was denied.")
                    }
                }
            } else {
                showError("Microphone access is off — enable Whispr in System Settings → Privacy & Security → Microphone.")
            }
            return
        }

        sessionKind = kind
        assembler.reset()
        liveText = ""
        previewText = ""
        micLevel = 0
        phase = .connecting
        statusLine = "Connecting to Deepgram…"
        targetAppName = lastTargetApp?.localizedName

        let newClient = DeepgramClient()
        client = newClient
        do {
            try newClient.connect(apiKey: apiKey, keyterms: settings.keytermList, endpointingMs: 800)
        } catch {
            teardownSession()
            showError("Could not build the Deepgram request.")
            return
        }

        startEventPump(for: newClient)

        let capture = AudioCapture()
        audio = capture
        do {
            let stream = try capture.start()
            audioTask = Task { [weak self] in
                for await chunk in stream {
                    self?.updateMicLevel(chunk)
                    newClient.sendAudio(chunk)
                }
            }
        } catch {
            teardownSession()
            showError(error.localizedDescription)
            return
        }

        panel.showRecording(state: self)

        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxSessionSeconds))
            guard !Task.isCancelled else { return }
            self?.maxDurationReached()
        }
    }

    private func finishSession() {
        guard phase == .recording || phase == .connecting else { return }
        phase = .finishing
        statusLine = "Finishing…"
        micLevel = 0

        audio?.stop()
        audio = nil
        audioTask?.cancel()
        audioTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil

        // Ask Deepgram to flush trailing audio and send final transcripts.
        client?.sendCloseStream()

        finishDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishGraceSeconds))
            guard !Task.isCancelled else { return }
            self?.completeToPreview()
        }
    }

    private func maxDurationReached() {
        guard phase == .recording || phase == .connecting else { return }
        lastError = "Stopped automatically after 5 minutes."
        finishSession()
    }

    /// Abort mid-session with no preview.
    func cancelSession() {
        guard isSessionActive else { return }
        teardownSession()
        assembler.reset()
        liveText = ""
        micLevel = 0
        phase = .idle
        statusLine = ""
        panel.hide()
    }

    private func teardownSession() {
        audio?.stop()
        audio = nil
        audioTask?.cancel()
        audioTask = nil
        maxDurationTask?.cancel()
        maxDurationTask = nil
        finishDeadlineTask?.cancel()
        finishDeadlineTask = nil
        client?.cancel()
        client = nil
        eventsTask?.cancel()
        eventsTask = nil
    }

    // MARK: - Deepgram event handling

    private func startEventPump(for client: DeepgramClient) {
        eventsTask = Task { [weak self] in
            for await event in client.events {
                self?.handleDeepgramEvent(event)
            }
        }
    }

    private func handleDeepgramEvent(_ event: DeepgramClient.Event) {
        switch event {
        case .opened:
            if phase == .connecting {
                phase = .recording
                statusLine = "Listening…"
            }
        case .text(let text):
            handleDeepgramMessage(DeepgramMessage.parse(text))
        case .closed(let code, let reason):
            handleConnectionEnded(detail: reason ?? "close code \(code.rawValue)")
        case .failed(let message):
            handleConnectionEnded(detail: message)
        }
    }

    private func handleDeepgramMessage(_ message: DeepgramMessage) {
        switch message {
        case .results(let isFinal, _, let transcript):
            assembler.apply(isFinal: isFinal, transcript: transcript)
            liveText = assembler.display
        case .metadata:
            // Deepgram's last frame after CloseStream — everything is final now.
            if phase == .finishing {
                completeToPreview()
            }
        case .error(let detail):
            handleConnectionEnded(detail: "Deepgram error: \(detail)")
        case .warning(let detail):
            statusLine = detail
        case .speechStarted, .utteranceEnd, .unknown:
            break
        }
    }

    private func handleConnectionEnded(detail: String) {
        switch phase {
        case .finishing:
            completeToPreview()
        case .connecting:
            teardownSession()
            showError(detail)
        case .recording:
            // Network dropped mid-dictation: salvage whatever we have.
            let hadPartialText = !assembler.display.isEmpty
            audio?.stop()
            audio = nil
            audioTask?.cancel()
            audioTask = nil
            if hadPartialText {
                lastError = "Connection lost (\(detail)) — review what was captured."
                phase = .finishing
                completeToPreview()
            } else {
                teardownSession()
                showError(detail)
            }
        case .idle, .preview:
            break
        }
    }

    private func completeToPreview() {
        guard phase == .finishing else { return }
        finishDeadlineTask?.cancel()
        finishDeadlineTask = nil

        let text = assembler.finish()
        client?.cancel()
        client = nil
        eventsTask?.cancel()
        eventsTask = nil

        if text.isEmpty {
            phase = .idle
            statusLine = ""
            panel.hide()
            panel.showNotice(title: "Nothing transcribed",
                             message: "Deepgram returned no text. Check your mic level while speaking.")
        } else {
            previewText = text
            phase = .preview
            statusLine = "Review and insert"
            panel.showPreview(state: self)
        }
    }

    private func showError(_ message: String) {
        phase = .idle
        statusLine = ""
        lastError = message
        panel.hide()
        panel.showNotice(title: "Whispr", message: message)
    }

    // MARK: - Preview actions

    func confirmInsert() {
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            cancelPreview()
            return
        }
        recordHistory(text)
        phase = .idle
        statusLine = ""
        lastError = nil
        panel.hide()

        let target = lastTargetApp
        Task { [weak self] in
            if let target, !target.isTerminated {
                target.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
                try? await Task.sleep(for: .milliseconds(250))
            }
            let result = TextInserter.insert(text: text)
            if result == .copiedOnly {
                self?.refreshPermissions()
                self?.panel.showNotice(
                    title: "Copied to clipboard",
                    message: "Grant Accessibility (System Settings → Privacy & Security → Accessibility) so Whispr can paste directly."
                )
            }
        }
    }

    func copyPreview() {
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            cancelPreview()
            return
        }
        recordHistory(text)
        TextInserter.copyToClipboard(text: text)
        phase = .idle
        statusLine = ""
        panel.hide()
        panel.showNotice(title: "Copied", message: "Transcript copied to the clipboard.")
    }

    func cancelPreview() {
        previewText = ""
        phase = .idle
        statusLine = ""
        lastError = nil
        panel.hide()
    }

    // MARK: - History

    private func recordHistory(_ text: String) {
        guard settings.historyEnabled else { return }
        historyItems = history.add(text)
    }

    func copyHistoryItem(_ entry: HistoryStore.Entry) {
        TextInserter.copyToClipboard(text: entry.text)
    }

    func clearHistory() {
        history.clear()
        historyItems = []
    }

    // MARK: - Self tests (CLI entry points)

    /// `--selftest-connection`: open the websocket, report, exit.
    func runConnectionSelfTest() {
        testConnection()
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { exit(2) }
                if let result = self.connectionTestResult, result != "Connecting…" {
                    dbg("selftest-connection: \(result)")
                    exit(result.hasPrefix("✓") ? 0 : 1)
                }
            }
        }
    }

    /// `--selftest-mic=SECONDS`: capture from the real mic, report signal, exit.
    func runMicSelfTest(seconds: Int) {
        Task { [weak self] in
            if !AudioCapture.permissionGranted {
                let granted = await AudioCapture.requestPermission()
                if !granted {
                    dbg("selftest-mic: microphone permission denied")
                    exit(1)
                }
            }
            let capture = AudioCapture()
            do {
                let stream = try capture.start()
                let deadline = ContinuousClock.now + .seconds(seconds)
                var chunks = 0
                var bytes = 0
                var peak: Float = 0
                for await chunk in stream {
                    chunks += 1
                    bytes += chunk.count
                    peak = max(peak, RMSLevel.compute(chunk))
                    if ContinuousClock.now >= deadline { break }
                }
                capture.stop()
                let peakText = String(format: "%.3f", peak)
                dbg("selftest-mic: \(chunks) chunks, \(bytes) bytes, peak level \(peakText)")
                self?.refreshPermissions()
                exit(chunks > 0 ? 0 : 2)
            } catch {
                dbg("selftest-mic: failed to start: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// `--selftest-file=PATH`: run a real session, but stream PCM from a file
    /// instead of the microphone. Ends in the normal preview panel.
    func runFileSelfTest(path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            let chunks = try FileAudioStreamer.loadChunks(url: url, chunkDurationMs: 100)
            dbg("selftest-file: \(chunks.count) chunks (\(chunks.count / 10)s of audio)")
            startSessionFromFile(chunks: chunks)
        } catch {
            dbg("selftest-file: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Mirrors `startSession`, swapping the mic for file chunks. Everything
    /// else (websocket, assembler, HUD, finish, preview) is production code.
    private func startSessionFromFile(chunks: [Data]) {
        guard let apiKey = KeychainStore.loadAPIKey() else {
            dbg("selftest-file: no API key in Keychain")
            exit(1)
        }

        sessionKind = .toggle
        assembler.reset()
        liveText = ""
        previewText = ""
        phase = .connecting
        statusLine = "Connecting to Deepgram…"
        targetAppName = "Self Test"

        let newClient = DeepgramClient()
        client = newClient
        do {
            try newClient.connect(apiKey: apiKey, keyterms: settings.keytermList, endpointingMs: 800)
        } catch {
            dbg("selftest-file: could not build request")
            exit(1)
        }

        startEventPump(for: newClient)
        panel.showRecording(state: self)

        audioTask = Task { [weak self] in
            for chunk in chunks {
                if Task.isCancelled { break }
                newClient.sendAudio(chunk)
                self?.updateMicLevel(chunk)
                try? await Task.sleep(for: .milliseconds(90))
            }
            try? await Task.sleep(for: .milliseconds(400))
            self?.finishSession()
        }
    }

    // MARK: - Helpers

    private func updateMicLevel(_ chunk: Data) {
        let level = RMSLevel.compute(chunk)
        micLevel = micLevel * 0.7 + level * 0.3
    }
}
