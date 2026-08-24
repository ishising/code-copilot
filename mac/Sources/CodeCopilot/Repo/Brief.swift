import Foundation

/// The repo brief: what the agent knows before the conversation starts.
///
/// A port of `src/repo/brief.ts`. Deliberately deterministic — no model runs
/// here. A realtime voice model has a small working memory and gets slow and
/// vague when it is stuffed, so this is a compact, factual orientation (shape,
/// stack, entry points, README) and nothing more. Detail arrives on demand
/// through `read_file`.
public enum Brief {

    /// Manifests worth reading in full at ingest: each names the language and
    /// lists what the project borrowed rather than built.
    public static let manifests = [
        "package.json", "requirements.txt", "pyproject.toml", "go.mod",
        "Cargo.toml", "Gemfile", "pom.xml", "composer.json",
    ]

    static let readmeBudget = 1500

    public static func build(
        snapshot: GitHub.Snapshot,
        manifests found: [String: String]
    ) -> String {
        let files = snapshot.entries.filter { $0.isFile && !GitHub.isNoise($0.path) }
        var lines: [String] = []

        lines.append(
            "REPOSITORY: \(snapshot.ref.owner)/\(snapshot.ref.repo) (branch \(snapshot.branch))")
        if let description = snapshot.description, !description.isEmpty {
            lines.append("GitHub description: \(description)")
        }

        let (groups, loose) = topLevel(files)
        lines.append(
            "\(files.count) files, \(groups.count) top-level folders"
                + (snapshot.truncated ? " (tree truncated by GitHub — this is a big repo)" : ""))

        lines.append("")
        lines.append("TOP-LEVEL LAYOUT (largest first):")
        for group in groups.prefix(14) {
            lines.append("- \(group.name)/ — \(group.files) files, \(human(group.bytes))")
        }
        if !loose.isEmpty {
            lines.append("- loose files at the root: \(list(loose, max: 12))")
        }

        let stack = manifests.filter { found.keys.contains($0) }
        if !stack.isEmpty {
            lines.append("")
            lines.append("STACK: \(stack.joined(separator: ", ")) present.")
        }
        let deps = dependencies(found)
        if !deps.isEmpty {
            lines.append("DEPENDENCIES (\(deps.count) total): \(list(deps, max: 30))")
        }

        let starts = entryPoints(files)
        if !starts.isEmpty {
            lines.append("")
            lines.append("LIKELY ENTRY POINTS: \(starts.joined(separator: ", "))")
        }

        if let readme = snapshot.readme {
            lines.append("")
            lines.append("README (beginning):")
            lines.append(String(readme.prefix(readmeBudget)))
            if readme.count > readmeBudget {
                lines.append("[README continues — read it with read_file if you need the rest]")
            }
        } else {
            lines.append("")
            lines.append("No README in this repository.")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - shape

    struct Group { let name: String; var files: Int; var bytes: Int }

    /// One line per root folder, biggest first. The single most useful thing
    /// to know about an unfamiliar repository.
    static func topLevel(_ files: [GitHub.TreeEntry]) -> (groups: [Group], loose: [String]) {
        var groups: [String: Group] = [:]
        var loose: [String] = []

        for entry in files {
            guard let slash = entry.path.firstIndex(of: "/") else {
                loose.append(entry.path)
                continue
            }
            let name = String(entry.path[entry.path.startIndex..<slash])
            var group = groups[name] ?? Group(name: name, files: 0, bytes: 0)
            group.files += 1
            group.bytes += entry.size
            groups[name] = group
        }

        return (groups.values.sorted { $0.files > $1.files }, loose.sorted())
    }

    /// Files whose names conventionally mean "start reading here". Shallow
    /// paths first, because a `main.ts` at the root matters more than one six
    /// levels down in a test fixture.
    static func entryPoints(_ files: [GitHub.TreeEntry]) -> [String] {
        let pattern = #"(^|/)(main|index|app|server|cli|__main__|program)\.[a-z]+$"#
        return
            files
            .filter {
                $0.path.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
            .map(\.path)
            .sorted {
                let a = $0.components(separatedBy: "/").count
                let b = $1.components(separatedBy: "/").count
                return a == b ? $0 < $1 : a < b
            }
            .prefix(8)
            .map { $0 }
    }

    /// What a project borrows is the fastest read on what it does, and on how
    /// much of it is custom.
    static func dependencies(_ manifests: [String: String]) -> [String] {
        if let packageJSON = manifests["package.json"],
            let data = packageJSON.data(using: .utf8),
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let runtime = (body["dependencies"] as? [String: Any])?.keys ?? [:].keys
            let dev = (body["devDependencies"] as? [String: Any])?.keys ?? [:].keys
            return Array(runtime) + Array(dev)
        }
        if let requirements = manifests["requirements.txt"] {
            return requirements.split(separator: "\n").compactMap { line in
                let name = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: CharacterSet(charactersIn: "=<>!~[ "))[0]
                return (name.isEmpty || name.hasPrefix("#")) ? nil : name
            }
        }
        return []
    }

    // MARK: - formatting

    static func human(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1000 { return "\(bytes / 1000) KB" }
        return "\(bytes) B"
    }

    static func list(_ items: [String], max limit: Int) -> String {
        if items.isEmpty { return "none found" }
        let shown = items.prefix(limit).joined(separator: ", ")
        let rest = items.count - limit
        return rest > 0 ? "\(shown) (+\(rest) more)" : shown
    }
}
