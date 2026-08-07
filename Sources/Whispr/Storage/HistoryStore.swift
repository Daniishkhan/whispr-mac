import Foundation

/// Keeps the last 100 inserted transcripts in a JSON file under
/// ~/Library/Application Support/Whispr. Can be disabled in Settings.
/// (All state lives in the file; the class only holds immutable paths.)
final class HistoryStore: @unchecked Sendable {

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        let date: Date
        let text: String

        init(text: String) {
            self.id = UUID()
            self.date = Date()
            self.text = text
        }
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

    func add(_ text: String) -> [Entry] {
        var entries = load()
        entries.insert(Entry(text: text), at: 0)
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
