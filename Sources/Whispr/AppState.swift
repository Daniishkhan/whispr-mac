import AppKit
import Foundation
import SwiftUI

/// Central state machine and glue layer.
///
/// Flow: idle → connecting → recording → finishing → polishing? → preview → idle.
/// A session can be hold-to-talk (Right ⌥) or toggled (⌃⌥Space / menu).
@MainActor
final class AppState: ObservableObject, @unchecked Sendable {

    enum Phase: Equatable {
        case idle
        case connecting
        case recording
        case finishing
        case polishing
        case preview
    }

    enum SessionKind {
        case hold
        case toggle
    }

    enum PreviewVersion: String, CaseIterable, Identifiable {
        case polished
        case raw

        var id: String { rawValue }
        var label: String { self == .polished ? "Polished" : "Raw" }
    }

    struct ClarificationItem: Identifiable, Equatable {
        let id = UUID()
        let question: String
        var answer: String = ""
    }

    // MARK: - Published UI state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusLine: String = ""
    @Published private(set) var liveText: String = ""
    @Published var previewText: String = ""
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var lastError: String?
    @Published private(set) var previewWarning: String?
    @Published private(set) var hasDeepgramAPIKey: Bool = false
    @Published private(set) var hasPolishAPIKey: Bool = false
    @Published private(set) var micAuthorized: Bool = false
    @Published private(set) var accessibilityTrusted: Bool = false
    @Published private(set) var targetAppName: String?
    @Published private(set) var historyItems: [HistoryStore.Entry] = []
    @Published private(set) var connectionTestResult: String?
    @Published private(set) var polishConnectionTestResult: String?
    @Published private(set) var polishEnabled: Bool
    @Published private(set) var llmBaseURL: String
    @Published private(set) var llmModel: String
    @Published private(set) var llmReasoningEffort: PolishReasoningEffort
    @Published private(set) var rawTranscript: String = ""
    @Published private(set) var polishedText: String?
    @Published private(set) var selectedPreviewVersion: PreviewVersion = .raw
    @Published private(set) var clarificationItems: [ClarificationItem] = []
    @Published private(set) var polishLoading = false
    /// Names the polish step swapped in, for the preview to point out.
    @Published private(set) var polishChanges: [TextDiff.Change] = []
    @Published private(set) var projectVocabularyEnabled: Bool
    @Published private(set) var projectFoldersText: String
    @Published private(set) var projectVocabularySummary: String = ""
    @Published private(set) var learnedTermsText: String

    // MARK: - Internals

    private let settings = SettingsStore.shared
    private let history = HistoryStore.shared
    private let hotkeys = HotkeyManager()
    private let panel = HUDPanelController()
    private let windows = AppWindows()
    private let vocabulary = ProjectVocabularyService()
    private let injectedPolishService: (any PolishService)?
    private var polishFlow: PolishFlowController?
    private var polishTask: Task<Void, Never>?
    private var assembler = TranscriptAssembler()
    private var client: DeepgramClient?
    private var audio: AudioCapture?
    private var sessionKind: SessionKind = .toggle
    private var eventsTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var finishDeadlineTask: Task<Void, Never>?
    private var maxDurationTask: Task<Void, Never>?
    private var lastTargetApp: NSRunningApplication?
    private var sessionTargetApp: NSRunningApplication?
    private var rawPreviewText = ""
    private var polishedPreviewText = ""
    private var workspaceObserver: NSObjectProtocol?
    private var didBootstrap = false
    private var sessionUsedAutomaticKeyterms = false
    private var retriedWithoutAutomaticKeyterms = false
    /// Set when Deepgram refused a connection that carried learned or project
    /// keyterms; they stay out of recognition until the app is relaunched.
    private var automaticKeytermsSuspended = false
    private var finishStartedAt: ContinuousClock.Instant?
    private var polishStartedAt: ContinuousClock.Instant?
    private var sessionTimings = HistoryStore.Timings()

    private static let maxSessionSeconds: UInt64 = 300
    private static let finishGraceSeconds: UInt64 = 3

    init(polishService: (any PolishService)? = nil) {
        injectedPolishService = polishService
        polishEnabled = SettingsStore.shared.polishEnabled
        llmBaseURL = SettingsStore.shared.llmBaseURL
        llmModel = SettingsStore.shared.llmModel
        llmReasoningEffort = SettingsStore.shared.llmReasoningEffort
        projectVocabularyEnabled = SettingsStore.shared.projectVocabularyEnabled
        projectFoldersText = SettingsStore.shared.projectFoldersText
        learnedTermsText = SettingsStore.shared.learnedTermsText
    }

