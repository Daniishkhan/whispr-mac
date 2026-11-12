import AVFoundation
import XCTest
@testable import Whispr

final class PCMChunkConverterTests: XCTestCase {

    /// Half a second of 16 kHz mono Int16.
    private let halfSecondBytes = 16_000.0
    private let tolerance = 1_600.0

    func testResamples48kMonoTo16kMono() throws {
        let converter = try XCTUnwrap(PCMChunkConverter())

        let chunk = try XCTUnwrap(converter.convert(try makeTone(sampleRate: 48_000, channels: 1)))

        XCTAssertEqual(Double(chunk.count), halfSecondBytes, accuracy: tolerance)
        XCTAssertGreaterThan(RMSLevel.compute(chunk), 0.1)
    }

    /// The downmix path holds back a few milliseconds on its first buffer and
    /// releases them on the next, so measure a run of buffers, not just one.
    func testDownmixesStereoToMono() throws {
        let converter = try XCTUnwrap(PCMChunkConverter())

        var audio = Data()
        for _ in 0..<4 {
            audio.append(try XCTUnwrap(converter.convert(try makeTone(sampleRate: 48_000, channels: 2))))
        }

        XCTAssertEqual(Double(audio.count), halfSecondBytes * 4, accuracy: tolerance * 4)
        XCTAssertGreaterThan(RMSLevel.compute(audio), 0.1)
    }

    /// AirPods open at 48 kHz and drop to 24 kHz a moment after the mic turns
    /// on. A converter pinned to the first format would emit half as much
    /// audio (played at double speed) for everything after the switch.
    func testFollowsInputFormatChangeMidStream() throws {
        let converter = try XCTUnwrap(PCMChunkConverter())

        let before = try XCTUnwrap(converter.convert(try makeTone(sampleRate: 48_000, channels: 1)))
        let after = try XCTUnwrap(converter.convert(try makeTone(sampleRate: 24_000, channels: 1)))

        XCTAssertEqual(Double(before.count), halfSecondBytes, accuracy: tolerance)
        XCTAssertEqual(Double(after.count), halfSecondBytes, accuracy: tolerance)
        XCTAssertGreaterThan(RMSLevel.compute(after), 0.1)
    }

    func testEmptyBufferYieldsNothing() throws {
        let converter = try XCTUnwrap(PCMChunkConverter())
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))

        XCTAssertNil(converter.convert(buffer))
    }

    /// Half a second of a 440 Hz tone in the engine's native Float32 layout.
    private func makeTone(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount(sampleRate / 2)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                channelData[channel][frame] = 0.5 * sinf(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        return buffer
    }
}
