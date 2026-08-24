import Foundation
import Testing

@testable import CodeCopilot

@Suite("Credential resolution")
struct ConfigTests {

    @Test("the dotenv parser handles a hand-edited file")
    func parsesDotenv() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "cc-\(UUID().uuidString).env")
        try """
            # a comment
            VITE_GITHUB_TOKEN=github_pat_abc123

            VITE_COSMO_BASE_URL="https://platform.askcosmo.ai"
            EMPTY=
            ODD=value=with=equals
            """.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let parsed = Config.parseEnv(at: tmp)
        #expect(parsed["VITE_GITHUB_TOKEN"] == "github_pat_abc123")
        #expect(parsed["EMPTY"] == "")
        #expect(parsed["ODD"] == "value=with=equals")
        #expect(parsed["# a comment"] == nil)
    }

    @Test("a missing file is empty, not a crash")
    func missingFile() {
        #expect(Config.parseEnv(at: URL(fileURLWithPath: "/nope/nothing.env")).isEmpty)
    }

    @Test("the real .env resolves both credentials")
    func resolvesRealCredentials() {
        let config = Config.current
        #expect(config.githubToken != nil, "GitHub token not found — \(config.sources)")
        #expect(config.cosmoAPIKey != nil, "Cosmo key not found — \(config.sources)")
        // Never print the values; the source path is the useful diagnostic.
        print("resolved from:", config.sources)
    }
}