    // MARK: - Derived display values

    var menuBarIconName: String {
        switch phase {
        case .idle: return lastError == nil ? "mic" : "exclamationmark.triangle"
        case .connecting, .recording, .finishing: return "mic.fill"
        case .polishing: return "sparkles"
        case .preview: return "text.bubble"
        }
    }

    var statusText: String {
        switch phase {
        case .idle: return lastError ?? "Ready — hold Right ⌥ or press ⌃⌥Space"
        case .connecting: return "Connecting to Deepgram…"
        case .recording: return "Listening…"
        case .finishing: return "Finishing…"
        case .polishing: return "Polishing…"
        case .preview: return polishLoading ? "Applying clarification…" : "Review your transcript"
        }
    }

    var recordingHintText: String {
        sessionKind == .hold ? "Release Right ⌥ to stop" : "Press ⌃⌥Space to stop"
    }

    /// Polishing intentionally is not active dictation: the menu must not show
    /// a misleading Stop button while the microphone is already stopped.
    var isSessionActive: Bool {
        phase == .connecting || phase == .recording || phase == .finishing
    }

    var hasBothPreviewVersions: Bool {
        polishedText != nil && !rawTranscript.isEmpty
    }

    var hasClarifications: Bool {
        !clarificationItems.isEmpty
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        historyItems = history.load()
        refreshPermissions()
        wireHotkeys()
        vocabulary.onChange = { [weak self] in self?.updateProjectVocabularySummary() }
        observeFrontmostApp()
        refreshProjectVocabulary()
        hotkeys.start()

        if !hasDeepgramAPIKey {
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
        cancelPolish()
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
        hasDeepgramAPIKey = !(KeychainStore.loadAPIKey()?.isEmpty ?? true)
        hasPolishAPIKey = !(KeychainStore.loadPolishAPIKey()?.isEmpty ?? true)
        micAuthorized = AudioCapture.permissionGranted
        accessibilityTrusted = Permissions.accessibilityTrusted
    }

    func setPolishEnabled(_ enabled: Bool) {
        // A session snapshots the toggle at completion; changing it mid-flow
        // could otherwise start or continue paid resolution traffic unexpectedly.
        guard phase == .idle else { return }
        polishEnabled = enabled
        settings.polishEnabled = enabled
    }

    func setLLMBaseURL(_ value: String) {
        llmBaseURL = value
        settings.llmBaseURL = value
    }

    func setLLMModel(_ value: String) {
        llmModel = value
        settings.llmModel = value
    }

    func setLLMReasoningEffort(_ effort: PolishReasoningEffort) {
        llmReasoningEffort = effort
        settings.llmReasoningEffort = effort
    }

    func setProjectVocabularyEnabled(_ enabled: Bool) {
        projectVocabularyEnabled = enabled
        settings.projectVocabularyEnabled = enabled
        if enabled {
            refreshProjectVocabulary(force: true)
        } else {
            vocabulary.clear()
        }
    }

    /// Saved as typed; picked up the next time the target app changes or a
    /// dictation starts, rather than re-reading folders on every keystroke.
    func setProjectFoldersText(_ value: String) {
        projectFoldersText = value
        settings.projectFoldersText = value
    }

    func setLearnedTermsText(_ value: String) {
        learnedTermsText = value
        settings.learnedTermsText = value
    }

    private func refreshProjectVocabulary(force: Bool = false) {
        guard projectVocabularyEnabled else { return }
        vocabulary.refresh(for: lastTargetApp, pinnedFolders: settings.projectFolderList, force: force)
    }

    /// The word lists for the next request: the Vocabulary from Settings,
    /// terms learned from corrections, and names from the current project.
    private func vocabularyLists(automaticKeyterms: Bool = true) -> VocabularyLists {
        VocabularyBuilder.build(
            manual: settings.keytermList,
            learned: settings.learnedTermList,
            project: projectVocabularyEnabled ? vocabulary.current : [],
            automaticKeyterms: automaticKeyterms && !automaticKeytermsSuspended
        )
    }

    private func updateProjectVocabularySummary() {
        let projects = vocabulary.current
        guard !projects.isEmpty else {
            projectVocabularySummary = ""
            return
        }
        let lists = vocabularyLists()
        projectVocabularySummary = projects.map(\.name).joined(separator: ", ")
            + " — \(lists.automaticKeytermCount) recognition terms, \(lists.glossary.count) glossary terms"
    }

    private static func isDictionaryWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds) * 1_000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    var effectiveLLMHost: String {
        PolishClient.validatedBaseURL(llmBaseURL)?.host ?? "Invalid HTTPS URL"
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

    func savePolishAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainStore.savePolishAPIKey(trimmed)
            previewWarning = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshPermissions()
    }

