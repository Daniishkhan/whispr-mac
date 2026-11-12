import Foundation

/// Keeps the last 100 inserted transcripts in a JSON file under
/// ~/Library/Application Support/Whispr. Can be disabled in Settings.
///
/// Each entry also keeps what the recogniser heard and what the polish step
/// produced. Together with the final text (what was actually inserted, after
/// any edits) that is a record of where each stage went wrong — the material
/// for judging a change to the prompt, the model or the vocabulary.
/// (All state lives in the file; the class only holds immutable paths.)
final class HistoryStore: @unchecked Sendable {

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let date: Date
        /// The text that was inserted or copied.
        let text: String
        /// The transcript as recognised, before any polish or editing.
        var raw: String?
        /// The polish model's output, when polish ran.
        var polished: String?
        /// The app the dictation was aimed at.
        var target: String?
        var timings: Timings?

        init(
            text: String,
            raw: String? = nil,
            polished: String? = nil,
            target: String? = nil,
            timings: Timings? = nil
        ) {
            self.id = UUID()
            self.date = Date()
            self.text = text
            self.raw = raw
            self.polished = polished
            self.target = target
            self.timings = timings
        }
    }

    /// How long the wait between releasing the key and seeing the preview
    /// took, and why the first part ended.
    struct Timings: Codable, Equatable, Sendable {
        /// Key release until the transcript was complete.
        var finishMs: Int?
        /// What ended that wait: "finalize", "metadata", "closed" or "timeout".
        var finishReason: String?
        /// The polish request, when one was made.
        var polishMs: Int?
    }

    static let shared = HistoryStore()

    private let fileURL: URL
    private let maxEntries = 100

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Whispr", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("history.json")
    }

    func load() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    func add(_ entry: Entry) -> [Entry] {
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
        return entries
    }

    func clear() {
        save([])
    }

    private func save(_ entries: [Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
