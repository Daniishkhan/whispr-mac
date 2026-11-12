import Foundation

/// Names harvested from one project folder.
struct ProjectVocabulary: Equatable, Sendable {
    /// The folder they came from.
    var repository: URL
    /// Names worth boosting during recognition, most useful first: types,
    /// functions, distinctive file names, dependencies.
    var spoken: [String]
    /// A wider list for the polish model, which can also use file names with
    /// their extensions, directory names and the branch.
    var glossary: [String]

    var name: String { repository.lastPathComponent }
}

/// The two word lists a dictation needs.
struct VocabularyLists: Equatable, Sendable {
    /// Sent to Deepgram as Nova-3 keyterms.
    var keyterms: [String]
    /// Sent to the polish model as known-correct spellings.
    var glossary: [String]
    /// How many keyterms were added automatically (learned or from a project)
    /// rather than typed into Settings.
    var automaticKeytermCount: Int
}

/// Merges the user's own vocabulary, terms learned from their corrections and
/// terms harvested from the project into the lists each service gets.
enum VocabularyBuilder {

    /// Deepgram rejects a connection whose keyterms exceed 500 tokens in
    /// total, and it does not publish its tokenizer — so automatic terms are
    /// admitted against a deliberately pessimistic estimate and a lower cap.
    static let keytermTokenBudget = 450
    static let maxKeyterms = 100
    static let maxLearnedKeyterms = 30
    static let maxProjectKeyterms = 40
    static let maxGlossaryTerms = 250

    /// Roughly one token per three characters plus one: identifiers split
    /// into more pieces than prose does.
    static func estimatedTokens(_ term: String) -> Int {
        max(1, (term.count + 2) / 3) + 1
    }

    /// - Parameters:
    ///   - manual: the Vocabulary list from Settings, always sent in full.
    ///   - learned: terms picked up from the user's corrections, newest first.
    ///   - project: harvested project vocabularies, most relevant first.
    ///   - automaticKeyterms: false sends only `manual` to Deepgram.
    static func build(
        manual: [String],
        learned: [String],
        project: [ProjectVocabulary],
        automaticKeyterms: Bool = true
    ) -> VocabularyLists {
        var keyterms: [String] = []
        var keytermKeys = Set<String>()
        var tokens = 0

        for term in manual.prefix(maxKeyterms) where keytermKeys.insert(term.lowercased()).inserted {
            keyterms.append(term)
            tokens += estimatedTokens(term)
        }
        let manualCount = keyterms.count

        func admit(_ candidates: [String], limit: Int) {
            var admitted = 0
            for term in candidates {
                guard admitted < limit, keyterms.count < maxKeyterms else { return }
                let cost = estimatedTokens(term)
                guard term.count <= 40, tokens + cost <= keytermTokenBudget,
                      keytermKeys.insert(term.lowercased()).inserted
                else { continue }
                keyterms.append(term)
                tokens += cost
                admitted += 1
            }
        }
        if automaticKeyterms {
            admit(learned, limit: maxLearnedKeyterms)
            admit(weighted(project.map(\.spoken)), limit: maxProjectKeyterms)
        }

        var glossary: [String] = []
        var glossaryKeys = Set<String>()
        for term in manual + learned + weighted(project.map(\.glossary)) {
            guard glossary.count < maxGlossaryTerms else { break }
            if glossaryKeys.insert(term.lowercased()).inserted {
                glossary.append(term)
            }
        }

        return VocabularyLists(
            keyterms: keyterms,
            glossary: glossary,
            automaticKeytermCount: keyterms.count - manualCount
        )
    }

    /// The first list is the most likely project, so it gets two places for
    /// every one shared among the others.
    static func weighted(_ lists: [[String]]) -> [String] {
        guard let first = lists.first else { return [] }
        return woven(primary: first, secondary: interleaved(Array(lists.dropFirst())))
    }

    /// Two from `primary` for every one from `secondary`, until both run out.
    static func woven(primary: [String], secondary: [String]) -> [String] {
        var result: [String] = []
        var p = primary[...]
        var s = secondary[...]
        while !p.isEmpty || !s.isEmpty {
            result.append(contentsOf: p.prefix(2))
            p = p.dropFirst(2)
            result.append(contentsOf: s.prefix(1))
            s = s.dropFirst(1)
        }
        return result
    }

    /// Round-robin across lists so one large project cannot crowd out another.
    static func interleaved(_ lists: [[String]]) -> [String] {
        var result: [String] = []
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count {
                result.append(list[index])
            }
        }
        return result
    }
}
