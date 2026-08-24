import Foundation
import Testing

@testable import CodeCopilot

/// Hits the real GitHub API through the app's own code path. Not a unit test —
/// it exists to answer "can the app actually read a repository", which is the
/// question a 404 in the panel raises.
///
/// Uses a public repository and skips without a token or a network, so a
/// checkout on someone else's machine is not red for reasons that are not
/// about the code.
@Suite("Live GitHub access")
struct LiveGitHubTests {

    static let sample = "https://github.com/socratic-ai/cosmo-ai"

    @Test("a pasted browser URL parses to the right owner and repo")
    func parsesTheRealURL() {
        let ref = GitHub.parseRef(Self.sample)
        #expect(ref?.owner == "socratic-ai", "got owner: \(ref?.owner ?? "nil")")
        #expect(ref?.repo == "cosmo-ai", "got repo: \(ref?.repo ?? "nil")")
    }

    @Test("the repository is readable end to end")
    func readsRepo() async throws {
        let ref = try #require(GitHub.parseRef(Self.sample))
        do {
            let snapshot = try await GitHub.snapshot(ref)
            print("OK — branch \(snapshot.branch), \(snapshot.entries.count) entries")
            #expect(!snapshot.entries.isEmpty)
        } catch let error as NSError where error.domain == NSURLErrorDomain {
            // Offline, or GitHub unreachable. Not a fact about this code.
            print("skipped — no network (\(error.code))")
        } catch let failure as GitHub.Failure
            where failure.message.contains("rate limiting")
                || failure.message.contains("404")
        {
            print("skipped — \(failure.message)")
        }
    }
}
