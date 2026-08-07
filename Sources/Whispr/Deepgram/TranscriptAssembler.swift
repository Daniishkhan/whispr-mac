import Foundation

/// Combines Deepgram interim + final streaming results into one clean string
/// without duplication.
///
/// - Interim results for the current utterance are *cumulative replacements*:
///   each new interim replaces the previous one.
/// - Final results (`is_final == true`) are appended to the committed text and
///   never change again.
/// - `speech_final` simply means the VAD decided the utterance ended; the
///   accompanying result is also `is_final`, so no special handling is needed
///   for assembly.
struct TranscriptAssembler {
    private(set) var committed: String = ""
    private(set) var interim: String = ""

    /// What the HUD shows while recording.
    var display: String {
        switch (committed.isEmpty, interim.isEmpty) {
        case (true, true): return ""
        case (false, true): return committed
        case (true, false): return interim
        case (false, false): return committed + " " + interim
        }
    }

    mutating func apply(isFinal: Bool, transcript: String) {
        let cleaned = transcript.trimmingCharacters(in: .whitespaces)
        if isFinal {
            if !cleaned.isEmpty {
                committed = committed.isEmpty ? cleaned : committed + " " + cleaned
            }
            interim = ""
        } else {
            interim = cleaned
        }
    }

    /// Call when the stream ends. Returns the whole transcript and resets.
    mutating func finish() -> String {
        let tail = interim
        interim = ""
        if !tail.isEmpty {
            committed = committed.isEmpty ? tail : committed + " " + tail
        }
        let result = committed
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        committed = ""
        return result
    }

    mutating func reset() {
        committed = ""
        interim = ""
    }
}
