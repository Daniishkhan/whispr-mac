import AppKit
import Foundation

/// Keeps the vocabulary of the project you are dictating into ready before
/// you press the key.
///
/// Locating the project and harvesting its names takes a few hundred
/// milliseconds, and the recogniser needs its keyterms the instant a session
/// starts — so this refreshes in the background whenever the target app
/// changes and hands back whatever it last resolved.
@MainActor
final class ProjectVocabularyService {

    /// Vocabularies for the current target, most relevant first.
    private(set) var current: [ProjectVocabulary] = []
    var onChange: (() -> Void)?

    private var cache: [String: (vocabulary: ProjectVocabulary, harvestedAt: Date)] = [:]
    private var lastRefresh: (pid: pid_t, at: Date)?
    private var generation = 0

    /// A harvested project is reused for this long before it is read again.
    private static let cacheLifetime: TimeInterval = 120
    /// Re-activating the same app sooner than this does nothing.
    private static let refreshInterval: TimeInterval = 20
    private static let maxProjects = 4

    /// - Parameters:
    ///   - app: the app the dictation will be inserted into.
    ///   - pinnedFolders: folders from Settings that are always included.
    ///   - force: skip the same-app debounce (used when a session starts).
    func refresh(for app: NSRunningApplication?, pinnedFolders: [URL], force: Bool = false) {
        let pid = app?.processIdentifier ?? -1
        let now = Date()
        if !force, let lastRefresh, lastRefresh.pid == pid,
           now.timeIntervalSince(lastRefresh.at) < Self.refreshInterval {
            return
        }
        lastRefresh = (pid, now)
        generation += 1
        let ticket = generation

        let window = pid > 0 ? ProjectLocator.focusedWindow(ofAppWithPID: pid) : ProjectLocator.FocusedWindow()
        let fresh = cache
            .filter { now.timeIntervalSince($0.value.harvestedAt) < Self.cacheLifetime }
            .mapValues(\.vocabulary)
        let limit = Self.maxProjects

        Task.detached(priority: .utility) { [weak self] in
            var folders = pinnedFolders
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .map { ProjectLocator.repositoryRoot(containing: $0) ?? $0 }
            if pid > 0 {
                folders += ProjectLocator.repositories(forAppWithPID: pid, window: window)
            }
            var seen = Set<String>()
            let chosen = folders
                .map(\.standardizedFileURL)
                .filter { seen.insert($0.path).inserted }
                .prefix(limit)
            var harvested: [ProjectVocabulary] = []
            var reused = Set<String>()
            for folder in chosen {
                if let cached = fresh[folder.path] {
                    harvested.append(cached)
                    reused.insert(folder.path)
                } else {
                    harvested.append(ProjectHarvester.harvest(repository: folder))
                }
            }
            await self?.finish(ticket: ticket, vocabularies: harvested, reused: reused, at: now)
        }
    }

    func clear() {
        generation += 1
        lastRefresh = nil
        guard !current.isEmpty else { return }
        current = []
        onChange?()
    }

    private func finish(ticket: Int, vocabularies: [ProjectVocabulary], reused: Set<String>, at date: Date) {
        for vocabulary in vocabularies where !reused.contains(vocabulary.repository.path) {
            cache[vocabulary.repository.path] = (vocabulary, date)
        }
        // A newer refresh has started; let it decide what is current.
        guard ticket == generation, vocabularies != current else { return }
        current = vocabularies
        onChange?()
    }
}
