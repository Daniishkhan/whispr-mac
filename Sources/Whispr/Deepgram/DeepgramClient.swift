import Foundation

/// Streaming client for Deepgram's websocket listen API (Nova-3).
///
/// Threading: safe to call from anywhere. Audio frames are queued and flushed
/// by a single serial "pump" task once the socket opens, so ordering is
/// preserved. Server frames and lifecycle events are delivered through the
/// `events` stream.
final class DeepgramClient: @unchecked Sendable {

    enum Event {
        case opened
        case text(String)
        case closed(code: URLSessionWebSocketTask.CloseCode, reason: String?)
        case failed(String)
    }

    private enum Outgoing {
        case audio(Data)
        case control(String)
    }

    let events: AsyncStream<Event>

    private let continuation: AsyncStream<Event>.Continuation
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var delegateBox: WebSocketDelegateBox?
    private var receiveTask: Task<Void, Never>?

    // All guarded by `lock`.
    private var isOpen = false
    private var pending: [Outgoing] = []
    private var pumpRunning = false
    private var terminalEmitted = false

    init() {
        let (stream, cont) = AsyncStream<Event>.makeStream()
        self.events = stream
        self.continuation = cont
    }

    // MARK: - Connection

    func connect(apiKey: String, keyterms: [String], endpointingMs: Int) throws {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")
        var query: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "endpointing", value: String(endpointingMs)),
            URLQueryItem(name: "vad_events", value: "true"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
        ]
        for term in keyterms.prefix(100) {
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                query.append(URLQueryItem(name: "keyterm", value: trimmed))
            }
        }
        components?.queryItems = query

        guard let url = components?.url else {
            throw DeepgramClientError.badURL
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let box = WebSocketDelegateBox(
            onOpen: { [weak self] in self?.handleOpen() },
            onClose: { [weak self] code, reason in self?.handleClose(code: code, reason: reason) },
            onError: { [weak self] error, status in self?.handleError(error, statusCode: status) }
        )
        self.delegateBox = box

        let session = URLSession(configuration: .default, delegate: box, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        task.resume()
        startReceiveLoop(task)
    }

    // MARK: - Sending

    func sendAudio(_ data: Data) {
        enqueue(.audio(data))
    }

    /// Flushes server-side audio and asks Deepgram to close the stream once it
    /// has returned all final transcripts.
    func sendCloseStream() {
        enqueue(.control(#"{"type":"CloseStream"}"#))
    }

    private func enqueue(_ message: Outgoing) {
        lock.lock()
        // Bound the pre-open buffer to ~25 s of audio so a stalled handshake
        // doesn't grow memory forever. Drop the oldest audio first.
        if pending.count > 300, case .audio = message {
            if let idx = pending.firstIndex(where: { if case .audio = $0 { return true } else { return false } }) {
                pending.remove(at: idx)
            }
        }
        pending.append(message)
        let shouldStart = isOpen && !pumpRunning && !terminalEmitted
        if shouldStart { pumpRunning = true }
        lock.unlock()
        if shouldStart { startPump() }
    }

    private func startPump() {
        Task { [weak self] in
            guard let self else { return }
            while let next = self.dequeueNext() {
                let wsMessage: URLSessionWebSocketTask.Message
                switch next {
                case .audio(let data): wsMessage = .data(data)
                case .control(let text): wsMessage = .string(text)
                }
                do {
                    try await self.task?.send(wsMessage)
                } catch {
                    self.emitTerminal(.failed("Send failed: \(error.localizedDescription)"))
                    return
                }
            }
        }
    }

    /// Synchronous (lock-guarded) queue pop. Returning nil stops the pump.
    private func dequeueNext() -> Outgoing? {
        lock.lock()
        defer { lock.unlock() }
        if pending.isEmpty || terminalEmitted {
            pumpRunning = false
            return nil
        }
        return pending.removeFirst()
    }

    // MARK: - Receiving

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        self.emit(.text(text))
                    case .data:
                        break
                    @unknown default:
                        break
                    }
                }
            } catch {
                // The delegate's didClose / didCompleteWithError usually reports
                // the real reason; only surface this if nothing else did.
                self?.emitTerminalIfIdle(.failed("Connection lost: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Delegate callbacks (arbitrary threads)

    private func handleOpen() {
        lock.lock()
        isOpen = true
        let shouldStart = !pending.isEmpty && !pumpRunning && !terminalEmitted
        if shouldStart { pumpRunning = true }
        lock.unlock()
        emit(.opened)
        if shouldStart { startPump() }
    }

    private func handleClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) }
        emitTerminal(.closed(code: code, reason: reasonString))
    }

    private func handleError(_ error: Error, statusCode: Int?) {
        if let statusCode {
            switch statusCode {
            case 401, 403:
                emitTerminal(.failed("Deepgram rejected the API key (HTTP \(statusCode)). Check it in Settings."))
            case 429:
                emitTerminal(.failed("Deepgram rate limit hit (HTTP 429). Try again shortly."))
            default:
                emitTerminal(.failed("Deepgram connection failed (HTTP \(statusCode))."))
            }
        } else {
            emitTerminal(.failed("Connection error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Teardown

    func cancel() {
        receiveTask?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        lock.lock()
        terminalEmitted = true
        lock.unlock()
        continuation.finish()
    }

    // MARK: - Event emission

    private func emit(_ event: Event) {
        continuation.yield(event)
    }

    private func emitTerminal(_ event: Event) {
        lock.lock()
        if terminalEmitted {
            lock.unlock()
            return
        }
        terminalEmitted = true
        lock.unlock()
        continuation.yield(event)
        continuation.finish()
    }

    private func emitTerminalIfIdle(_ event: Event) {
        emitTerminal(event)
    }
}

private enum DeepgramClientError: Error {
    case badURL
}

/// Bridges `URLSessionWebSocketDelegate` callbacks into sendable closures.
private final class WebSocketDelegateBox: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let onOpen: @Sendable () -> Void
    let onClose: @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void
    let onError: @Sendable (Error, Int?) -> Void

    init(
        onOpen: @escaping @Sendable () -> Void,
        onClose: @escaping @Sendable (URLSessionWebSocketTask.CloseCode, Data?) -> Void,
        onError: @escaping @Sendable (Error, Int?) -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.onError = onError
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose(closeCode, reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        onError(error, status)
    }
}
