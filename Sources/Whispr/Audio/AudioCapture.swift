@preconcurrency import AVFoundation
import Foundation

/// Converts microphone buffers to 16 kHz mono signed-16-bit PCM (`linear16`),
/// which is what Deepgram expects.
///
/// The converter follows the format of the buffers it is handed rather than a
/// format captured up front, so a device that renegotiates mid-stream (AirPods
/// dropping from 48 kHz to 24 kHz when their mic opens) keeps producing audio
/// at the right speed.
///
/// Only ever touched from one tap callback at a time.
final class PCMChunkConverter: @unchecked Sendable {

    static let outputSampleRate: Double = 16_000

    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: true
        ) else { return nil }
        outputFormat = format
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) -> Data? {
        let inputFormat = inputBuffer.format
        guard inputFormat.sampleRate > 0, inputBuffer.frameLength > 0 else { return nil }

        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil else { return nil }

        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0, let channelData = outputBuffer.int16ChannelData else { return nil }
        return Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size)
    }
}

/// Captures microphone audio with `AVAudioEngine` and yields it as an ordered
/// stream of 16 kHz mono Int16 PCM chunks.
///
/// The tap does the minimum possible: convert and yield into an `AsyncStream`.
///
/// `AVAudioEngine` stops itself whenever the input hardware changes format or
/// the default input device changes, and posts
/// `AVAudioEngineConfigurationChange`. Bluetooth headsets do this on *every*
/// recording — AirPods switch profile a moment after their mic opens — so the
/// capture re-installs its tap and restarts the engine when that happens.
/// Without it the stream goes silent while the session still looks live.
@MainActor
final class AudioCapture {

    enum CaptureError: LocalizedError {
        case formatUnavailable
        case engineStartFailed(Error)
        case deviceChangeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .formatUnavailable:
                return "Could not create a 16 kHz audio format for the microphone."
            case .engineStartFailed(let error):
                return "Microphone failed to start: \(error.localizedDescription)"
            case .deviceChangeFailed(let error):
                return "The microphone changed and could not be restarted: \(error.localizedDescription)"
            }
        }
    }

    /// Called when the microphone cannot be brought back after a device
    /// change. The capture has already stopped and its stream has finished.
    var onFailure: ((Error) -> Void)?

    private var engine = AVAudioEngine()
    private var continuation: AsyncStream<Data>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    private var restartTask: Task<Void, Never>?
    private var tapInstalled = false

    /// A device is often still settling when the change notification lands,
    /// so restarting is retried for a little over a second before giving up.
    private static let restartAttempts = 8
    private static let restartRetryDelay: Duration = .milliseconds(150)

    nonisolated static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    nonisolated static var permissionDetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined
    }

    nonisolated static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Starts the engine and returns an ordered stream of PCM chunks.
    func start() throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        do {
            try startEngine(yieldingTo: continuation)
        } catch {
            continuation.finish()
            throw error
        }
        self.continuation = continuation
        observeConfigurationChanges()
        return stream
    }

    func stop() {
        stopObservingConfigurationChanges()
        restartTask?.cancel()
        restartTask = nil
        removeTap()
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Engine

    private func startEngine(yieldingTo continuation: AsyncStream<Data>.Continuation) throws {
        let input = engine.inputNode
        // The hardware side of the input node. After a device change the
        // node's *output* format still carries the old sample rate and the
        // engine refuses to start with it (-10868), so the tap always pins
        // the bus to what the hardware reports right now.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.formatUnavailable
        }
        guard let converter = PCMChunkConverter() else {
            throw CaptureError.formatUnavailable
        }

        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: format,
            block: Self.tapBlock(converter: converter, continuation: continuation)
        )
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTap()
            throw CaptureError.engineStartFailed(error)
        }
    }

    /// Built outside the main actor on purpose: the tap runs on an audio
    /// thread, and a closure formed in an isolated method would inherit the
    /// main actor and trap there.
    nonisolated private static func tapBlock(
        converter: PCMChunkConverter,
        continuation: AsyncStream<Data>.Continuation
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            if let chunk = converter.convert(buffer) {
                continuation.yield(chunk)
            }
        }
    }

    private func removeTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    // MARK: - Device changes

    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // Posted on an engine-internal thread, and the engine must not be
            // reconfigured from inside the handler — hop to the main actor.
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    private func stopObservingConfigurationChanges() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    /// Swaps in a brand-new engine, which reads the device's formats from
    /// scratch exactly as the first start of a session does.
    private func replaceEngine() {
        stopObservingConfigurationChanges()
        removeTap()
        engine.stop()
        engine = AVAudioEngine()
        observeConfigurationChanges()
    }

    private func handleConfigurationChange() {
        guard continuation != nil else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            await self?.restartAfterConfigurationChange()
        }
    }

    private func restartAfterConfigurationChange() async {
        var lastError: Error = CaptureError.formatUnavailable
        for attempt in 0..<Self.restartAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: Self.restartRetryDelay)
            }
            guard !Task.isCancelled, let continuation else { return }

            // First try the engine we have; if it will not come back, start
            // over with a fresh one on each further attempt.
            if attempt == 0 {
                removeTap()
                engine.stop()
            } else {
                replaceEngine()
            }
            do {
                try startEngine(yieldingTo: continuation)
                let format = engine.inputNode.inputFormat(forBus: 0)
                dbg("audio: input device changed — capture restarted at \(Int(format.sampleRate)) Hz (attempt \(attempt + 1))")
                return
            } catch {
                dbg("audio: restart attempt \(attempt + 1) failed: \(error.localizedDescription)")
                lastError = error
            }
        }

        guard !Task.isCancelled, continuation != nil else { return }
        dbg("audio: input device changed — restart failed: \(lastError.localizedDescription)")
        let handler = onFailure
        stop()
        handler?(CaptureError.deviceChangeFailed(lastError))
    }
}
