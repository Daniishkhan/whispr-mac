import Foundation

/// User-editable settings persisted in UserDefaults.
/// (UserDefaults is internally synchronized; the class holds no mutable state.)
final class SettingsStore: @unchecked Sendable {

    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let keyterms = "keytermsText"
        static let historyEnabled = "historyEnabled"
    }

    /// Raw text from the Vocabulary editor — one term per line.
    var keytermsText: String {
        get { defaults.string(forKey: Key.keyterms) ?? "" }
        set { defaults.set(newValue, forKey: Key.keyterms) }
    }

    /// Parsed, cleaned, de-duplicated keyterms ready for the Deepgram URL.
    var keytermList: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in keytermsText.components(separatedBy: .newlines) {
            let term = line.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            let fingerprint = term.lowercased()
            if seen.insert(fingerprint).inserted {
                result.append(term)
            }
            if result.count == 100 { break }  // Deepgram keyterm limit
        }
        return result
    }

    var historyEnabled: Bool {
        get {
            if defaults.object(forKey: Key.historyEnabled) == nil { return true }
            return defaults.bool(forKey: Key.historyEnabled)
        }
        set { defaults.set(newValue, forKey: Key.historyEnabled) }
    }
}
