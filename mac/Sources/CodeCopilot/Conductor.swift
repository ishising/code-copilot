import CosmoRealtime
import Foundation
import Observation

/// Session lifecycle: ingest the repository, start the agent, consume the
/// event stream into something the UI can render.
///
/// Modelled on the SDK's `Cartographer` example, including its two documented
/// traps — see `append(_:isFinal:)` and the note on `ready` in `consume`.
@MainActor
@Observable
public final class Conductor {

    public enum Phase: Equatable {
        case idle
        case reading(String)
        case connecting
        case live
        case ended(String)
        case failed(String)

        public var label: String {
            switch self {
            case .idle: "idle"
            case .reading(let what): what
            case .connecting: "connecting"
            case .live: "live"
            case .ended: "ended"
            case .failed: "failed"
            }
        }
    }

    public struct Turn: Identifiable {
        public let id = UUID()
        public let speaker: String
        public var text: String
    }

    public private(set) var phase: Phase = .idle
    public private(set) var turns: [Turn] = []
    /// Exact, written record of what the agent touched. The spoken transcript
    /// is a transcription of synthesized speech and mangles identifiers no
    /// matter how well the agent pronounces them, so the precise spelling has
    /// to reach the user through a channel that never passes through audio.
    public private(set) var activity: [String] = []
    public private(set) var problem: String?

    private var session: RealtimeSession?
    /// Held for the life of the session. The agent's tool closures reach into
    /// this object, so letting it fall out of scope disables every tool.
    private var tools: RepoTools?
    private var pump: Task<Void, Never>?
    private let overlay = Overlay()

    public init() {}

    public var permissions: Capture.Permissions { Capture.permissions() }

    public func requestPermissions() { Capture.requestPermissions() }

    // MARK: - start

    public func start(repo input: String) async {
        guard let ref = GitHub.parseRef(input) else {
            phase = .failed("That doesn't look like a GitHub repository")
            return
        }

        problem = nil
        turns = []
        activity = []
        phase = .reading("reading \(ref.owner)/\(ref.repo)…")

        do {
            let snapshot = try await GitHub.snapshot(ref)

            var manifests: [String: String] = [:]
            for name in Brief.manifests where snapshot.entries.contains(where: { $0.path == name }) {
                manifests[name] = try? await GitHub.file(ref, path: name).text
            }

            // Pull the source up front: search can only look inside files we
            // already hold, and following a flow is search, not guesswork.
            let cache = await GitHub.prefetch(ref, entries: snapshot.entries) { done, total in
                Task { @MainActor in self.phase = .reading("reading the code… \(done) of \(total)") }
            }

            let brief = Brief.build(snapshot: snapshot, manifests: manifests)
            note("read \(cache.count) source files")

            phase = .connecting
            try await connect(ref: ref, snapshot: snapshot, cache: cache, brief: brief)
        } catch {
            let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            phase = .failed(why)
            problem = why
        }
    }

    private func connect(
        ref: GitHub.Ref,
        snapshot: GitHub.Snapshot,
        cache: [String: String],
        brief: String
    ) async throws {
        let tools = RepoTools(
            ref: ref,
            overlay: overlay,
            cache: cache,
            allPaths: snapshot.entries.map(\.path),
            onActivity: { [weak self] line in self?.note(line) }
        )
        self.tools = tools

        // Prefer the key from the shared `.env`, and fall back to whatever
        // `cosmo login` stored. Zero-argument construction alone throws when
        // `~/.cosmo/credentials` is absent, which is the state a machine is in
        // until someone runs the CLI — an avoidable dead end when the key is
        // already sitting in a file next door.
        let client: RealtimeClient
        if let key = Config.current.cosmoAPIKey {
            client = RealtimeClient(
                RealtimeClient.Options(apiKey: key, baseURL: Config.current.cosmoBaseURL))
        } else {
            client = try RealtimeClient()
        }
        let agent = try client.agent(
            instructions: Persona.instructions(brief: brief),
            voice: VoiceConfig(name: Persona.voice),
            tools: try tools.agentTools(),
            greeting: Persona.greeting
        )

        let session = try await agent.start(
            storeRecording: true,
            storeAudio: true,
            storeTranscript: true,
            storeVideo: false
        )
        self.session = session
        consume(session)
    }

    // MARK: - events

    private func consume(_ session: RealtimeSession) {
        pump = Task { [weak self] in
            do {
                for try await event in session.events {
                    guard let self else { return }
                    // Don't gate the UI on `ready`: it is a single broadcast
                    // frame, and a client whose data channel attaches late
                    // never sees it. Latch live on the first event of any kind.
                    if case .live = self.phase {} else { self.phase = .live }

                    switch event {
                    case .transcript(let delta):
                        self.append(delta)
                    case .sessionEnded(let ended):
                        self.phase = .ended("\(ended.reason)")
                    case .error(let problem):
                        self.problem = problem.message
                        if problem.fatal == true { self.phase = .failed(problem.message) }
                    default:
                        break
                    }
                }
            } catch {
                await MainActor.run {
                    let why = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    self?.phase = .failed(why)
                    self?.problem = why
                }
            }
        }
    }

    /// Transcripts are not all the same. A non-final event carries only the
    /// new fragment for that turn, so it is appended; the final event carries
    /// the whole turn, so it replaces what was accumulated. Rendering both the
    /// same way duplicates every turn once.
    private func append(_ delta: RealtimeSession.TranscriptDelta) {
        let speaker = delta.role.rawValue.lowercased() == "assistant" ? "copilot" : "you"

        if let last = turns.indices.last, turns[last].speaker == speaker {
            if delta.isFinal {
                turns[last].text = delta.text
            } else {
                turns[last].text += delta.text
            }
        } else {
            turns.append(Turn(speaker: speaker, text: delta.text))
        }
    }

    private func note(_ line: String) {
        activity.append(line)
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }

    // MARK: - stop

    public func stop() async {
        overlay.clear()
        await session?.end()
        pump?.cancel()
        session = nil
        tools = nil
        if case .failed = phase {} else { phase = .ended("you ended it") }
    }
}
