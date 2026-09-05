import AppKit
import Foundation
import Observation

/// The map: what has been walked, and how the pieces connect.
///
/// A port of the web app's `src/repo/map.ts`, with the same two jobs. During a
/// session it is the picture a spoken walk cannot leave behind — the agent
/// files every stop here *with* its connection to an earlier one, which is the
/// structural enforcement of "nothing stands alone". Afterwards it is the
/// thing to review: it persists per repository under Application Support, so
/// the next session opens with what was already covered, and it exports as
/// Markdown with a Mermaid diagram that GitHub renders.
///
/// The Mac app draws no diagram of its own. Bundling a renderer to show a
/// flowchart in a panel this small is not worth it; the export opens in
/// whatever the user reads Markdown with, and the count in the panel is
/// enough to know the map is growing.
@MainActor
@Observable
public final class RepoMap {

    public enum Kind: String, Codable, Sendable { case file, concept, layer, step }

    public struct Node: Codable, Identifiable, Sendable {
        public var id: String
        public var label: String
        public var kind: Kind
        public var path: String?
        public var from: Int?
        public var to: Int?
        /// One line, in the world's terms, on what this is for.
        public var note: String?
        /// Insertion order — the order the walk visited things.
        public var order: Int

        var whereText: String {
            guard let path else { return "" }
            guard let from else { return path }
            if let to, to != from { return "\(path):\(from)-\(to)" }
            return "\(path):\(from)"
        }
    }

    public struct Edge: Codable, Sendable {
        public var from: String
        public var to: String
        public var label: String?
    }

    struct Data: Codable {
        var repo: String
        var nodes: [Node]
        var edges: [Edge]
        var updated: Double
    }

    public struct AddResult: Sendable {
        public let node: Node
        public let created: Bool
        public let connectedTo: Node?
        /// Set when `connectsTo` named something that is not on the map.
        public let unknownConnection: String?
    }

    static let briefBudget = 1400

    public let key: String
    private(set) var data: Data

    public var nodes: [Node] { data.nodes }
    public var edges: [Edge] { data.edges }
    public var isEmpty: Bool { data.nodes.isEmpty }
    public var updatedAt: Date? { data.updated == 0 ? nil : Date(timeIntervalSince1970: data.updated) }

    // MARK: - files

    public static let directory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/CodeCopilot/maps")

    public static func key(for ref: GitHub.Ref) -> String {
        let base = "\(ref.owner)/\(ref.repo)"
        guard let subpath = ref.subpath else { return base }
        return "\(base)/\(subpath)"
    }

