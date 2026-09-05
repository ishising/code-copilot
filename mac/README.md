# Code Copilot (macOS)

Paste a GitHub repository. It reads the whole thing, then walks you through it
out loud — pointing at what it means **on your actual screen**, in your real
browser.

The [browser version](../code-copilot) does the same thing inside its own code
viewer. This one exists because a web page cannot draw on another tab; only a
native app can.

## How the pointing works

`cosmo_screen_locate` grounds the agent's description ("the file called login")
against a screenshot **plus the macOS accessibility tree** — real elements,
real frames. A browser publishes its whole rendered page through that tree, so
on a GitHub tab the agent knows exactly where every file row and line sits.

That is why this works where an earlier attempt failed: `detect_objects` and
`point_at_object` are object locators built for camera scenes, and could not
reliably find a filename in a screenshot of a code listing.

It marks, it never clicks. `cosmo_sdk_screen_highlight_element` is documented
as "the pointing sibling of `ScreenClickTool` — it marks the control and stops
there, so the user does the acting."

## Setup, once

1. **Credentials** — read from the browser app's existing file,
   `web/.env`. One place to rotate a key, no second copy:

   ```
   VITE_COSMO_API_KEY=cosmo_...
   VITE_COSMO_BASE_URL=https://platform.askcosmo.ai
   VITE_GITHUB_TOKEN=github_pat_...
   ```

   Resolution order per value, first non-empty wins: the process environment,
   then that `.env`, then `~/Library/Application Support/CodeCopilot/config.json`.
   `cosmo login` also works as a fallback for the Cosmo key. The panel shows
   where each credential came from — hover for the exact path.

   **You may not need a GitHub token at all.** If `gh auth login` has been run,
   this app borrows the CLI's credential automatically — and because that is an
   OAuth token rather than a personal access token, it reaches organisations
   whose policies reject a PAT outright. Measured: a fine-grained token was
   refused by the `socratic-ai` org for exceeding a 366-day lifetime, while
   `gh`'s token read the same private repository fine.

   If you do configure one, it wants to be **fine-grained** with Contents:
   Read-only. Two traps: a classic token's `public_repo` scope grants **write**,
   and many orgs reject long-lived fine-grained tokens. An explicit
   `VITE_GITHUB_TOKEN` in the environment still overrides the CLI.

## Monorepos

Paste the URL of the folder you care about, not the repository root:

```
https://github.com/socratic-ai/cosmo/tree/main/sdks/cosmo-realtime
```

The walk is confined to that folder. On that repository it is the difference
between 17,350 files and 1,019 — a brief built from the whole thing describes
everything and explains nothing.

2. **A stable signing identity** — run this once:

   ```bash
   mac/make-identity.sh
   ```

   Skip it and the app is signed ad-hoc, which means macOS pins your
   permissions to the binary's hash and silently forgets them on every
   rebuild — the app stays ticked in System Settings and is treated as a
   different app anyway. Reversible: delete "Code Copilot Local" in Keychain
   Access.

3. **Permissions** — Screen Recording and Accessibility, both in System
   Settings → Privacy & Security. The app tells you which are missing and can
   prompt for them. **Quit and reopen after granting** — macOS only reads them
   at launch.

## Running it

```bash
mac/run.sh
```

It works from any directory.

Then open the repo on GitHub in **Safari** (its accessibility tree is the most
reliable; Chrome's is patchier), paste the repo into the panel, and talk.

## Tests

```bash
swift test --package-path ~/code-copilot-mac
```

The suite covers the parts that fail *silently*: the coordinate flip between
accessibility's top-left origin and AppKit's bottom-left one, the brief
builder, repo-reference parsing, and the accessibility filtering caps.

## The map

The agent files every stop into a map — the name it used out loud, one line on
what it is for, where it lives, and **which earlier stop it connects to**. The
panel shows the count; **Open map** writes it as Markdown with a Mermaid block
(which GitHub and most editors render) and opens it. It persists per
repository under `~/Library/Application Support/CodeCopilot/maps/`, so a
second visit continues from where the last one stopped.

This app draws no diagram of its own — the web app does, in its Map tab.

## Known limits

**Chrome needs to be started with a flag.** It keeps its renderer
accessibility tree off by default, and setting `AXManualAccessibility` does
not turn it on — measured here: a normal Chrome window gives 58 nodes and no
`AXWebArea`, while `--force-renderer-accessibility` gives ~1,640 including the
links and rows the agent points at. Run `./chrome-with-accessibility.sh` once
per Chrome session, or use **Safari**, which needs nothing. The app detects
this state and says so rather than failing quietly.

**Mark timing.** A realtime model emits its function calls at the end of a
turn, so a mark can land as the sentence finishes. `screen_locate` adds a
round trip on top. The persona pushes ordering; it is not a guarantee.

**Speed.** Measured from a real session: 20–25 second silences around
`cosmo_screen_locate`, long enough that the user asked "can you hear me?".
Two findings from chasing it:

- The accessibility walk is *not* the cost — 0.012ms per attribute read, about
  0.1s for a whole GitHub page.
- The screenshot was. It was captured at full Retina resolution when the SDK
  documents that both providers discard anything above a 1280px long edge —
  roughly seven times the pixels the model keeps, uploaded on every look.
  Now capped at `ImageDownscale.recommendedMaxLongEdge`.

The remaining latency is server-side grounding, which is not ours to fix. The
activity panel reports the size and duration of every capture, so this stays
measurable rather than anecdotal.

**If permissions stop working**, the signature identity has probably changed.
Check it is not ad-hoc:

```bash
codesign -d -r- mac/build/CodeCopilot.app
```

It should read `certificate leaf = H"..."`, not `cdhash`. If it says cdhash,
run `make-identity.sh` and rebuild. Then clear the stale grants and re-grant:

```bash
tccutil reset ScreenCapture local.codecopilot && tccutil reset Accessibility local.codecopilot
```
