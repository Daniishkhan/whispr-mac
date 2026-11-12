import Foundation

/// Reads the names a speaker is likely to say out of a project folder: types
/// and functions from recently changed files, file names, dependencies and
/// the terms its agent instructions put in backticks.
///
/// Everything here is read-only and bounded — a handful of short `git`
/// queries and a few small file reads — and is meant to run off the main
/// thread.
enum ProjectHarvester {

    static func harvest(repository: URL) -> ProjectVocabulary {
        let recent = recentlyChangedFiles(in: repository)
        let tracked = trackedFiles(in: repository)
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: repository)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var types: [String] = []
        var functions: [String] = []
        for path in recent.prefix(15) {
            guard let source = readText(repository.appendingPathComponent(path)) else { continue }
            let names = declaredNames(in: source)
            types.append(contentsOf: names.types)
            functions.append(contentsOf: names.functions)
        }

        let stems = recent.prefix(30)
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            .filter(isDistinctiveFileStem)
        let dependencies = dependencyNames(in: repository)
        let documented = documentedTerms(in: repository)

        // Types and file names are what people actually say out loud, so they
        // get two places for every one given to the rest.
        let spoken = unique(
            [repository.lastPathComponent]
                + VocabularyBuilder.woven(
                    primary: VocabularyBuilder.interleaved([types, stems]),
                    secondary: VocabularyBuilder.interleaved([dependencies, documented, functions])
                )
        ).filter(isUsableTerm)

