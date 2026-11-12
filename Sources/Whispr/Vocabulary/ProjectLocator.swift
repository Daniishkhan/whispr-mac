import ApplicationServices
import Darwin
import Foundation

/// Works out which project folders the app you are dictating into is working
/// in, so their vocabulary can be offered to the recogniser.
///
/// Two signals, neither needing anything from the target app itself:
/// - the focused window's document (terminals and editors publish the current
///   folder or file through Accessibility), and
/// - the working directories of the app's child processes — a terminal's
///   shells, or the agent CLIs an editor or desktop app has spawned.
enum ProjectLocator {

    struct FocusedWindow: Sendable {
        var title: String?
        var documentPath: String?
    }

    // MARK: - Accessibility

    /// Title and document of the app's focused window. Returns empty values
    /// without Accessibility permission. Bounded by a short messaging timeout
    /// so an unresponsive app cannot stall the caller.
    static func focusedWindow(ofAppWithPID pid: pid_t) -> FocusedWindow {
        guard AXIsProcessTrusted() else { return FocusedWindow() }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID()
        else { return FocusedWindow() }
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)

        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        let document = string(kAXDocumentAttribute as String).flatMap { raw -> String? in
            if let url = URL(string: raw), url.isFileURL { return url.path }
            return raw.hasPrefix("/") ? raw : nil
        }
        return FocusedWindow(title: string(kAXTitleAttribute as String), documentPath: document)
    }

    // MARK: - Repositories

    /// Project folders the app is working in, most likely first.
    static func repositories(
        forAppWithPID pid: pid_t,
        window: FocusedWindow,
        limit: Int = 3
    ) -> [URL] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        func note(_ path: String?) {
            guard let path, let root = repositoryRoot(containing: URL(fileURLWithPath: path)) else { return }
            if counts[root.path] == nil { order.append(root.path) }
            counts[root.path, default: 0] += 1
        }

        note(window.documentPath)
        let documentRoot = order.first
        for child in descendants(of: pid) {
            note(workingDirectory(of: child))
        }

        let title = window.title?.lowercased() ?? ""
        func score(_ path: String) -> (Int, Date) {
            let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            var points = 0
            if path == documentRoot { points += 4 }
            if !name.isEmpty, title.contains(name) { points += 2 }
            return (points, lastActivity(inRepositoryAt: path))
        }
        return order
            .map { (path: $0, score: score($0)) }
            .sorted { $0.score.0 != $1.score.0 ? $0.score.0 > $1.score.0 : $0.score.1 > $1.score.1 }
            .prefix(limit)
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    /// The nearest enclosing folder that holds a `.git`. The home folder
    /// itself never counts — a dotfiles repository there would otherwise
    /// claim every shell.
    static func repositoryRoot(containing location: URL) -> URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        var current = location.standardizedFileURL
        if manager.fileExists(atPath: current.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            current = current.deletingLastPathComponent()
        }
        for _ in 0..<24 {
            let path = current.path
            if path == "/" || path == home || path.isEmpty { return nil }
            if manager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// When git last touched the repository — a cheap proxy for "the one
    /// being worked in" when an app has several open.
    private static func lastActivity(inRepositoryAt path: String) -> Date {
        let manager = FileManager.default
        for candidate in [".git/index", ".git/HEAD", ".git"] {
            if let date = (try? manager.attributesOfItem(atPath: path + "/" + candidate))?[.modificationDate] as? Date {
                return date
            }
        }
        return .distantPast
    }

    // MARK: - Processes

    /// Every process below `root` in the process tree.
    static func descendants(of root: pid_t, limit: Int = 400) -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }

        var children: [pid_t: [pid_t]] = [:]
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize {
                children[pid_t(info.pbi_ppid), default: []].append(pid)
            }
        }

        var result: [pid_t] = []
        var queue = [root]
        while let next = queue.popLast(), result.count < limit {
            for child in children[next] ?? [] {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}
