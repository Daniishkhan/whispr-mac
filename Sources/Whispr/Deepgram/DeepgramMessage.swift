import Foundation

/// One decoded Deepgram websocket frame, reduced to what the app cares about.
enum DeepgramMessage {
    /// `fromFinalize` marks the result that completes a `Finalize` flush.
    case results(isFinal: Bool, speechFinal: Bool, transcript: String, fromFinalize: Bool)
    case speechStarted
    case utteranceEnd
    case metadata
    case warning(String)
    case error(String)
    case unknown

    static func parse(_ text: String) -> DeepgramMessage {
        guard
            let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return .unknown }

        switch type {
        case "Results":
            let channel = obj["channel"] as? [String: Any]
            let alternatives = channel?["alternatives"] as? [[String: Any]]
            let transcript = alternatives?.first?["transcript"] as? String ?? ""
            return .results(
                isFinal: obj["is_final"] as? Bool ?? false,
                speechFinal: obj["speech_final"] as? Bool ?? false,
                transcript: transcript,
                fromFinalize: obj["from_finalize"] as? Bool ?? false
            )
        case "SpeechStarted":
            return .speechStarted
        case "UtteranceEnd":
            return .utteranceEnd
        case "Metadata":
            return .metadata
        case "Warning":
            return .warning(obj["message"] as? String ?? "Unknown warning")
        case "Error":
            return .error(
                obj["message"] as? String
                    ?? obj["description"] as? String
                    ?? "Unknown Deepgram error"
            )
        default:
            return .unknown
        }
    }
}
