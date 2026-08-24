# Code Copilot

Two voice copilots that walk a non-technical person through a codebase — out
loud, pointing at what they mean.

They are not versions of each other. They solve the same problem from opposite
directions, and both are kept.

| | [`web/`](web) | [`mac/`](mac) |
| --- | --- | --- |
| Where the code is | Rendered inside the app | GitHub, in your own browser |
| How it points | Exact highlight in its own viewer | A real mark drawn on your screen |
| "What's this?" | Click a line | Click anything, read via accessibility |
| Sees the rest of your screen | No | Yes |
| Setup | `npm run dev` | Permissions, a signing identity, a Chrome flag |

Both are built on the [Cosmo SDK](https://github.com/socratic-ai/cosmo-ai).

## The idea

Someone who owns software but cannot read code doesn't know which questions to
ask — that is precisely their problem. So neither app answers questions. Both
**walk**: open the file, mark the exact lines, say what happens there in terms
of the world, name where the flow goes next. A question changes *what* gets
walked, never *whether* there is a walk.

The instructions that produce that behaviour are the actual product. They live
in [`web/src/persona.ts`](web/src/persona.ts) and
[`mac/Sources/CodeCopilot/Persona.swift`](mac/Sources/CodeCopilot/Persona.swift),
and they are plain English — edit those first.

## Why two

A web page cannot draw on another browser tab. That is a hard security
boundary, not a gap in the SDK. So either the app owns the surface and can
point precisely (`web`), or it leaves the code on GitHub and needs the macOS
accessibility tree to point at it (`mac`).

An earlier attempt to point at a shared tab from the browser failed for a
different reason worth recording: `detect_objects` and `point_at_object` are
object locators built for camera scenes, and could not reliably find a filename
in a screenshot of a code listing. The native app grounds against the
accessibility tree instead, which *says* where every row is rather than
guessing from pixels.

## Running either app

From the repository root:

```bash
npm run dev      # the web app  (forwards to web/)
npm run mac      # build and launch the Mac app
npm run mac:test # the Mac app's tests
```

The root `package.json` holds nothing but those forwarders — each app keeps
its own dependencies.

## Getting started

Each app has its own README with setup. Credentials are shared: both read
`web/.env`, which is git-ignored. Copy `web/.env.example` to `web/.env` and
fill it in.

## Notes worth keeping

- **Chrome hides its page from accessibility** unless launched with
  `--force-renderer-accessibility`. Measured: 58 nodes without it, ~1,640 with.
  `mac/chrome-with-accessibility.sh` handles it. Safari needs nothing.
- **Screenshots are capped at a 1280px long edge.** The SDK documents that
  providers discard anything above their working resolution, and sending a full
  Retina display meant ~7× the pixels the model keeps — paid for in silence
  while the conversation waited.
- **Ad-hoc code signatures lose macOS permissions on every rebuild.**
  `mac/make-identity.sh` creates a stable local identity so the grants stick.
