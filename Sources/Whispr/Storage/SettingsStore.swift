import Foundation

/// User-editable settings persisted in UserDefaults.
/// (UserDefaults is internally synchronized; the class holds no mutable state.)
final class SettingsStore: @unchecked Sendable {

    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let keyterms = "keytermsText"
        static let historyEnabled = "historyEnabled"
        static let polishEnabled = "polishEnabled"
        static let llmBaseURL = "llmBaseURL"
        static let llmModel = "llmModel"
        static let llmReasoningEffort = "llmReasoningEffort"
        static let learnedTerms = "learnedTermsText"
        static let projectVocabularyEnabled = "projectVocabularyEnabled"
        static let projectFolders = "projectFoldersText"
    }

    /// Deepgram accepts at most this many keyterms from the Vocabulary list.
    static let maxKeyterms = 100
    static let maxLearnedTerms = 150

    /// Raw text from the Vocabulary editor — one term per line.
    var keytermsText: String {
        get { defaults.string(forKey: Key.keyterms) ?? "" }
        set { defaults.set(newValue, forKey: Key.keyterms) }
    }

    /// Parsed, cleaned, de-duplicated keyterms ready for the Deepgram URL.
    var keytermList: [String] {
        Self.parseTerms(keytermsText, limit: Self.maxKeyterms)
    }

    /// One term per line: trimmed, de-duplicated case-insensitively, capped.
    static func parseTerms(_ text: String, limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let term = line.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            if seen.insert(term.lowercased()).inserted {
                result.append(term)
            }
            if result.count == limit { break }
        }
        return result
    }

    /// Names picked up from corrections made in the preview — newest first,
    /// one per line, editable in Settings.
    var learnedTermsText: String {
        get { defaults.string(forKey: Key.learnedTerms) ?? "" }
        set { defaults.set(newValue, forKey: Key.learnedTerms) }
    }

    var learnedTermList: [String] {
        Self.parseTerms(learnedTermsText, limit: Self.maxLearnedTerms)
    }

    /// Puts new terms at the front of the learned list. Returns the ones that
    /// were not already known (in either list).
    @discardableResult
    func addLearnedTerms(_ terms: [String]) -> [String] {
        let existing = learnedTermList
        var known = Set((keytermList + existing).map { $0.lowercased() })
        let added = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("\n") && known.insert($0.lowercased()).inserted }
        guard !added.isEmpty else { return [] }
        learnedTermsText = (added + existing).prefix(Self.maxLearnedTerms).joined(separator: "\n")
        return added
    }

    /// Whether names from the project being dictated into are added to the
    /// recogniser's keyterms and the polish glossary.
    var projectVocabularyEnabled: Bool {
        get {
            if defaults.object(forKey: Key.projectVocabularyEnabled) == nil { return true }
            return defaults.bool(forKey: Key.projectVocabularyEnabled)
        }
        set { defaults.set(newValue, forKey: Key.projectVocabularyEnabled) }
    }

    /// Folders that are always treated as the current project, in addition to
    /// whatever is detected — separated by commas or new lines.
    var projectFoldersText: String {
        get { defaults.string(forKey: Key.projectFolders) ?? "" }
        set { defaults.set(newValue, forKey: Key.projectFolders) }
    }

    var projectFolderList: [URL] {
        projectFoldersText
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(4)
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, isDirectory: true) }
    }

    var historyEnabled: Bool {
        get {
            if defaults.object(forKey: Key.historyEnabled) == nil { return true }
            return defaults.bool(forKey: Key.historyEnabled)
        }
        set { defaults.set(newValue, forKey: Key.historyEnabled) }
    }

    /// Global LLM polish is opt-out, as approved for the first release.
    var polishEnabled: Bool {
        get {
            if defaults.object(forKey: Key.polishEnabled) == nil { return true }
            return defaults.bool(forKey: Key.polishEnabled)
        }
        set { defaults.set(newValue, forKey: Key.polishEnabled) }
    }

    var llmBaseURL: String {
        get { defaults.string(forKey: Key.llmBaseURL) ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: Key.llmBaseURL) }
    }

    var llmModel: String {
        get { defaults.string(forKey: Key.llmModel) ?? "gpt-5.6-terra" }
        set { defaults.set(newValue, forKey: Key.llmModel) }
    }

    var llmReasoningEffort: PolishReasoningEffort {
        get {
            guard let raw = defaults.string(forKey: Key.llmReasoningEffort),
                  let effort = PolishReasoningEffort(rawValue: raw) else {
                // Repairing a transcript is editing, not problem solving; a
                // low setting keeps the wait before the preview short.
                return .low
            }
            return effort
        }
        set { defaults.set(newValue.rawValue, forKey: Key.llmReasoningEffort) }
    }
}