        let directories = unique(tracked.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : nil
        })
        let basenames = (recent.prefix(40) + tracked.prefix(400)).map { URL(fileURLWithPath: $0).lastPathComponent }
        let glossary = unique(
            spoken
                + (branch.map { [$0] } ?? []).filter { $0 != "HEAD" }
                + directories.prefix(20)
                + basenames
        ).filter(isUsableTerm)

        return ProjectVocabulary(
            repository: repository,
            spoken: Array(spoken.prefix(120)),
            glossary: Array(glossary.prefix(VocabularyBuilder.maxGlossaryTerms))
        )
    }

    // MARK: - Files

    /// Files being worked on, most relevant first: uncommitted changes, then
    /// paths touched by the latest commits — limited to files that still
    /// exist. Falls back to a shallow listing without git.
    static func recentlyChangedFiles(in repository: URL) -> [String] {
        let status = git(["status", "--porcelain=v1", "--untracked-files=all"], in: repository) ?? ""
        let log = git(["log", "-n", "40", "--name-only", "--pretty=format:"], in: repository) ?? ""
        let fromGit = unique(uncommittedPaths(fromStatus: status) + lines(log)).filter {
            FileManager.default.fileExists(atPath: repository.appendingPathComponent($0).path)
        }
        return fromGit.isEmpty ? shallowListing(of: repository) : fromGit
    }

    /// Paths from `git status --porcelain=v1` output, skipping deletions.
    static func uncommittedPaths(fromStatus status: String) -> [String] {
        status.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.count > 3 else { return nil }
            let code = line.prefix(2)
            guard !code.contains("D") else { return nil }
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])   // renamed: keep the new name
            }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return path.isEmpty || path.hasSuffix("/") ? nil : path
        }
    }

    static func trackedFiles(in repository: URL) -> [String] {
        let fromGit = lines(git(["ls-files"], in: repository, maxBytes: 524_288) ?? "")
        return fromGit.isEmpty ? shallowListing(of: repository) : fromGit
    }

    private static let skippedDirectories: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "DerivedData", "Pods",
        "target", "vendor", ".venv", "venv", "__pycache__", ".next",
    ]

    /// Top two levels of the folder, newest first, for folders git knows
    /// nothing about.
    private static func shallowListing(of folder: URL) -> [String] {
        let manager = FileManager.default
        var found: [(path: String, modified: Date)] = []
        func visit(_ directory: URL, prefix: String, depth: Int) {
            guard let entries = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries.prefix(300) {
                let name = entry.lastPathComponent
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                if values?.isDirectory == true {
                    if depth < 2, !skippedDirectories.contains(name) {
                        visit(entry, prefix: prefix + name + "/", depth: depth + 1)
                    }
                } else {
                    found.append((prefix + name, values?.contentModificationDate ?? .distantPast))
                }
            }
        }
        visit(folder, prefix: "", depth: 0)
        return found.sorted { $0.modified > $1.modified }.prefix(200).map(\.path)
    }

    private static func readText(_ url: URL, maxBytes: Int = 300_000) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Declarations

    private static let declarationPattern = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:(?:public|private|internal|fileprivate|open|final|static|export|default|async|abstract|pub|override|nonisolated|indirect|@\w+)[ \t]+)*(class|struct|enum|protocol|actor|interface|trait|type|typealias|func|def|function|fn|const)[ \t]+([A-Za-z_][A-Za-z0-9_]{2,})"#
    )

    private static let typeKeywords: Set<String> = [
        "class", "struct", "enum", "protocol", "actor", "interface", "trait", "type", "typealias",
    ]

    private static let boilerplateNames: Set<String> = ["CodingKeys", "PreviewProvider"]

    /// Names declared in a source file, in order of appearance. A name is
    /// kept only when it is distinctive enough to be worth boosting:
    /// `AudioCapture`, `startSession`, `handle_event` — not `Phase`, `run` or
    /// `value`, which are ordinary words the recogniser already gets right.
    static func declaredNames(in source: String) -> (types: [String], functions: [String]) {
        guard let declarationPattern else { return ([], []) }
        var types: [String] = []
        var functions: [String] = []
        let whole = NSRange(source.startIndex..., in: source)
        for match in declarationPattern.matches(in: source, range: whole).prefix(400) {
            guard let kindRange = Range(match.range(at: 1), in: source),
                  let nameRange = Range(match.range(at: 2), in: source)
            else { continue }
            let name = String(source[nameRange])
            guard name.count >= 6, !boilerplateNames.contains(name), !name.hasPrefix("__"),
                  name.dropFirst().contains(where: { $0.isUppercase || $0.isNumber || $0 == "_" })
            else { continue }
            if typeKeywords.contains(String(source[kindRange])) {
                types.append(name)
            } else {
                functions.append(name)
            }
        }
        return (unique(types), unique(functions))
    }

    private static let genericStems: Set<String> = [
        "index", "main", "readme", "license", "makefile", "package", "config", "setup",
        "utils", "util", "types", "test", "tests", "init", "__init__", "app", "mod", "lib",
        "changelog", "dockerfile", "gitignore", "default", "common", "helpers", "constants",
    ]

    /// File names that are ordinary words ("index", "sample", "prepare") are
    /// recognised fine already, and long hyphenated ones are never said as
    /// written; boosting either only spends the keyterm budget.
    static func isDistinctiveFileStem(_ stem: String) -> Bool {
        guard !genericStems.contains(stem.lowercased()), !stem.hasPrefix("."),
              stem.count >= 4, stem.count <= 28,
              stem.filter({ $0 == "-" }).count <= 1
        else { return false }
        return stem.dropFirst().contains(where: { $0.isUppercase || $0.isNumber || $0 == "_" || $0 == "-" })
    }

    // MARK: - Dependencies and documentation

    static func dependencyNames(in repository: URL) -> [String] {
        var names: [String] = []

        if let text = readText(repository.appendingPathComponent("package.json")),
           let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            for key in ["dependencies", "devDependencies"] {
                names.append(contentsOf: ((object[key] as? [String: Any]) ?? [:]).keys.sorted())
            }
        }
        if let text = readText(repository.appendingPathComponent("Package.swift")) {
            names.append(contentsOf: captures(#"url:\s*"[^"]*/([^/"]+?)(?:\.git)?""#, in: text))
        }
        if let text = readText(repository.appendingPathComponent("requirements.txt")) {
            names.append(contentsOf: captures(#"(?m)^\s*([A-Za-z0-9][A-Za-z0-9_.\-]*)"#, in: text))
        }
        if let text = readText(repository.appendingPathComponent("Cargo.toml")) {
            names.append(contentsOf: captures(
                #"(?ms)^\[(?:dev-)?dependencies\]\s*$(.*?)(?=^\[|\z)"#, in: text
            ).flatMap { captures(#"(?m)^\s*([A-Za-z0-9_\-]+)\s*="#, in: $0) })
        }
        if let text = readText(repository.appendingPathComponent("go.mod")) {
            names.append(contentsOf: captures(#"(?m)^\s*(?:require\s+)?[\w.\-]+(?:/[\w.\-]+)*/([\w.\-]+)\s+v\d"#, in: text))
        }
        return Array(unique(names).prefix(40))
    }

    /// Terms the project's own agent instructions put in backticks.
    static func documentedTerms(in repository: URL) -> [String] {
        var terms: [String] = []
        for file in ["CLAUDE.md", "AGENTS.md"] {
            guard let text = readText(repository.appendingPathComponent(file)) else { continue }
            terms.append(contentsOf: captures(#"`([A-Za-z_][A-Za-z0-9_.\-/]{2,39})`"#, in: text))
        }
        // Only what reads as a name; a backticked `main` or `build` is prose.
        let names = terms
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/.")) }
            .filter { $0.dropFirst().contains(where: { $0.isUppercase || $0.isNumber || "_-./".contains($0) }) }
        return Array(unique(names).prefix(40))
    }

    // MARK: - Helpers

    private static func isUsableTerm(_ term: String) -> Bool {
        term.count >= 3 && term.count <= 60 && term.contains(where: \.isLetter)
    }

    private static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func unique(_ items: some Sequence<String>) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - git

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    /// Runs one read-only git query. `GIT_OPTIONAL_LOCKS=0` keeps it from
    /// taking the index lock, so it can never get in the way of a commit the
    /// user (or their agent) is making at the same moment.
    private static func git(
        _ arguments: [String],
        in repository: URL,
        maxBytes: Int = 131_072,
        timeout: TimeInterval = 2
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        let box = OutputBox()
        let finished = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while box.data.count < maxBytes,
                  let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
                box.data.append(chunk)
            }
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            finished.wait()
        }
        if process.isRunning {
            // Stopped reading at the byte cap; the rest is not needed.
            process.terminate()
        }
        process.waitUntilExit()
        guard !box.data.isEmpty else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }
}
