import Foundation

/// Borrowing the GitHub CLI's credential.
///
/// `gh` signs in through GitHub's OAuth flow, and the token it stores reaches
/// organisations that reject a personal access token outright. Measured here:
/// a fine-grained PAT was refused by the `socratic-ai` organisation for having
/// a lifetime over 366 days, while `gh`'s token reads the same private
/// repository with a 200.
///
/// It also means there is nothing to create, paste, or rotate — if `gh auth
/// login` has been run, this app is already authenticated.
public enum GitHubCLI {

    /// Where `gh` actually lives. A GUI app launched from Finder inherits a
    /// minimal PATH — not the shell's — so `/usr/bin/env gh` finds nothing
    /// even when it works perfectly in a terminal.
    static let candidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/bin/gh").path,
    ]

    public static var executable: String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The stored token, or nil if `gh` is absent or signed out.
    ///
    /// Synchronous and run once at launch: it is a local process that returns
    /// in milliseconds, and everything downstream wants the answer before the
    /// first request.
    public static func token() -> String? {
        guard let executable else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