    func deletePolishAPIKey() {
        KeychainStore.deletePolishAPIKey()
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

    func testPolishConnection() {
        guard let key = KeychainStore.loadPolishAPIKey(), !key.isEmpty else {
            polishConnectionTestResult = "Save an API key first."
            return
        }
        polishConnectionTestResult = "Connecting…"
        do {
            let client = try PolishClient(configuration: polishConfiguration(apiKey: key))
            Task { [weak self] in
                do {
                    _ = try await client.initial(transcript: "Please correct this harmless test sentence.", glossary: [])
                    self?.polishConnectionTestResult = "✓ Connected — your API key works."
                } catch {
                    self?.polishConnectionTestResult = error.localizedDescription
                }
            }
        } catch {
            polishConnectionTestResult = error.localizedDescription
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
        hotkeys.onTemporaryEscape = { [weak self] in self?.cancelPolish() }
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
                self?.refreshProjectVocabulary()
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
        case .finishing, .polishing, .preview:
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
        previewWarning = nil
        refreshPermissions()

        guard hasDeepgramAPIKey, let apiKey = KeychainStore.loadAPIKey() else {
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
        clearPreviewState()
        micLevel = 0
        phase = .connecting
        statusLine = "Connecting to Deepgram…"
        sessionTargetApp = lastTargetApp
        targetAppName = sessionTargetApp?.localizedName
        sessionTimings = HistoryStore.Timings()
        finishStartedAt = nil
        polishStartedAt = nil
        retriedWithoutAutomaticKeyterms = false

        // Recognition needs its keyterms now, so it gets whatever project
        // vocabulary is already resolved; the refresh started here is for the
        // polish step a few seconds from now.
        let lists = vocabularyLists()
        sessionUsedAutomaticKeyterms = lists.automaticKeytermCount > 0
        refreshProjectVocabulary(force: true)

        let newClient = DeepgramClient()
        client = newClient
        do {
            try newClient.connect(apiKey: apiKey, keyterms: lists.keyterms, endpointingMs: 800)
        } catch {
            teardownSession()
            showError("Could not build the Deepgram request.")
            return
        }

        startEventPump(for: newClient)

        let capture = AudioCapture()
        audio = capture
        capture.onFailure = { [weak self, weak capture] error in
            guard let self, let capture, self.audio === capture else { return }
            self.handleMicrophoneLost(error.localizedDescription)
        }
        do {
            let stream = try capture.start()
            audioTask = Task { [weak self] in
                for await chunk in stream {
                    self?.updateMicLevel(chunk)
                    // Through `client`, not the one captured here: a session
                    // may reconnect without its automatic keyterms.
                    self?.client?.sendAudio(chunk)
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

        // Finalize makes Deepgram transcribe what it has buffered right away
        // and flag the last result, so the preview does not have to wait for
        // the stream to wind down. CloseStream and the deadline stay as
        // fallbacks for when that flag never comes.
        finishStartedAt = .now
        client?.sendFinalize()
        client?.sendCloseStream()

        finishDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishGraceSeconds))
            guard !Task.isCancelled else { return }
            self?.completeToPreview(reason: "timeout")
        }
    }

    private func maxDurationReached() {
        guard phase == .recording || phase == .connecting else { return }
        lastError = "Stopped automatically after 5 minutes."
        finishSession()
    }

    /// The input device changed mid-dictation and capture could not be
    /// restarted. Keep whatever was already transcribed rather than leaving
    /// the HUD "listening" to a dead microphone.
    private func handleMicrophoneLost(_ detail: String) {
        guard phase == .recording || phase == .connecting else { return }
        if assembler.display.isEmpty {
            teardownSession()
            showError(detail)
        } else {
            lastError = "\(detail) — review what was captured."
            finishSession()
        }
    }

    /// Abort recording/finishing with no preview.
    func cancelSession() {
        guard isSessionActive else { return }
        teardownSession()
        assembler.reset()
        liveText = ""
        micLevel = 0
        phase = .idle
        statusLine = ""
        sessionTargetApp = nil
        panel.hide()
    }

    /// Cancels either initial polish or an in-preview resolution call.
    func cancelPolish() {
        guard phase == .polishing || (phase == .preview && polishLoading) else { return }
        polishTask?.cancel()
        polishTask = nil
        let flow = polishFlow
        Task { await flow?.cancel() }
        polishFlow = nil
        polishLoading = false
        clarificationItems = []
        hotkeys.unregisterTemporaryEscape()
        let cancellingInitial = phase == .polishing
        if cancellingInitial {
            clearPreviewState()
            phase = .idle
            statusLine = ""
            sessionTargetApp = nil
            panel.hide()
        } else {
            // The preview is already active, so Esc cancels the session. Any
            // late response is ignored because the task and flow were invalidated.
            clearPreviewState()
            phase = .idle
            statusLine = ""
            sessionTargetApp = nil
            panel.hide()
        }
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
                if retriedWithoutAutomaticKeyterms, !automaticKeytermsSuspended {
                    automaticKeytermsSuspended = true
                    updateProjectVocabularySummary()
                }
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
        case .results(let isFinal, _, let transcript, let fromFinalize):
            assembler.apply(isFinal: isFinal, transcript: transcript)
            liveText = assembler.display
            if fromFinalize, phase == .finishing {
                completeToPreview(reason: "finalize")
            }
        case .metadata:
            if phase == .finishing {
                completeToPreview(reason: "metadata")
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
            completeToPreview(reason: "closed")
        case .connecting:
            if Self.looksLikeRejectedRequest(detail), reconnectWithoutAutomaticKeyterms() { return }
            teardownSession()
            showError(detail)
        case .recording:
            let hadPartialText = !assembler.display.isEmpty
            if !hadPartialText, detail.localizedCaseInsensitiveContains("keyterm"),
               reconnectWithoutAutomaticKeyterms() {
                return
            }
            audio?.stop()
            audio = nil
            audioTask?.cancel()
            audioTask = nil
            if hadPartialText {
                lastError = "Connection lost (\(detail)) — review what was captured."
                phase = .finishing
                completeToPreview(reason: "closed")
            } else {
                teardownSession()
                showError(detail)
            }
        case .idle, .polishing, .preview:
            break
        }
    }

    /// A refusal of the request itself (as opposed to a network failure, a
    /// bad key or rate limiting), which is how an over-long keyterm list
    /// shows up.
    private static func looksLikeRejectedRequest(_ detail: String) -> Bool {
        detail.localizedCaseInsensitiveContains("keyterm")
            || detail.hasPrefix("Deepgram connection failed (HTTP 4")
    }

    /// Deepgram limits keyterms by a token count it does not let us measure,
    /// so a session that sent learned or project terms and was refused gets
    /// one more try with only the Vocabulary from Settings — the list that
    /// worked before those terms existed. The microphone keeps running. If
    /// that second attempt connects, the automatic terms were the cause and
    /// stay out of recognition until the app is relaunched.
    private func reconnectWithoutAutomaticKeyterms() -> Bool {
        guard sessionUsedAutomaticKeyterms, !retriedWithoutAutomaticKeyterms,
              let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty
        else { return false }
        retriedWithoutAutomaticKeyterms = true
        dbg("deepgram: request refused with automatic keyterms — retrying with the Settings vocabulary only")

        client?.cancel()
        eventsTask?.cancel()
        let newClient = DeepgramClient()
        do {
            try newClient.connect(apiKey: apiKey, keyterms: settings.keytermList, endpointingMs: 800)
        } catch {
            return false
        }
        client = newClient
        phase = .connecting
        statusLine = "Connecting to Deepgram…"
        startEventPump(for: newClient)
        return true
    }

    private func completeToPreview(reason: String) {
        guard phase == .finishing else { return }
        finishDeadlineTask?.cancel()
        finishDeadlineTask = nil
        if let finishStartedAt {
            sessionTimings.finishMs = Self.milliseconds(since: finishStartedAt)
            sessionTimings.finishReason = reason
        }
        finishStartedAt = nil

        let text = assembler.finish()
        client?.cancel()
        client = nil
        eventsTask?.cancel()
        eventsTask = nil

        if text.isEmpty {
            phase = .idle
            statusLine = ""
            sessionTargetApp = nil
            panel.hide()
            panel.showNotice(title: "Nothing transcribed",
                             message: "Deepgram returned no text. Check your mic level while speaking.")
        } else if polishEnabled {
            startInitialPolish(text)
        } else {
            showPreview(raw: text, polished: nil, warning: nil)
        }
    }

    // MARK: - Polish flow

    private func polishConfiguration(apiKey: String) -> PolishConfiguration {
        PolishConfiguration(
            baseURL: llmBaseURL,
            model: llmModel,
            reasoningEffort: llmReasoningEffort,
            apiKey: apiKey,
            targetApp: targetAppName
        )
    }

    private func startInitialPolish(_ raw: String) {
        rawTranscript = raw
        rawPreviewText = raw
        phase = .polishing
        statusLine = "Polishing…"
        panel.showPolishing(state: self)
        hotkeys.registerTemporaryEscape()

        let service: any PolishService
        if let injectedPolishService {
            service = injectedPolishService
        } else {
            guard let apiKey = KeychainStore.loadPolishAPIKey(), !apiKey.isEmpty else {
                hotkeys.unregisterTemporaryEscape()
                polishFlow = nil
                showPreview(raw: raw, polished: nil,
                            warning: "Polish is on, but no LLM API key is saved. Using the raw transcript.")
                return
            }
            do {
                service = try PolishClient(configuration: polishConfiguration(apiKey: apiKey))
            } catch {
                hotkeys.unregisterTemporaryEscape()
                polishFlow = nil
                showPreview(raw: raw, polished: nil, warning: "Polish failed — using the raw transcript. \(error.localizedDescription)")
                return
            }
        }
        let flow = PolishFlowController(service: service)
        polishFlow = flow
        let glossary = vocabularyLists().glossary
        polishStartedAt = .now
        polishTask = Task { [weak self] in
            let result = await flow.start(transcript: raw, glossary: glossary)
            guard !Task.isCancelled else { return }
            self?.handleInitialPolishResult(result)
        }
    }

    private func handleInitialPolishResult(_ result: PolishFlowResult) {
        guard phase == .polishing else { return }
        if let polishStartedAt {
            sessionTimings.polishMs = Self.milliseconds(since: polishStartedAt)
        }
        polishStartedAt = nil
        polishTask = nil
        hotkeys.unregisterTemporaryEscape()
        switch result {
        case .ready(let text, let provenance, let warning):
            polishFlow = nil
            showPreview(raw: rawTranscript, polished: provenance == .polished ? text : nil, warning: warning)
        case .clarification(let draft, let questions):
            clarificationItems = questions.map { ClarificationItem(question: $0) }
            showPreview(raw: rawTranscript, polished: draft, warning: nil)
        case .cancelled:
            cancelPolish()
        }
    }

    func submitClarifications() {
        guard phase == .preview, !polishLoading, !clarificationItems.isEmpty else { return }
        guard polishEnabled else {
            discardPolishFlow()
            if polishedText == nil {
                applyRawText(warning: "Polish was turned off; using the raw transcript.")
            } else {
                clarificationItems = []
                previewWarning = "Polish was turned off; using the best available draft."
            }
            return
        }
        guard let polishFlow else {
            applyRawText(warning: "Could not apply clarification answers; using the raw transcript.")
            return
        }
        polishLoading = true
        previewWarning = nil
        let answers = clarificationItems.map(\.answer)
        polishTask = Task { [weak self] in
            let result = await polishFlow.resolve(answers: answers)
            guard !Task.isCancelled else { return }
            self?.handleResolutionPolishResult(result)
        }
    }

    func skipClarifications() {
        guard !polishLoading else { return }
        for index in clarificationItems.indices {
            clarificationItems[index].answer = ""
        }
        submitClarifications()
    }

    private func handleResolutionPolishResult(_ result: PolishFlowResult) {
        guard phase == .preview, polishLoading else { return }
        polishTask = nil
        switch result {
        case .ready(let text, let provenance, let warning):
            polishLoading = false
            clarificationItems = []
            polishFlow = nil
            if provenance == .polished {
                applyPolishedText(text, warning: warning)
            } else {
                applyRawText(warning: warning)
            }
        case .clarification:
            polishLoading = false
            clarificationItems = []
            polishFlow = nil
            // The controller never emits this after resolution; retain usable text
            // defensively if an alternate service violates that invariant.
            if let polishedText {
                applyPolishedText(polishedText,
                                  warning: PolishServiceError.repeatedUnclear.localizedDescription)
            } else {
                applyRawText(warning: PolishServiceError.repeatedUnclear.localizedDescription)
            }
        case .cancelled:
            cancelPolish()
        }
    }

    func clarificationAnswerBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { [weak self] in
                self?.clarificationItems.first(where: { $0.id == id })?.answer ?? ""
            },
            set: { [weak self] value in
                guard let index = self?.clarificationItems.firstIndex(where: { $0.id == id }) else { return }
                self?.clarificationItems[index].answer = value
            }
        )
    }

    func selectPreviewVersion(_ version: PreviewVersion) {
        guard hasBothPreviewVersions else { return }
        saveSelectedPreviewText()
        selectedPreviewVersion = version
        previewText = version == .polished ? polishedPreviewText : rawPreviewText
    }

    private func showPreview(raw: String, polished: String?, warning: String?) {
        rawTranscript = raw
        rawPreviewText = raw
        polishedText = polished
        polishedPreviewText = polished ?? ""
        selectedPreviewVersion = polished == nil ? .raw : .polished
        previewText = selectedPreviewVersion == .polished ? polishedPreviewText : rawPreviewText
        previewWarning = warning
        updatePolishChanges()
        phase = .preview
        statusLine = "Review and insert"
        dbg("timing: transcript complete after \(sessionTimings.finishMs.map(String.init) ?? "?") ms"
            + " (\(sessionTimings.finishReason ?? "n/a")), polish \(sessionTimings.polishMs.map(String.init) ?? "none") ms")
        panel.showPreview(state: self)
    }

    /// Lists the names polish swapped in, so a wrong "correction" is visible
    /// without comparing the two versions word by word.
    private func updatePolishChanges() {
        guard let polishedText, !rawTranscript.isEmpty else {
            polishChanges = []
            return
        }
        polishChanges = TextDiff.notableSubstitutions(
            from: rawTranscript,
            to: polishedText,
            limit: 8,
            isDictionaryWord: { Self.isDictionaryWord($0) }
        )
    }

    /// Puts back what was heard for one of the listed changes.
    func revertPolishChange(_ change: TextDiff.Change) {
        polishChanges.removeAll { $0 == change }
        guard selectedPreviewVersion == .polished, !polishLoading,
              let range = previewText.range(of: change.to)
        else { return }
        previewText.replaceSubrange(range, with: change.from)
    }

    /// A name typed over something else in the preview is a correction the
    /// recogniser and the polish model should not need twice.
    private func learnFromEdits(finalText: String) {
        let shown = selectedPreviewVersion == .polished ? (polishedText ?? rawTranscript) : rawTranscript
        guard !shown.isEmpty else { return }
        let terms = TextDiff.correctedTerms(from: shown, to: finalText) { Self.isDictionaryWord($0) }
        guard !terms.isEmpty else { return }
        let added = settings.addLearnedTerms(terms)
        guard !added.isEmpty else { return }
        learnedTermsText = settings.learnedTermsText
        dbg("vocabulary: learned \(added.joined(separator: ", "))")
    }

    private func applyPolishedText(_ text: String, warning: String?) {
        saveSelectedPreviewText()
        clarificationItems = []
        polishedText = text
        polishedPreviewText = text
        selectedPreviewVersion = .polished
        previewText = text
        previewWarning = warning
        updatePolishChanges()
    }

    private func applyRawText(warning: String?) {
        saveSelectedPreviewText()
        clarificationItems = []
        polishedText = nil
        polishedPreviewText = ""
        selectedPreviewVersion = .raw
        previewText = rawPreviewText
        previewWarning = warning
        polishChanges = []
    }

    private func discardPolishFlow() {
        polishTask?.cancel()
        polishTask = nil
        let flow = polishFlow
        polishFlow = nil
        clarificationItems = []
        polishLoading = false
        Task { await flow?.cancel() }
    }

    private func saveSelectedPreviewText() {
        switch selectedPreviewVersion {
        case .raw: rawPreviewText = previewText
        case .polished: polishedPreviewText = previewText
        }
    }

    private func clearPreviewState() {
        previewText = ""
        rawTranscript = ""
        polishedText = nil
        rawPreviewText = ""
        polishedPreviewText = ""
        selectedPreviewVersion = .raw
        clarificationItems = []
        polishLoading = false
        previewWarning = nil
        polishChanges = []
    }

    /// Releases the flow's pending raw transcript when preview actions finish.
    private func releasePreviewPolishState() {
        discardPolishFlow()
        clearPreviewState()
    }

    nonisolated static func canPasteIntoTarget(
        activationSucceeded: Bool,
        targetIsTerminated: Bool,
        targetProcessIdentifier: Int32,
        frontmostProcessIdentifier: Int32?
    ) -> Bool {
        activationSucceeded
            && !targetIsTerminated
            && frontmostProcessIdentifier == targetProcessIdentifier
    }

    private func copyForUnavailableTarget(_ text: String) {
        TextInserter.copyToClipboard(text: text)
        panel.showNotice(
            title: "Copied to clipboard",
            message: "The app you dictated into is no longer available, so Whispr did not paste into another app."
        )
    }

    private func showError(_ message: String) {
        phase = .idle
        statusLine = ""
        lastError = message
        sessionTargetApp = nil
        panel.hide()
        panel.showNotice(title: "Whispr", message: message)
    }

    // MARK: - Preview actions

    func confirmInsert() {
        saveSelectedPreviewText()
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            cancelPreview()
            return
        }
        let target = sessionTargetApp
        learnFromEdits(finalText: text)
        recordHistory(text)
        releasePreviewPolishState()
        phase = .idle
        statusLine = ""
        lastError = nil
        sessionTargetApp = nil
        panel.hide()

        Task {
            guard let target, !target.isTerminated else {
                copyForUnavailableTarget(text)
                return
            }
            let activationSucceeded = target.activate(
                from: NSRunningApplication.current,
                options: [.activateAllWindows]
            )
            guard activationSucceeded else {
                copyForUnavailableTarget(text)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard Self.canPasteIntoTarget(
                activationSucceeded: activationSucceeded,
                targetIsTerminated: target.isTerminated,
                targetProcessIdentifier: target.processIdentifier,
                frontmostProcessIdentifier: frontmostProcessIdentifier
            ) else {
                copyForUnavailableTarget(text)
                return
            }
            let result = TextInserter.insert(text: text)
            if result == .copiedOnly {
                refreshPermissions()
                panel.showNotice(
                    title: "Copied to clipboard",
                    message: "Grant Accessibility (System Settings → Privacy & Security → Accessibility) so Whispr can paste directly."
                )
            }
        }
    }

    func copyPreview() {
        saveSelectedPreviewText()
        let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            cancelPreview()
            return
        }
        learnFromEdits(finalText: text)
        recordHistory(text)
        TextInserter.copyToClipboard(text: text)
        releasePreviewPolishState()
        phase = .idle
        statusLine = ""
        sessionTargetApp = nil
        panel.hide()
        panel.showNotice(title: "Copied", message: "Transcript copied to the clipboard.")
    }