    private static func filename(_ key: String) -> String {
        key.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "__", options: .regularExpression)
    }

    var jsonURL: URL { Self.directory.appending(path: "\(Self.filename(key)).json") }
    public var markdownURL: URL { Self.directory.appending(path: "\(Self.filename(key)).md") }

    public init(key: String) {
        self.key = key
        self.data = Data(repo: key, nodes: [], edges: [], updated: 0)
        if let raw = try? Foundation.Data(contentsOf: jsonURL),
            let loaded = try? JSONDecoder().decode(Data.self, from: raw)
        {
            data = loaded
        }
    }

    private func save() {
        data.updated = Date().timeIntervalSince1970
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(data).write(to: jsonURL, options: .atomic)
        } catch {
            // Persistence is a convenience. The map still works for this
            // session; it just won't be there next time.
        }
    }

    // MARK: - reading

    /// A stable identifier from a label. Prefixed so it can never collide with
    /// Mermaid's own keywords (`end`, `graph`, `click`) — a node called "end"
    /// would otherwise break the diagram.
    static func slug(_ label: String) -> String {
        var base = label.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        base = String(base.prefix(40))
        return "n_\(base.isEmpty ? "node" : base)"
    }

    /// Lenient lookup: id, then exact label, then the best partial match. The
    /// agent refers back to things by what it called them out loud, which is
    /// rarely character-perfect.
    public func find(_ nameOrID: String) -> Node? {
        let needle = nameOrID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        if let byID = data.nodes.first(where: { $0.id == nameOrID || $0.id == Self.slug(nameOrID) }) {
            return byID
        }
        if let exact = data.nodes.first(where: { $0.label.lowercased() == needle }) {
            return exact
        }
        return data.nodes
            .filter {
                let label = $0.label.lowercased()
                return label.contains(needle) || needle.contains(label)
            }
            .max(by: { $0.label.count < $1.label.count })
    }

    // MARK: - writing

    @discardableResult
    public func add(
        label rawLabel: String,
        kind: Kind? = nil,
        path: String? = nil,
        from: Int? = nil,
        to: Int? = nil,
        note: String? = nil,
        connectsTo: String? = nil,
        relationship: String? = nil
    ) -> AddResult {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)

        var created = false
        let index: Int
        if let existing = data.nodes.firstIndex(where: { $0.label.lowercased() == label.lowercased() }) {
            // Filing the same thing twice is a correction, not a duplicate:
            // keep the node, take any new detail, and allow a new connection.
            index = existing
            if let kind { data.nodes[index].kind = kind }
            if let path { data.nodes[index].path = path }
            if let from { data.nodes[index].from = from }
            if let to { data.nodes[index].to = to }
            if let cleanNote, !cleanNote.isEmpty { data.nodes[index].note = cleanNote }
        } else {
            var id = Self.slug(label)
            while data.nodes.contains(where: { $0.id == id }) { id = "\(id)_\(data.nodes.count)" }
            data.nodes.append(
                Node(
                    id: id, label: label, kind: kind ?? .concept, path: path, from: from, to: to,
                    note: (cleanNote?.isEmpty == false) ? cleanNote : nil, order: data.nodes.count))
            index = data.nodes.count - 1
            created = true
        }
        let node = data.nodes[index]

        var connectedTo: Node? = nil
        var unknown: String? = nil
        if let connectsTo, !connectsTo.trimmingCharacters(in: .whitespaces).isEmpty {
            if let target = find(connectsTo), target.id != node.id {
                connectedTo = target
                let duplicate = data.edges.contains { $0.from == target.id && $0.to == node.id }
                if !duplicate {
                    let rel = relationship?.trimmingCharacters(in: .whitespaces)
                    data.edges.append(
                        Edge(from: target.id, to: node.id, label: (rel?.isEmpty == false) ? rel : nil))
                }
            } else if find(connectsTo) == nil {
                unknown = connectsTo
            }
        }

        save()
        return AddResult(node: node, created: created, connectedTo: connectedTo, unknownConnection: unknown)
    }

    public func clear() {
        data = Data(repo: key, nodes: [], edges: [], updated: 0)
        try? FileManager.default.removeItem(at: jsonURL)
        try? FileManager.default.removeItem(at: markdownURL)
    }

    // MARK: - rendering

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "#quot;").replacingOccurrences(of: "\n", with: "<br/>")
    }

    /// Mermaid source. Labels are quoted, and quotes inside them escaped the
    /// way Mermaid wants, so a label like `the "front desk"` cannot break the
    /// whole diagram.
    public func toMermaid() -> String {
        var lines = ["flowchart TD"]
        let style: [Kind: String] = [
            .file: "fill:#161a23,stroke:#6ea8fe,color:#e6e9ef",
            .layer: "fill:#1d1a12,stroke:#ffd479,color:#e6e9ef",
            .concept: "fill:#141821,stroke:#5c6675,color:#e6e9ef",
            .step: "fill:#141821,stroke:#5ad19b,color:#e6e9ef",
        ]
        for node in data.nodes {
            let title = node.path == nil ? node.label : "\(node.label)\n\(node.whereText)"
            lines.append("  \(node.id)[\"\(Self.escape(title))\"]")
            lines.append("  style \(node.id) \(style[node.kind] ?? "")")
        }
        for edge in data.edges {
            if let label = edge.label {
                lines.append("  \(edge.from) -->|\"\(Self.escape(label))\"| \(edge.to)")
            } else {
                lines.append("  \(edge.from) --> \(edge.to)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The review document: the diagram GitHub will render, then every stop
    /// with its one-line meaning and exactly where it lives.
    public func toMarkdown() -> String {
        let when = updatedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "never"
        let rows = data.nodes.sorted { $0.order < $1.order }.enumerated().map { index, node in
            let place = node.path == nil ? "" : "`\(node.whereText)`"
            return "| \(index + 1) | **\(node.label)** | \(node.note ?? "") | \(place) |"
        }
        return (
            [
                "# Map of \(data.repo)", "",
                "_Updated \(when). \(data.nodes.count) stops, \(data.edges.count) connections._", "",
                "```mermaid", toMermaid(), "```", "",
                "| # | Stop | What it is for | Where |",
                "| --- | --- | --- | --- |",
            ] + rows + [""]
        ).joined(separator: "\n")
    }

    /// Write the review document and hand back where it went, so the panel can
    /// open it in whatever reads Markdown here.
    @discardableResult
    public func exportMarkdown() throws -> URL {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try toMarkdown().write(to: markdownURL, atomically: true, encoding: .utf8)
        return markdownURL
    }

    /// What the agent is told at the start of a later session. Compact: a
    /// realtime model's working memory is small, and this is orientation.
    public func briefSection() -> String {
        guard !isEmpty else { return "" }
        let stops = data.nodes.sorted { $0.order < $1.order }.map { node -> String in
            let inbound = data.edges.first { $0.to == node.id }
            let fromLabel = inbound.flatMap { edge in data.nodes.first { $0.id == edge.from }?.label }
            var line = "- \(node.label)"
            if let fromLabel {
                line += " (\(inbound?.label.map { "\($0) ←" } ?? "from") \(fromLabel))"
            }
            if let note = node.note { line += " — \(note)" }
            return line
        }
        var body = stops.joined(separator: "\n")
        if body.count > Self.briefBudget { body = String(body.prefix(Self.briefBudget)) + "\n- …" }
        return """
            MAP FROM EARLIER SESSIONS — what this person has already walked, in
            order, with how each stop connected to the one before. Continue from
            here rather than starting again, unless they ask for something new:
            \(body)
            """
    }
}
