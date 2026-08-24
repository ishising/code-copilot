import AppKit
import CosmoRealtime
import Foundation

/// What the agent can do: read the repository, search it, find out what the
/// user is looking at — and, through the SDK's own screen tools, mark things
/// on their screen.
///
/// A port of the browser app's `src/repo/tools.ts`, minus the two tools that
/// drove our own viewer. `highlight_lines` and `highlight_path` are gone;
/// `cosmo_sdk_screen_highlight_element` replaces both, and `user_focus` is now
/// answered by the accessibility tree instead of a click handler — which makes
/// it exact rather than a guess.
@MainActor
public final class RepoTools {

    /// A realtime model's working memory is small, so a file arrives in
    /// slices. Past this the model is told to ask for a line range.
    static let textBudget = 8000

    private let ref: GitHub.Ref
    private let overlay: Overlay
    private var cache: [String: String]
    private let allPaths: [String]
    private let onActivity: @MainActor (String) -> Void

    public init(
        ref: GitHub.Ref,
        overlay: Overlay,
        cache: [String: String],
        allPaths: [String],
        onActivity: @escaping @MainActor (String) -> Void
    ) {
        self.ref = ref
        self.overlay = overlay
        self.cache = cache
        self.allPaths = allPaths
        self.onActivity = onActivity
    }

    public func agentTools() throws -> [AgentTool] {
        [
            try readFile(),
            try findInRepo(),
            try userFocus(),
            // The SDK's own screen surface. `screenLocate` answers the capture
            // RPC the server-side locator drives; `screenHighlightElement`
            // renders what it found. No click tool: the user does the acting.
            .screenLocate(capture: { [onActivity] request in
                do {
                    let capture = try await Capture.snapshot(request)
                    await MainActor.run { onActivity(Capture.lastLook) }
                    return capture
                } catch {
                    // A failed look is the most important thing to surface: it
                    // is why the agent describes instead of pointing, and it
                    // otherwise leaves no trace anywhere the user can see.
                    let why = (error as? ScreenCaptureUnavailable)?.message ?? "\(error)"
                    await MainActor.run { onActivity("couldn't see the screen — \(why)") }
                    throw error
                }
            }),
            .screenHighlightElement { [overlay, onActivity] request in
                await MainActor.run {
                    let outcome = overlay.mark(request.element, label: request.label)
                    let name = request.element.title ?? request.element.label ?? request.element.role
                    onActivity(outcome.shown ? "marked \(name)" : "could not mark \(name)")
                    // A grounded handle is on a real control, so this is
                    // `landedOnControl` rather than an estimate. The refusal
                    // reason is model-facing: it is what the agent says out
                    // loud, so it reads as an instruction, not an error code.
                    return outcome.shown
                        ? .landedOnControl
                        : .notShown(outcome.reason ?? "I couldn't draw on that.")
                }
            },
        ]
    }

    // MARK: - reading the repository

    private struct ReadArgs: Decodable, Sendable {
        let path: String
        let from_line: Int?
        let to_line: Int?
    }

    private func readFile() throws -> AgentTool {
        try AgentTool.define(
            name: "read_file",
            description:
                "Read the real text of one file in the repository. Give a line range for a "
                + "long file. Use this before describing what any code does — you are "
                + "reading the actual file, not guessing from its name.",
            input: .object(
                properties: [
                    "path": .string(description: "Path from the repository root."),
                    "from_line": .integer(
                        description: "First line to return. Omit to start at the top.",
                        minimum: 1),
                    "to_line": .integer(
                        description: "Last line to return. Omit for as much as fits.",
                        minimum: 1),
                ],
                required: ["path"]
            )
        ) { args in
            // Strong capture, deliberately. These closures are owned by the
            // agent and this object never stores them back, so there is no
            // retain cycle — while a weak capture meant the tools quietly
            // stopped working the moment whoever built them went out of scope.
            await self.read(args)
        }
    }

