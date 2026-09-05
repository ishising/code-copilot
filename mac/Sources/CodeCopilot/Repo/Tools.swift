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
/// One thing the agent offers to walk, rendered as a button in the panel.
///
/// The agent chooses these, not a heuristic over the file tree: it has just
/// read the summary and is the only thing here that knows which parts of *this*
/// repository are worth an hour. Clicking one sends its label back as a spoken
/// turn, so a click and saying it out loud take exactly the same path.
public struct Route: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let label: String
    public let summary: String
}

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
    private let onRoutes: @MainActor ([Route]) -> Void
    /// The map the agent files each stop into. Optional only so tests can
    /// build the tools without one; the app always passes it.
    private let map: RepoMap?

    public init(
        ref: GitHub.Ref,
        overlay: Overlay,
        cache: [String: String],
        allPaths: [String],
        onActivity: @escaping @MainActor (String) -> Void,
        onRoutes: @escaping @MainActor ([Route]) -> Void = { _ in },
        map: RepoMap? = nil
    ) {
        self.ref = ref
        self.overlay = overlay
        self.cache = cache
        self.allPaths = allPaths
        self.onActivity = onActivity
        self.onRoutes = onRoutes
        self.map = map
    }

    public func agentTools() throws -> [AgentTool] {
        [
            try readFile(),
            try findInRepo(),
            try userFocus(),
            try offerRoutes(),
            try addToMap(),
            try mapSoFar(),
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

    // MARK: - what to walk

    private struct RouteArgs: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let label: String
            let summary: String
        }
        let routes: [Item]
    }

    /// Offered once, at the top of a session. The panel draws a button per
    /// route; the user can still ignore all of them and say what they want.
    private func offerRoutes() throws -> AgentTool {
        try AgentTool.define(
            name: "offer_routes",
            description:
                "Offer the user three to five different ways into this repository, shown "
                + "as buttons they can click. Call this once, at the start, after you have "
                + "said what the software is — then stop talking and wait for them to "
                + "choose. Draw the routes from the summary and make them about genuinely "
                + "different things, not three flavours of how it starts up. At least one "
                + "should be about what the software does rather than how it connects or "
                + "configures itself.",
            input: .object(
                properties: [
                    // The schema builder has no min/max for arrays, so the
                    // count lives in the description where the model reads it.
                    "routes": .array(
                        items: .object(
                            properties: [
                                "label": .string(
                                    description:
                                        "Short button text, a few words, in their language "
                                        + "not the code's. E.g. 'How a question becomes speech'."),
                                "summary": .string(
                                    description:
                                        "One line on what they would come away understanding."),
                            ],
                            required: ["label", "summary"]
                        ),
                        description: "Three to five routes, most interesting first."
                    )
                ],
                required: ["routes"]
            )
        ) { (args: RouteArgs) in
            await MainActor.run {
                let routes = args.routes.map { Route(label: $0.label, summary: $0.summary) }
                self.onRoutes(routes)
                self.onActivity("offered \(routes.count) routes")
                return [
                    "shown": .bool(true),
                    "note": .string(
                        "The buttons are on their screen. Say they can pick one or just "
                            + "tell you what they want, then stop and wait."),
                ]
            }
        }
    }

    // MARK: - the map

    private struct AddToMapArgs: Decodable, Sendable {
        let label: String
        let kind: String?
        let note: String
        let path: String?
        let from_line: Int?
        let to_line: Int?
        let connects_to: String?
        let relationship: String?
    }

    private struct NoArgsAtAll: Decodable, Sendable {}

    /// Filed at every stop, with the connection to an earlier one. This is the
    /// structural enforcement of "nothing stands alone": a node cannot be
    /// filed without saying what it connects to, and the reply pushes back
    /// when it is not.
    private func addToMap() throws -> AgentTool {
        try AgentTool.define(
            name: "add_to_map",
            description:
                "File the stop you just explained into the map the user can review "
                + "later. Call this at EVERY stop, after marking. Give it the name you "
                + "used out loud, one line on what it is for in the world's terms, where "
                + "it lives, and — this is the important part — which earlier stop it "
                + "connects to and how. Filing the same name again updates it and can add "
                + "a new connection, so use it to link things too.",
            input: .object(
                properties: [
                    "label": .string(
                        description:
                            "The name you used out loud, in their language. 'The front "
                            + "desk', 'where the line opens' — not a class name."),
                    "kind": .string(
                        description:
                            "One of: file, concept, layer, step. 'file' for a specific file "
                            + "or lines, 'layer' for a whole part of the system, 'step' for "
                            + "a moment in a flow, 'concept' for anything else."),
                    "note": .string(
                        description: "One line on what it does for the anchor. Plain words."),
                    "path": .string(description: "File path, if it lives in one."),
                    "from_line": .integer(description: "First line, if it lives in a file.", minimum: 1),
                    "to_line": .integer(description: "Last line, if it lives in a file.", minimum: 1),
                    "connects_to": .string(
                        description:
                            "The label of an EARLIER stop this one connects to. Required for "
                            + "every stop after the first — the map is the connections."),
                    "relationship": .string(
                        description:
                            "A short verb phrase for the arrow: 'sends you to', 'is inside', "
                            + "'happens after', 'hides'."),
                ],
                required: ["label", "note"]
            )
        ) { (args: AddToMapArgs) in
            await MainActor.run {
                guard let map = self.map else {
                    return ["added": .bool(false), "reason": .string("no map in this session")]
                }
                let label = args.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else {
                    return ["added": .bool(false), "reason": .string("give the stop a label")]
                }
                let result = map.add(
                    label: label,
                    kind: args.kind.flatMap(RepoMap.Kind.init(rawValue:)),
                    path: args.path,
                    from: args.from_line,
                    to: args.to_line,
                    note: args.note,
                    connectsTo: args.connects_to,
                    relationship: args.relationship
                )
                let link = result.connectedTo.map { " ← \($0.label)" } ?? ""
                self.onActivity("\(result.created ? "mapped" : "updated") \"\(result.node.label)\"\(link)")

                var reply: [String: JSONValue] = [
                    "added": .bool(true),
                    "label": .string(result.node.label),
                    "connected_to": result.connectedTo.map { .string($0.label) } ?? .null,
                    "stops_on_map": .int(map.nodes.count),
                ]
                if let unknown = result.unknownConnection {
                    reply["note"] = .string(
                        "Nothing on the map is called \"\(unknown)\". Existing stops: "
                            + map.nodes.map(\.label).joined(separator: ", ")
                            + ". File it again with one of those as connects_to.")
                } else if result.connectedTo == nil && map.nodes.count > 1 {
                    reply["note"] = .string(
                        "This stop is not connected to anything. Unless it truly stands "
                            + "apart, file it again with connects_to set to an earlier stop.")
                }
                return reply
            }
        }
    }

    private func mapSoFar() throws -> AgentTool {
        try AgentTool.define(
            name: "map_so_far",
            description:
                "Read back the map: every stop filed so far, in order, with its "
                + "connections. Use it for the recap every few stops, and whenever you "
                + "are unsure what has already been covered.",
            input: .object(properties: [:])
        ) { (_: NoArgsAtAll) in
            await MainActor.run {
                guard let map = self.map, !map.isEmpty else {
                    return ["stops": .array([]), "note": .string("nothing mapped yet")]
                }
                let stops: [JSONValue] = map.nodes.sorted { $0.order < $1.order }.map { node in
                    let from: [JSONValue] = map.edges.filter { $0.to == node.id }.map { edge in
                        let source = map.nodes.first { $0.id == edge.from }?.label ?? edge.from
                        return .string(edge.label.map { "\(source) (\($0))" } ?? source)
                    }
                    return .object([
                        "label": .string(node.label),
                        "note": node.note.map { .string($0) } ?? .null,
                        "connected_from": .array(from),
                    ])
                }
                return ["stops": .array(stops), "count": .int(stops.count)]
            }
        }
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
