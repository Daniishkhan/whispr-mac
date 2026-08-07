@preconcurrency import AVFoundation
import Foundation

/// Captures microphone audio with `AVAudioEngine` and resamples it to
/// 16 kHz mono signed-16-bit PCM (`linear16`), which is what Deepgram expects.
///
/// The tap runs on a realtime audio thread, so it does the minimum possible:
/// convert and yield into an `AsyncStream`. All consumers read in order.
final class AudioCapture {

    enum CaptureError: LocalizedError {
        case formatUnavailable
        case engineStartFailed(Error)

        var errorDescription: String? {
            switch self {
            case .formatUnavailable:
                return "Could not create a 16 kHz audio format for the microphone."
            case .engineStartFailed(let error):
                return "Microphone failed to start: \(error.localizedDescription)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<Data>.Continuation?

    /// Converts the tap's native-format buffers to 16 kHz mono Int16.
    /// Only ever touched on the audio render thread.
    private final class TapContext: @unchecked Sendable {
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat
        let continuation: AsyncStream<Data>.Continuation

        init(converter: AVAudioConverter, outputFormat: AVAudioFormat, continuation: AsyncStream<Data>.Continuation) {
            self.converter = converter
            self.outputFormat = outputFormat
            self.continuation = continuation
        }

        func process(_ inputBuffer: AVAudioPCMBuffer) {
            let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 64
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                return
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

            guard status != .error, conversionError == nil else { return }

            let frameLength = Int(outputBuffer.frameLength)
            guard frameLength > 0, let channelData = outputBuffer.int16ChannelData else { return }
            continuation.yield(Data(bytes: channelData[0], count: frameLength * MemoryLayout<Int16>.size))
        }
    }

    static var permissionGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var permissionDetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined
    }

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Starts the engine and returns an ordered stream of PCM chunks.
    func start() throws -> AsyncStream<Data> {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.formatUnavailable
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CaptureError.formatUnavailable
        }

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        let context = TapContext(converter: converter, outputFormat: outputFormat, continuation: continuation)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            context.process(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }
}
