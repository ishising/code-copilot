import Foundation

/// Reading a repository from the GitHub API.
///
/// A port of the browser app's `src/repo/github.ts`, constants and all — the
/// noise filters, prefetch caps and entry-point heuristics were tuned against
/// real repositories and are not worth rediscovering.
///
/// Read-only by construction: every request is a GET, and GitHub requires
/// POST/PUT/PATCH/DELETE for any mutation. This client cannot create, change
/// or delete anything, whatever it is asked to do.
public enum GitHub {

    static let api = URL(string: "https://api.github.com")!

    public struct Ref: Sendable, Equatable {
        public let owner: String
        public let repo: String
        /// Folder within the repository to confine the walk to, taken from a
        /// `/tree/<branch>/<path>` URL. A monorepo is otherwise unusable here:
        /// `socratic-ai/cosmo` has over seventeen thousand files, and a brief
        /// built from all of them describes everything and explains nothing.
        public var subpath: String? = nil
    }

    public struct TreeEntry: Sendable {
        public let path: String
        public let isFile: Bool
        public let size: Int
    }

    public struct Snapshot: Sendable {
        public let ref: Ref
        public let branch: String
        public let description: String?
        public let entries: [TreeEntry]
        public let readme: String?
        public let truncated: Bool
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    // MARK: - parsing what someone would actually paste

    /// A browser URL, a `.git` clone URL, or bare `owner/repo`.
    public static func parseRef(_ input: String) -> Ref? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        while text.hasSuffix("/") { text = String(text.dropLast()) }

        if let match = text.range(of: #"github\.com[/:]([^/]+)/([^/]+)"#, options: .regularExpression) {
            let parts = text[match].split(whereSeparator: { $0 == "/" || $0 == ":" })
            if parts.count >= 3 {
                // Anything after /tree/<branch>/ is the folder the person is
                // pointing at. `/blob/` is deliberately excluded: it addresses
                // a single file, and confining the whole walk to one file
                // would leave nothing to walk.
                var subpath: String? = nil
                if let rest = text.range(of: #"/tree/[^/]+/"#, options: .regularExpression) {
                    let tail = String(text[rest.upperBound...])
                    if !tail.isEmpty { subpath = tail }
                }
                return Ref(owner: String(parts[1]), repo: String(parts[2]), subpath: subpath)
            }
        }
        // Anchored, and restricted to the characters GitHub actually allows
        // in a name. A loose split here happily reads `https://example.com` as
        // owner `https:` — a valid-looking ref that 404s much later.
        if text.range(of: #"^[\w.-]+/[\w.-]+$"#, options: .regularExpression) != nil {
            let parts = text.split(separator: "/")
            return Ref(owner: String(parts[0]), repo: String(parts[1]))
        }
        return nil
    }

    // MARK: - requests

