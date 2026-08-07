import Foundation

enum RMSLevel {

    /// Normalized 0…1 loudness for a chunk of 16-bit PCM audio.
    static func compute(_ data: Data) -> Float {
        data.withUnsafeBytes { rawBuffer -> Float in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Double = 0
            for sample in samples {
                let value = Double(sample) / 32768.0
                sum += value * value
            }
            let rms = sqrt(sum / Double(samples.count))
            return Float(min(1.0, rms * 3.0))
        }
    }
}
