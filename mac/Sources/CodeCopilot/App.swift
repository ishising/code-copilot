import SwiftUI

/// The control panel. Deliberately small: GitHub in the browser is the
/// surface, and this window is only here to start a session, show what was
/// said, and record exactly which files were touched.
@main
struct CodeCopilotApp: App {
    @State private var conductor = Conductor()

    var body: some Scene {
        Window("Code Copilot", id: "panel") {
            PanelView(conductor: conductor)
                .frame(minWidth: 380, minHeight: 480)
        }
        .defaultSize(width: 420, height: 640)
        .windowResizability(.contentSize)
    }
}

struct PanelView: View {
    @Bindable var conductor: Conductor
    @State private var repo = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !conductor.permissions.allGranted {
                permissionsNotice
                Divider()
            }

            if let advice = Config.current.missingCredentialAdvice {
                Text(advice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Divider()
            }

            if !conductor.routes.isEmpty {
                routePicker
                Divider()
            }

            transcript
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Code Copilot").font(.headline)
                Spacer()
                Text(conductor.phase.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(statusColour)
            }

            HStack(spacing: 6) {
                TextField("github.com/owner/repo", text: $repo)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { begin() }

                if case .live = conductor.phase {
                    Button("End") { Task { await conductor.stop() } }
                } else {
                    Button("Walk me through it", action: begin)
                        .buttonStyle(.borderedProminent)
                        .disabled(repo.isEmpty || isBusy)
                }
            }

            HStack(spacing: 10) {
                ForEach(Config.current.sources.sorted(by: { $0.key < $1.key }), id: \.key) {
                    label, source in
                    Text("\(label): \(source == "not found" ? "not found" : "✓")")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(source == "not found" ? Color.orange : .secondary)
                        .help(source)
                }
            }

            if let problem = conductor.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    private var permissionsNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(conductor.permissions.missingDescription) not granted")
                .font(.callout.bold())
            Text(
                "I can't point at anything until macOS lets me see and read the "
                    + "screen. Grant these in System Settings → Privacy & Security, "
                    + "then quit and reopen me."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Ask for permission") { conductor.requestPermissions() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.10))
    }

    /// The agent's own suggestions, not a fixed menu — so this is built from
    /// whatever it offered and disappears once something is chosen. Saying one
    /// of these out loud instead works identically; the buttons only save the
    /// user from having to invent the question.
    private var routePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHERE WOULD YOU LIKE TO START?")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(conductor.routes) { route in
                Button {
                    Task { await conductor.choose(route) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.label).font(.callout.weight(.medium))
                        Text(route.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
            }

            Text("Or just say what you want to understand.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conductor.turns) { turn in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(turn.speaker.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(
                                    turn.speaker == "copilot" ? Color.accentColor : .secondary)
                            Text(turn.text).font(.callout).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // The written record. Spoken words can be misheard; this
                    // cannot — it is written by the code, not transcribed.
                    ForEach(Array(conductor.activity.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: conductor.turns.count) { proxy.scrollTo("bottom") }
            .onChange(of: conductor.activity.count) { proxy.scrollTo("bottom") }
        }
    }

    private var statusColour: Color {
        switch conductor.phase {
        case .live: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var isBusy: Bool {
        switch conductor.phase {
        case .reading, .connecting: true
        default: false
        }
    }

    private func begin() {
        guard !repo.isEmpty, !isBusy else { return }
        Task { await conductor.start(repo: repo) }
    }
}
