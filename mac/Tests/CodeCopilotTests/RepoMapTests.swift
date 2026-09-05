import Foundation
import Testing

@testable import CodeCopilot

/// The map is what the user reviews afterwards, so the things that would
/// quietly corrupt it — a duplicate stop, a lost connection, a label that
/// breaks the diagram — are the things worth pinning down.
@MainActor
@Suite("Repo map")
struct RepoMapTests {

    /// A unique key per test so nothing on disk is shared or left behind.
    private func fresh() -> RepoMap {
        RepoMap(key: "test/\(UUID().uuidString)")
    }

    @Test("slugs are stable, punctuation-free, and never a Mermaid keyword")
    func slugs() {
        #expect(RepoMap.slug("The \"front desk\"") == "n_the_front_desk")
        #expect(RepoMap.slug("end") == "n_end")
        #expect(RepoMap.slug("!!!") == "n_node")
    }

    @Test("the first stop stands alone; the second connects by a loose name")
    func connects() {
        let map = fresh()
        defer { map.clear() }

        let first = map.add(label: "The front desk", kind: .layer, path: "src/client.ts", from: 10, to: 20, note: "checks your pass")
        #expect(first.created)
        #expect(first.connectedTo == nil)

        let second = map.add(
            label: "Where the line opens", kind: .step, path: "src/agent.ts", from: 5, to: 9,
            note: "dials the number", connectsTo: "front desk", relationship: "sends you to")
        #expect(second.created)
        #expect(second.connectedTo?.label == "The front desk")
        #expect(map.edges.count == 1)
        #expect(map.edges.first?.label == "sends you to")
    }

    @Test("filing the same label again updates rather than duplicates, and does not double the edge")
    func merges() {
        let map = fresh()
        defer { map.clear() }
        map.add(label: "A", note: "one")
        map.add(label: "B", note: "two", connectsTo: "A", relationship: "then")

        let again = map.add(label: "b", note: "two, revised", connectsTo: "A", relationship: "then")
        #expect(!again.created)
        #expect(map.nodes.count == 2)
        #expect(again.node.note == "two, revised")
        #expect(map.edges.count == 1)
    }

    @Test("a connection to nothing on the map is reported, not invented")
    func unknownConnection() {
        let map = fresh()
        defer { map.clear() }
        map.add(label: "A", note: "one")
        let result = map.add(label: "C", note: "three", connectsTo: "nothing like this")
        #expect(result.unknownConnection == "nothing like this")
        #expect(result.connectedTo == nil)
        #expect(map.edges.isEmpty)
    }

    @Test("mermaid output is well-formed, with quotes escaped")
    func mermaid() {
        let map = fresh()
        defer { map.clear() }
        map.add(label: "a \"quoted\" name", kind: .file, path: "x.ts", from: 1, to: 3, note: "n")
        map.add(label: "next", note: "n", connectsTo: "quoted", relationship: "sends to")

        let text = map.toMermaid()
        #expect(text.hasPrefix("flowchart TD"))
        #expect(text.contains("#quot;quoted#quot;"))
        #expect(text.contains("x.ts:1-3"))
        #expect(text.contains("-->|\"sends to\"| n_next"))
        // No raw double quote may survive inside a node label.
        #expect(!text.contains("[\"a \"quoted\""))
    }

    @Test("the brief lists stops in walk order with their relationships, or nothing at all")
    func brief() {
        let empty = fresh()
        #expect(empty.briefSection() == "")

        let map = fresh()
        defer { map.clear() }
        map.add(label: "First", note: "one")
        map.add(label: "Second", note: "two", connectsTo: "First", relationship: "leads to")
        let brief = map.briefSection()
        let firstAt = brief.range(of: "First")!.lowerBound
        let secondAt = brief.range(of: "- Second")!.lowerBound
        #expect(firstAt < secondAt)
        #expect(brief.contains("leads to"))
    }

    @Test("markdown carries the diagram and one row per stop")
    func markdown() {
        let map = fresh()
        defer { map.clear() }
        map.add(label: "The front desk", path: "src/client.ts", from: 10, to: 20, note: "checks your pass")
        let md = map.toMarkdown()
        #expect(md.contains("```mermaid"))
        #expect(md.contains("| 1 | **The front desk** | checks your pass | `src/client.ts:10-20` |"))
    }

    @Test("the map survives a restart and clear() removes it")
    func persists() throws {
        let key = "test/\(UUID().uuidString)"
        let map = RepoMap(key: key)
        map.add(label: "Kept", note: "should be here next time")
        #expect(FileManager.default.fileExists(atPath: map.jsonURL.path))

        let reopened = RepoMap(key: key)
        #expect(reopened.nodes.count == 1)
        #expect(reopened.nodes.first?.label == "Kept")

        _ = try reopened.exportMarkdown()
        #expect(FileManager.default.fileExists(atPath: reopened.markdownURL.path))

        reopened.clear()
        #expect(reopened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: reopened.jsonURL.path))
        #expect(!FileManager.default.fileExists(atPath: reopened.markdownURL.path))
    }
}