    private func read(_ args: ReadArgs) async -> [String: JSONValue] {
        do {
            let text = try await textOf(args.path)
            let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let from = max(1, args.from_line ?? 1)
            let to = min(all.count, args.to_line ?? all.count)
            guard from <= to else {
                return ["path": .string(args.path), "error": .string("empty line range")]
            }

            var body = all[(from - 1)..<to].joined(separator: "\n")
            var truncated = false
            if body.count > Self.textBudget {
                body = String(body.prefix(Self.textBudget))
                truncated = true
            }

            onActivity("read \(args.path) lines \(from)-\(to)")
            return [
                "path": .string(args.path),
                "total_lines": .int(all.count),
                "from_line": .int(from),
                "to_line": .int(to),
                "truncated": .bool(truncated),
                "text": .string(body),
            ]
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "could not read"
            onActivity("could not read \(args.path) — \(reason)")
            return ["path": .string(args.path), "error": .string(reason)]
        }
    }

    private func textOf(_ path: String) async throws -> String {
        if let hit = cache[path] { return hit }
        let text = try await GitHub.file(ref, path: path).text
        cache[path] = text
        return text
    }

    // MARK: - search

    private struct FindArgs: Decodable, Sendable { let query: String }

    private func findInRepo() throws -> AgentTool {
        try AgentTool.define(
            name: "find_in_repo",
            description:
                "Search the repository for a word — a function name, a route, a filename. "
                + "Returns matching files with line numbers. This is how you follow a flow: "
                + "search for where something is defined, then where it is called. Use it "
                + "instead of guessing a path.",
            input: .object(
                properties: [
                    "query": .string(
                        description: "What to look for, e.g. 'checkPassword' or '/api/login'.",
                        minLength: 2)
                ],
                required: ["query"]
            )
        ) { (args: FindArgs) in
            await MainActor.run { self.find(args.query) }
        }
    }

    private func find(_ query: String) -> [String: JSONValue] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else {
            return ["query": .string(query), "note": .string("query too short")]
        }

        let paths = allPaths.filter { $0.lowercased().contains(needle) }.prefix(10)

        var matches: [JSONValue] = []
        outer: for (path, text) in cache {
            for (index, line) in text.split(
                separator: "\n", omittingEmptySubsequences: false
            ).enumerated() {
                guard line.lowercased().contains(needle) else { continue }
                matches.append(
                    .object([
                        "path": .string(path),
                        "line": .int(index + 1),
                        "text": .string(String(line.trimmingCharacters(in: .whitespaces).prefix(160))),
                    ]))
                if matches.count >= 25 { break outer }
            }
        }

        onActivity("searched for \"\(query)\" — \(matches.count) hits")
        var result: [String: JSONValue] = [
            "query": .string(query),
            "matching_paths": .array(paths.map { .string($0) }),
            "matches": .array(matches),
            "searched_files": .int(cache.count),
        ]
        if matches.isEmpty && paths.isEmpty {
            result["note"] = .string("nothing found — try a shorter or different word")
        }
        return result
    }

    // MARK: - what the user is looking at

    private struct NoArgs: Decodable, Sendable {}

    private func userFocus() throws -> AgentTool {
        try AgentTool.define(
            name: "user_focus",
            description:
                "Find out what the user is currently looking at and what they have "
                + "selected or clicked on screen. Call this FIRST whenever they say "
                + "\"this\", \"that\", \"here\" or otherwise point without naming what "
                + "they mean.",
            input: .object(properties: [:])
        ) { (_: NoArgs) in
            await MainActor.run { self.focus() }
        }
    }

    private func focus() -> [String: JSONValue] {
        guard AXIsProcessTrusted() else {
            return [
                "error": .string(
                    "I can't read the screen — Accessibility permission isn't granted.")
            ]
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ["error": .string("nothing is frontmost")]
        }

        let (element, selected) = AXWalk.focus(forPID: app.processIdentifier)
        var result: [String: JSONValue] = [
            "frontmost_app": .string(app.localizedName ?? "unknown")
        ]
        if let element {
            result["focused_role"] = .string(element.role)
            if let title = element.title { result["focused_title"] = .string(title) }
            if let value = element.value { result["focused_text"] = .string(value) }
        }
        result["selected_text"] = selected.map { .string($0) } ?? .null
        if element == nil && selected == nil {
            result["note"] = .string(
                "nothing specific is focused — ask them to click on what they mean")
        }
        return result
    }
}