    private static func request(_ path: String) async throws -> Data {
        // Concatenation, not `api.appending(path:)`. That method treats its
        // argument as a single path component and percent-encodes it, so a
        // `?` becomes `%3F` and the query is swallowed into the path:
        //   /git/trees/main?recursive=1  ->  /git/trees/main%3Frecursive=1
        // which 404s. Path segments that need encoding are already encoded by
        // their callers.
        guard let url = URL(string: api.absoluteString + path) else {
            throw Failure(message: "Could not build a URL for \(path)")
        }
        var request = URLRequest(url: url)
        // Stated rather than defaulted, so read-only is a visible property of
        // this function. Changing it is the only way to make the app capable
        // of writing.
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = Config.current.githubToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "No response from GitHub")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(message: explain(http, data: data, path: path))
        }
        return data
    }

    /// GitHub's own words, which are almost always the useful ones — a 403 is
    /// as often an org policy or a missing permission as it is a rate limit,
    /// and collapsing those into one message sends you debugging the wrong
    /// thing. Only a spent budget is reported as rate limiting.
    private static func explain(_ http: HTTPURLResponse, data: Data, path: String) -> String {
        if http.statusCode == 404 {
            // Naming the path matters: a 404 is as often a URL this app built
            // wrongly as it is a repository that isn't there, and a message
            // that only ever blames the repository sends you checking the
            // address while the bug sits in the request.
            let hasToken = Config.current.githubToken != nil
            return "GitHub returned 404 for \(path). "
                + (hasToken
                    ? "A token is configured, so either the repository doesn't exist or "
                        + "the token has no access to it."
                    : "No GitHub token is configured, which is required for a private "
                        + "repository.")
        }
        let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
        if (http.statusCode == 403 || http.statusCode == 429) && remaining == "0" {
            return "GitHub is rate limiting us. Wait a few minutes, or add a "
                + "GitHub token to lift the limit."
        }
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = body["message"] as? String, !message.isEmpty
        {
            return "GitHub refused that (\(http.statusCode)): \(message)"
        }
        return "GitHub returned \(http.statusCode) for \(path)"
    }

    private static func json<T>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await request(path)
        guard let value = try JSONSerialization.jsonObject(with: data) as? T else {
            throw Failure(message: "Unexpected response shape from \(path)")
        }
        return value
    }

    // MARK: - the repository

    public static func snapshot(_ ref: Ref) async throws -> Snapshot {
        let meta = try await json("/repos/\(ref.owner)/\(ref.repo)", as: [String: Any].self)
        let branch = meta["default_branch"] as? String ?? "main"

        let tree = try await json(
            "/repos/\(ref.owner)/\(ref.repo)/git/trees/\(branch)?recursive=1",
            as: [String: Any].self
        )
        let raw = tree["tree"] as? [[String: Any]] ?? []
        var entries: [TreeEntry] = raw.compactMap { item in
            guard let path = item["path"] as? String,
                let kind = item["type"] as? String,
                kind == "blob" || kind == "tree"
            else { return nil }
            return TreeEntry(path: path, isFile: kind == "blob", size: item["size"] as? Int ?? 0)
        }

        // Confine to the folder the URL pointed at, if it named one.
        if let subpath = ref.subpath {
            let prefix = subpath.hasSuffix("/") ? subpath : subpath + "/"
            entries = entries.filter { $0.path == subpath || $0.path.hasPrefix(prefix) }
        }

        // A repo with no README is normal; the brief just says so.
        let readme = try? await file(ref, path: "README.md").text

        return Snapshot(
            ref: ref,
            branch: branch,
            description: meta["description"] as? String,
            entries: entries,
            readme: readme,
            truncated: tree["truncated"] as? Bool ?? false
        )
    }

    public static func file(_ ref: Ref, path: String) async throws -> (text: String, lines: Int) {
        let encoded =
            path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")

        let body = try await json(
            "/repos/\(ref.owner)/\(ref.repo)/contents/\(encoded)", as: [String: Any].self)
        guard let content = body["content"] as? String, body["encoding"] as? String == "base64"
        else { throw Failure(message: "\(path) is not a readable text file") }
        if let size = body["size"] as? Int, size > 400_000 {
            throw Failure(message: "\(path) is too large to read (\(size / 1024) KB)")
        }
        guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters),
            let text = String(data: data, encoding: .utf8)
        else { throw Failure(message: "\(path) looks like a binary file") }

        return (text, text.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    // MARK: - prefetch

    static let sourcePattern =
        #"\.(ts|tsx|js|jsx|mjs|cjs|py|go|rb|java|kt|swift|rs|php|cs|scala|vue|svelte|sql|sh|bash|toml|ya?ml|json|html|css|scss)$"#
    static let noisePattern =
        #"^(node_modules|dist|build|out|vendor|\.git|\.next|target|coverage|__pycache__)(/|$)"#

    static let prefetchLimit = 250
    static let prefetchConcurrency = 12
    static let prefetchMaxBytes = 120_000

    public static func isNoise(_ path: String) -> Bool {
        path.range(of: noisePattern, options: .regularExpression) != nil
    }

    static func isSource(_ path: String) -> Bool {
        path.range(of: sourcePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Pull the source up front.
    ///
    /// Search can only look inside files we already hold, and following a flow
    /// — this calls that, which writes here — is search, not guesswork. This is
    /// what makes a walkthrough possible rather than a sequence of guesses at
    /// filenames.
    public static func prefetch(
        _ ref: Ref,
        entries: [TreeEntry],
        progress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> [String: String] {
        let wanted =
            entries
            .filter {
                $0.isFile && !isNoise($0.path) && isSource($0.path) && $0.size > 0
                    && $0.size <= prefetchMaxBytes
            }
            // Shallow first: a repo's important code is rarely six levels down,
            // so if the cap bites it bites on the least interesting files.
            .sorted { $0.path.components(separatedBy: "/").count < $1.path.components(separatedBy: "/").count }
            .prefix(prefetchLimit)

        var cache: [String: String] = [:]
        var done = 0
        let total = wanted.count

        for batch in stride(from: 0, to: wanted.count, by: prefetchConcurrency) {
            let slice = Array(wanted[batch..<min(batch + prefetchConcurrency, wanted.count)])
            await withTaskGroup(of: (String, String?).self) { group in
                for entry in slice {
                    group.addTask {
                        // A file we can't read is simply not searchable; not
                        // worth failing the whole ingest over one bad blob.
                        (entry.path, try? await file(ref, path: entry.path).text)
                    }
                }
                for await (path, text) in group {
                    if let text { cache[path] = text }
                    done += 1
                    progress(done, total)
                }
            }
        }
        return cache
    }
}