    func cancelPreview() {
        if polishLoading {
            cancelPolish()
            return
        }
        releasePreviewPolishState()
        phase = .idle
        statusLine = ""
        lastError = nil
        sessionTargetApp = nil
        panel.hide()
    }

    // MARK: - History

    private func recordHistory(_ text: String) {
        guard settings.historyEnabled else { return }
        let hasTimings = sessionTimings.finishMs != nil || sessionTimings.polishMs != nil
        historyItems = history.add(HistoryStore.Entry(
            text: text,
            raw: rawTranscript.isEmpty ? nil : rawTranscript,
            polished: polishedText,
            target: targetAppName,
            timings: hasTimings ? sessionTimings : nil
        ))
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

    /// `--selftest-polish=TEXT`: performs exactly one production initial call.
    func runPolishSelfTest(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dbg("selftest-polish: text must not be empty")
            exit(2)
        }
        guard let key = KeychainStore.loadPolishAPIKey(), !key.isEmpty else {
            dbg("selftest-polish: no LLM API key in Keychain")
            exit(1)
        }
        let client: PolishClient
        do {
            client = try PolishClient(configuration: polishConfiguration(apiKey: key))
        } catch {
            dbg("selftest-polish: \(error.localizedDescription)")
            exit(1)
        }
        let glossary = settings.keytermList
        Task {
            do {
                let result = try await client.initial(transcript: trimmed, glossary: glossary)
                switch result {
                case .ok(let rewrite):
                    dbg("selftest-polish: ok (\(rewrite.count) characters)")
                case .unclear(_, let questions):
                    dbg("selftest-polish: unclear (\(questions.count) questions)")
                }
                exit(0)
            } catch {
                dbg("selftest-polish: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// Deterministic forced-unclear integration check for the production flow.
    func runPolishMockSelfTest() {
        let service = ScriptedPolishService(steps: [
            .response(.unclear(draft: "Delete the temporary item.", questions: ["Which temporary item?", "Should this be permanent?"])),
            .response(.ok(rewrite: "Delete the temporary cache item permanently.")),
        ])
        let flow = PolishFlowController(service: service)
        Task {
            let first = await flow.start(transcript: "delete the temp thing", glossary: [])
            guard case .clarification(_, let questions) = first, questions.count == 2 else {
                dbg("selftest-polish-mock: unexpected initial transition")
                exit(1)
            }
            dbg("selftest-polish-mock: initial unclear (2 questions)")
            let second = await flow.resolve(answers: ["cache item", "yes"])
            let callCount = await service.callCount
            guard case .ready(let text, .polished, _) = second,
                  text == "Delete the temporary cache item permanently.",
                  callCount == 2 else {
                dbg("selftest-polish-mock: unexpected resolution transition")
                exit(1)
            }
            dbg("selftest-polish-mock: unclear → resolution ok (2 service calls)")
            exit(0)
        }
    }

    /// `--selftest-vocab[=FOLDER]`: show the vocabulary that would be used for
    /// a project — the given folder, or whatever the frontmost app is working
    /// in. Touches neither the Keychain nor the network.
    func runVocabularySelfTest(path: String?) {
        Task {
            var folders: [URL] = []
            if let path, !path.isEmpty {
                let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
                folders = [ProjectLocator.repositoryRoot(containing: url) ?? url]
            } else if let app = NSWorkspace.shared.frontmostApplication {
                let window = ProjectLocator.focusedWindow(ofAppWithPID: app.processIdentifier)
                dbg("selftest-vocab: frontmost app \(app.localizedName ?? "?"), window document \(window.documentPath ?? "none")")
                folders = ProjectLocator.repositories(forAppWithPID: app.processIdentifier, window: window)
            }
            guard !folders.isEmpty else {
                dbg("selftest-vocab: no project folder found")
                exit(1)
            }
            let started = ContinuousClock.now
            let projects = await Task.detached { folders.map(ProjectHarvester.harvest(repository:)) }.value
            dbg("selftest-vocab: harvested \(projects.count) project(s) in \(Self.milliseconds(since: started)) ms")
            for project in projects {
                dbg("selftest-vocab: \(project.repository.path) — \(project.spoken.count) spoken, \(project.glossary.count) glossary")
            }
            let lists = VocabularyBuilder.build(
                manual: settings.keytermList,
                learned: settings.learnedTermList,
                project: projects
            )
            let tokens = lists.keyterms.reduce(0) { $0 + VocabularyBuilder.estimatedTokens($1) }
            dbg("selftest-vocab: \(lists.keyterms.count) keyterms, ~\(tokens) of \(VocabularyBuilder.keytermTokenBudget) budgeted tokens: "
                + lists.keyterms.joined(separator: ", "))
            dbg("selftest-vocab: \(lists.glossary.count) glossary terms, first 60: "
                + lists.glossary.prefix(60).joined(separator: ", "))
            exit(0)
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
            capture.onFailure = { error in
                dbg("selftest-mic: capture failed: \(error.localizedDescription)")
            }
            do {
                let stream = try capture.start()
                // Stop on a timer, not on chunk arrival: a microphone that
                // goes quiet must end the test with a short count, not hang it.
                let stopper = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    capture.stop()
                }
                var chunks = 0
                var bytes = 0
                var peak: Float = 0
                for await chunk in stream {
                    chunks += 1
                    bytes += chunk.count
                    peak = max(peak, RMSLevel.compute(chunk))
                }
                stopper.cancel()
                capture.stop()
                // 16 kHz mono Int16 is 32 000 bytes per second. A capture that
                // stalls partway (e.g. after a device change) falls well short.
                let expectedBytes = max(seconds, 1) * 32_000
                let coverage = bytes * 100 / expectedBytes
                let peakText = String(format: "%.3f", peak)
                dbg("selftest-mic: \(chunks) chunks, \(bytes) bytes (\(coverage)% of \(seconds)s), peak level \(peakText)")
                self?.refreshPermissions()
                exit(coverage >= 70 ? 0 : 2)
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

    private func startSessionFromFile(chunks: [Data]) {
        guard let apiKey = KeychainStore.loadAPIKey() else {
            dbg("selftest-file: no API key in Keychain")
            exit(1)
        }

        sessionKind = .toggle
        assembler.reset()
        liveText = ""
        clearPreviewState()
        phase = .connecting
        statusLine = "Connecting to Deepgram…"
        targetAppName = "Self Test"
        sessionTargetApp = nil

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
