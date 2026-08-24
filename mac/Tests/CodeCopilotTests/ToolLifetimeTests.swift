import CosmoRealtime
import Testing

@testable import CodeCopilot

/// The tools must outlive whoever built them.
///
/// They did not. The handlers captured `RepoTools` weakly, and `Conductor`
/// built it as a local, so the object died the moment the connect function
/// returned. Every subsequent call answered `{"error": "gone"}` — the agent
/// could see the file tree and could not open a single file, and said so.
///
/// This is worth a test because nothing about it is visible at the call site:
/// it compiles, connects, and only fails once the model reaches for a tool.
@MainActor
@Suite("Tool lifetime")
struct ToolLifetimeTests {

    /// Build the tools inside a scope and let their owner fall out of it —
    /// exactly the condition that broke.
    private func specsFromADeadScope() throws -> [AgentTool] {
        let tools = RepoTools(
            ref: GitHub.Ref(owner: "someone", repo: "something"),
            overlay: Overlay(),
            cache: ["notes.txt": "first line\nsecond line\nthird line"],
            allPaths: ["notes.txt"],
            onActivity: { _ in }
        )
        return try tools.agentTools()
    }

    private func handler(named name: String, in specs: [AgentTool]) throws -> ClientToolHandler {
        for spec in specs {
            if case .client(let toolName, _, _, let handler) = spec,
                toolName == name, let handler
            {
                return handler
            }
        }
        throw TestFailure(message: "no handler for \(name)")
    }

    struct TestFailure: Error { let message: String }

    @Test("read_file still works after its owner goes out of scope")
    func readSurvives() async throws {
        let specs = try specsFromADeadScope()
        let read = try handler(named: "read_file", in: specs)

        let result = try await read(["path": .string("notes.txt")])

        #expect(result["error"] == nil, "tool answered with an error: \(result)")
        #expect(result["text"] == .string("first line\nsecond line\nthird line"))
        #expect(result["total_lines"] == .int(3))
    }

    @Test("find_in_repo still returns matches after its owner goes out of scope")
    func searchSurvives() async throws {
        let specs = try specsFromADeadScope()
        let find = try handler(named: "find_in_repo", in: specs)

        let result = try await find(["query": .string("second")])

        guard case .array(let matches)? = result["matches"] else {
            throw TestFailure(message: "no matches key: \(result)")
        }
        // The weak-capture bug returned an empty array here rather than an
        // error, which would have looked like "nothing found" forever.
        #expect(matches.count == 1, "expected one hit, got \(matches.count)")
    }

    @Test("user_focus answers rather than reporting a dead object")
    func focusSurvives() async throws {
        let specs = try specsFromADeadScope()
        let focus = try handler(named: "user_focus", in: specs)

        let result = try await focus([:])

        // It may legitimately report missing Accessibility permission; what it
        // must never do is report that its own implementation has vanished.
        #expect(result["error"] != .string("gone"))
        #expect(!result.isEmpty)
    }
}
