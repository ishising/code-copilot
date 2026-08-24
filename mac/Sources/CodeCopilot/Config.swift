import Foundation

/// Credentials, read from the same `.env` the browser app already uses.
///
/// One file, one place to rotate a key. The browser app's `VITE_` prefix is a
/// Vite convention rather than anything meaningful, so the names carry over
/// unchanged rather than forcing a second copy of the same secrets.
///
/// Resolution order for each value, first non-empty wins:
///   1. the process environment (handy for a one-off run)
///   2. `~/code-copilot/.env`
///   3. `~/Library/Application Support/CodeCopilot/config.json`
///
/// The Cosmo key is read here too. The SDK's zero-argument `RealtimeClient()`
/// would otherwise expect `cosmo login` to have stored credentials in
/// `~/.cosmo/credentials`, and throws when that file is absent — which is the
/// state most machines are in.
public struct Config: Sendable {
    public var githubToken: String?
    public var cosmoAPIKey: String?
    public var cosmoBaseURL: URL?

    /// The web app's env file, which this app shares rather than keeping a
    /// second copy of the same secrets.
    ///
    /// A list rather than one path: the two apps have lived at more than one
    /// layout, and a credential file that silently stops being found produces
    /// a 404 that looks like a missing repository. First one that exists wins.
    public static let envCandidates: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "code-copilot/web/.env"),
            home.appending(path: "code-copilot/.env"),
        ]
    }()

    public static var sharedEnv: URL {
        envCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? envCandidates[0]
    }

    public static let appSupport = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/CodeCopilot/config.json")

    public static let current: Config = load()

    /// Where each value came from, for the panel to show. Diagnosing "why
    /// can't it see my token" is otherwise guesswork.
    public private(set) var sources: [String: String] = [:]

    // MARK: - loading

    private static func load() -> Config {
        let env = ProcessInfo.processInfo.environment
        let dotenv = parseEnv(at: sharedEnv)
        let json = parseJSON(at: appSupport)

        var config = Config()

        func resolve(_ names: [String], jsonKey: String, label: String) -> String? {
            for name in names {
                if let value = clean(env[name]) {
                    config.sources[label] = "environment (\(name))"
                    return value
                }
            }
            for name in names {
                if let value = clean(dotenv[name]) {
                    config.sources[label] = sharedEnv.path
                    return value
                }
            }
            if let value = clean(json[jsonKey]) {
                config.sources[label] = appSupport.path
                return value
            }
            config.sources[label] = "not found"
            return nil
        }

        // The GitHub CLI's token first, when it is signed in. It is an OAuth
        // credential rather than a personal access token, so it reaches
        // organisations whose policies reject a PAT — and it needs nothing
        // created or pasted. An explicit environment variable still wins, for
        // deliberately scoping a run down.
        if let explicit = clean(env["VITE_GITHUB_TOKEN"]) ?? clean(env["GITHUB_TOKEN"]) {
            config.githubToken = explicit
            config.sources["GitHub token"] = "environment"
        } else if let cli = GitHubCLI.token() {
            config.githubToken = cli
            config.sources["GitHub token"] = "gh CLI (gh auth token)"
        } else {
            config.githubToken = resolve(
                ["VITE_GITHUB_TOKEN", "GITHUB_TOKEN"], jsonKey: "githubToken",
                label: "GitHub token")
        }
        config.cosmoAPIKey = resolve(
            ["VITE_COSMO_API_KEY", "COSMO_API_KEY"], jsonKey: "cosmoApiKey", label: "Cosmo key")
        config.cosmoBaseURL = resolve(
            ["VITE_COSMO_BASE_URL", "COSMO_BASE_URL"], jsonKey: "cosmoBaseUrl", label: "Cosmo host")
            .flatMap(URL.init(string:))

        return config
    }

    /// A placeholder is not a value. `.env.example` ships `cosmo_...`, which
    /// sails through a bare emptiness check and fails much later as an opaque
    /// credential error.
    private static func clean(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1 {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty, !value.hasSuffix("...") else { return nil }
        return value
    }

    /// Enough of the dotenv format for a file a person hand-edits: comments,
    /// blank lines, optional quotes, and values that themselves contain `=`.
    static func parseEnv(at url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                let split = trimmed.firstIndex(of: "=")
            else { continue }
            let key = String(trimmed[trimmed.startIndex..<split]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: split)...])
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private static func parseJSON(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return body.compactMapValues { $0 as? String }
    }

    /// What to tell the user when a credential is missing, naming the file
    /// they should put it in.
    public var missingCredentialAdvice: String? {
        guard cosmoAPIKey == nil else { return nil }
        return "No Cosmo key. Add VITE_COSMO_API_KEY to \(Config.sharedEnv.path), "
            + "or run `cosmo login`."
    }
}
