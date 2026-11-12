import Foundation

/// Word-level comparison of two versions of a dictated message.
///
/// Used twice: to show which names the polish step swapped in (a silent wrong
/// "fix" is worse than a typo), and to notice which names the user corrected
/// by hand so they can be recognised properly next time.
enum TextDiff {

    struct Change: Hashable, Sendable {
        /// The wording that was replaced.
        let from: String
        /// What it became.
        let to: String
    }

    private struct Token {
        /// The word exactly as written, punctuation included.
        let raw: String
        /// The word without surrounding punctuation.
        let text: String
        /// Case-insensitive identity used for alignment.
        let key: String
    }

    // MARK: - Substitutions

    /// Phrases that were replaced going from `old` to `new`.
    ///
    /// Differences in case and surrounding punctuation are ignored, and pure
    /// insertions or deletions are not reported — only wording that was
    /// swapped for other wording.
    static func substitutions(from old: String, to new: String, maxWords: Int = 1_500) -> [Change] {
        let a = tokens(old)
        let b = tokens(new)
        guard !a.isEmpty, !b.isEmpty, a.count <= maxWords, b.count <= maxWords else { return [] }

        // Longest common subsequence, filled from the end so the walk below
        // can go forwards.
        let n = a.count
        let m = b.count
        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * width + j] = a[i].key == b[j].key
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }

        var changes: [Change] = []
        var removed: [String] = []
        var added: [String] = []
        func flush() {
            if !removed.isEmpty, !added.isEmpty {
                changes.append(Change(from: removed.joined(separator: " "), to: added.joined(separator: " ")))
            }
            removed.removeAll()
            added.removeAll()
        }

        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i].key == b[j].key {
                flush()
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                removed.append(a[i].text)
                i += 1
            } else {
                added.append(b[j].text)
                j += 1
            }
        }
        removed.append(contentsOf: a[i...].map(\.text))
        added.append(contentsOf: b[j...].map(\.text))
        flush()
        return changes
    }

    /// Substitutions worth showing a reader: short, not just a spacing or
    /// casing change, and involving something that looks like a name.
    static func notableSubstitutions(
        from old: String,
        to new: String,
        limit: Int,
        isDictionaryWord: (String) -> Bool
    ) -> [Change] {
        var seen = Set<Change>()
        var result: [Change] = []
        for change in substitutions(from: old, to: new) {
            guard result.count < limit else { break }
            guard wordCount(change.from) <= 4, wordCount(change.to) <= 4,
                  compact(change.from) != compact(change.to),
                  looksLikeTerm(change.to, isDictionaryWord: isDictionaryWord)
                    || looksLikeTerm(change.from, isDictionaryWord: isDictionaryWord),
                  seen.insert(change).inserted
            else { continue }
            result.append(change)
        }
        return result
    }

    /// Names the user typed in place of something else — candidates for the
    /// vocabulary. Only the name-like part of each replacement is returned, so
    /// rewording a sentence does not teach ordinary words.
    static func correctedTerms(
        from old: String,
        to new: String,
        isDictionaryWord: (String) -> Bool
    ) -> [String] {
        let newTokens = tokens(new)
        var seen = Set<String>()
        var result: [String] = []
        for change in substitutions(from: old, to: new) {
            let words = change.to.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count <= 6 else { continue }
            var run: [String] = []
            func flush(reachesEndOfChange: Bool) {
                if reachesEndOfChange {
                    // "cloud code" corrected to "Claude Code" only replaces
                    // one word, but the name is two: take the capitalised
                    // words that follow it in the same sentence.
                    run = extended(run, in: newTokens)
                }
                let term = run.joined(separator: " ")
                if !term.isEmpty, term.count <= 40, seen.insert(term.lowercased()).inserted {
                    result.append(term)
                }
                run.removeAll()
            }
            for word in words {
                if wordLooksLikeTerm(word, isDictionaryWord: isDictionaryWord) {
                    run.append(word)
                } else if !run.isEmpty, run.count < 3, word.first?.isUppercase == true {
                    // A capitalised word straight after a name is part of it.
                    run.append(word)
                } else {
                    flush(reachesEndOfChange: false)
                }
            }
            flush(reachesEndOfChange: true)
        }
        return result
    }

    /// Grows a name with the capitalised words that directly follow its first
    /// occurrence in the text, up to three words and never across a sentence.
    private static func extended(_ name: [String], in text: [Token]) -> [String] {
        guard !name.isEmpty, name.count < 3, text.count > name.count else { return name }
        guard let start = (0...(text.count - name.count)).first(where: { offset in
            zip(name, text[offset...]).allSatisfy { $0 == $1.text }
        }) else { return name }

        var words = name
        var next = start + name.count
        while words.count < 3, next < text.count,
              text[next].text.first?.isUppercase == true,
              !(text[next - 1].raw.last.map { ".!?:;".contains($0) } ?? false) {
            words.append(text[next].text)
            next += 1
        }
        return words
    }

    // MARK: - Term heuristics

    /// True when any word in the phrase looks like a name rather than prose:
    /// mixed case, digits, code punctuation, or simply not a dictionary word.
    static func looksLikeTerm(_ phrase: String, isDictionaryWord: (String) -> Bool) -> Bool {
        phrase.split(whereSeparator: \.isWhitespace).contains {
            wordLooksLikeTerm(String($0), isDictionaryWord: isDictionaryWord)
        }
    }

    static func wordLooksLikeTerm(_ word: String, isDictionaryWord: (String) -> Bool) -> Bool {
        let letterCount = word.reduce(0) { $1.isLetter ? $0 + 1 : $0 }
        guard letterCount > 0 else { return false }                          // "42", "—"
        if word.contains(where: \.isNumber) { return true }                  // v2, S3, gpt-5
        if word.dropFirst().contains(where: \.isUppercase) { return true }   // camelCase, SQL
        if word.contains(where: { "_./:\\".contains($0) }) { return true }   // Node.js, snake_case
        guard letterCount >= 4 else { return false }
        return !isDictionaryWord(word.lowercased())                          // kubectl, Postgres
    }

    /// Letters and digits only, lowercased — "type script" and "TypeScript"
    /// compare equal.
    static func compact(_ phrase: String) -> String {
        String(phrase.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func wordCount(_ phrase: String) -> Int {
        phrase.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Tokenising

    private static let leadingTrim = CharacterSet(charactersIn: "\"'`“”‘’([{<*—–,;:!?")
    private static let trailingTrim = CharacterSet(charactersIn: "\"'`“”‘’)]}>*—–,;:!?.")

    private static func tokens(_ text: String) -> [Token] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let word = trimmed(String(raw))
            guard word.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return Token(raw: String(raw), text: word, key: word.lowercased())
        }
    }

    /// Strips sentence punctuation and quoting from a word's edges while
    /// keeping what belongs to it: ".gitignore", "--flag", "/usr/bin".
    private static func trimmed(_ word: String) -> String {
        var scalars = Substring(word).unicodeScalars
        while let first = scalars.first, leadingTrim.contains(first) { scalars.removeFirst() }
        while let last = scalars.last, trailingTrim.contains(last) { scalars.removeLast() }
        return String(scalars)
    }
}
