@preconcurrency import AVFoundation
import Foundation

/// Decodes an audio file (WAV/AIFF/CAF/M4A…) to 16 kHz mono Int16 PCM chunks,
/// matching what `AudioCapture` produces. Used by the `--selftest-file` CLI
/// path to drive a real dictation session without a microphone.
enum FileAudioStreamer {

    enum StreamerError: LocalizedError {
        case formatUnavailable
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .formatUnavailable: return "Could not create conversion formats for the audio file."
            case .emptyFile: return "The audio file decoded to zero samples."
            }
        }
    }

    static func loadChunks(url: URL, chunkDurationMs: Int = 100) throws -> [Data] {
        let file = try AVAudioFile(forReading: url)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
            throw StreamerError.formatUnavailable
        }

        let frameCount = AVAudioFrameCount(max(file.length, 1))
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw StreamerError.formatUnavailable
        }
        try file.read(into: source)

        var pcm = Data()
        var provided = false
        var exhausted = false
        var iterations = 0

        while !exhausted && iterations < 10_000 {
            iterations += 1
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
                if provided {
                    statusPointer.pointee = .endOfStream
                    return nil
                }
                provided = true
                statusPointer.pointee = .haveData
                return source
            }

            if output.frameLength > 0, let channelData = output.int16ChannelData {
                pcm.append(Data(bytes: channelData[0], count: Int(output.frameLength) * 2))
            }

            switch status {
            case .endOfStream:
                exhausted = true
            case .error:
                throw conversionError ?? StreamerError.formatUnavailable
            case .haveData, .inputRanDry:
                if output.frameLength == 0 && provided { exhausted = true }
            @unknown default:
                exhausted = true
            }
        }

        guard !pcm.isEmpty else { throw StreamerError.emptyFile }

        let bytesPerChunk = max(2, Int(16_000.0 * Double(chunkDurationMs) / 1000.0) * 2)
        var chunks: [Data] = []
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + bytesPerChunk, pcm.count)
            chunks.append(pcm.subdata(in: offset..<end))
            offset = end
        }
        return chunks
    }
}
