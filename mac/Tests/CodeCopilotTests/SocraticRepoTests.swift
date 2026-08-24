import Foundation
import Testing

@testable import CodeCopilot

/// The repository that failed: a private monorepo in an organisation whose
/// policy rejects personal access tokens.
@Suite("Private monorepo access")
struct SocraticRepoTests {

    static let url = "https://github.com/socratic-ai/cosmo/tree/main/sdks/cosmo-realtime"

    @Test("a /tree/ URL yields the subfolder, not just the repo")
    func parsesSubpath() throws {
        let ref = try #require(GitHub.parseRef(Self.url))
        #expect(ref.owner == "socratic-ai")
        #expect(ref.repo == "cosmo")
        #expect(ref.subpath == "sdks/cosmo-realtime")
    }

    @Test("a plain repo URL has no subpath")
    func noSubpath() {
        #expect(GitHub.parseRef("https://github.com/socratic-ai/cosmo")?.subpath == nil)
    }

    @Test("the GitHub CLI credential is found")
    func findsCLIToken() {
        #expect(GitHubCLI.executable != nil, "gh not found in \(GitHubCLI.candidates)")
        #expect(GitHubCLI.token() != nil, "gh is present but not signed in")
        #expect(Config.current.githubToken != nil)
        print("token source:", Config.current.sources["GitHub token"] ?? "?")
    }

    @Test("the private monorepo reads, scoped to the subfolder")
    func readsScoped() async throws {
        let ref = try #require(GitHub.parseRef(Self.url))
        do {
            let scoped = try await GitHub.snapshot(ref)
            let whole = try await GitHub.snapshot(
                GitHub.Ref(owner: ref.owner, repo: ref.repo))
            print("whole repo: \(whole.entries.count) entries")
            print("scoped to \(ref.subpath ?? "-"): \(scoped.entries.count) entries")
            #expect(!scoped.entries.isEmpty)
            #expect(scoped.entries.count < whole.entries.count)
            #expect(scoped.entries.allSatisfy { $0.path.hasPrefix("sdks/cosmo-realtime") })
        } catch let error as NSError where error.domain == NSURLErrorDomain {
            print("skipped — no network")
        }
    }
}
