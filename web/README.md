# Code Copilot — Web

**One of two.** This one *renders the repository itself* in its own viewer, so
pointing is exact and you can click a line and ask "what's this?". It never
looks at your screen.

Its sibling, [`mac/`](../mac), does the opposite:
it leaves the code in your browser on GitHub and draws marks on your real
screen. Neither replaces the other — use whichever suits the moment.

| | This app | The Mac app |
| --- | --- | --- |
| Where the code is | In this app's viewer | GitHub, in your browser |
| Pointing | Exact, instant | Real marks on your screen |
| Click a line and ask | Yes | Yes, via accessibility |
| Setup | `npm run dev` | Permissions, signing identity, Chrome flag |
| Sees the rest of your screen | No | Yes |

---


Paste a GitHub repository. It reads the whole thing, then walks you through it
out loud — pointing at exactly what it means while it talks.

Built on the [Cosmo SDK](https://github.com/socratic-ai/cosmo-ai).

## Authentication

**You probably need no token.** If you have run `gh auth login`, the dev
server borrows the CLI's credential automatically. That is an OAuth token
rather than a personal access token, so it reaches organisations that reject a
PAT on policy — measured: a fine-grained token was refused by the
`socratic-ai` org for exceeding a 366-day lifetime, while this one reads the
same private repository fine.

Dev only. A production build never bakes a personal credential into a bundle.
An explicit `VITE_GITHUB_TOKEN` still overrides it.

## Monorepos

Paste the URL of the folder you care about, not the repository root:

```
https://github.com/socratic-ai/cosmo/tree/main/sdks/cosmo-realtime
```

On that repository that is the difference between 17,350 files and 1,019.

## Setup, once

1. A Cosmo API key with the `realtime:use` scope — in the Cosmo web app at
   **app.askcosmo.ai**, under **Developer platform → API keys**.
2. `cp .env.example .env` and paste the key in as `VITE_COSMO_API_KEY`.
3. `npm install`

Optionally add a GitHub token as `VITE_GITHUB_TOKEN`. Without one GitHub
allows 60 requests an hour, which covers a few repos; with one, 5000. A
private repository needs one.

## Running it

```bash
npm run dev
```

Open the printed address, paste a repo, and talk.

Things worth trying:

- "What is this project?"
- "Where would I look if I wanted to change the signup flow?"
- Click any line, then ask **"what's this?"** — the point of the whole thing.
  You never have to know what something is called.
- "Is this something they built, or a library?"
- "What's the riskiest part of this codebase?"

## How it works

Two phases, and the split is the important design decision.

**Ingest, before you talk.** The app pulls the file tree, the README and the
dependency manifests from GitHub, and builds a compact factual brief — shape,
stack, entry points. A realtime voice model has small working memory and gets
vague when stuffed, so the brief is deliberately short. Detail arrives on
demand through `read_file`.

It also pulls the source files themselves at ingest (up to 250, code and
config only). That is what makes search possible, and search is what makes a
*walkthrough* possible rather than a sequence of guesses at filenames.

**Guide, while you talk.** The agent has five tools:

| Tool | What it does |
| --- | --- |
| `find_in_repo` | Searches the real source. This is how it follows a flow: find where a thing is defined, then where it is called. |
| `read_file` | Reads the real text of a file, and opens it in your view so you see what it sees. |
| `highlight_lines` | Marks lines and scrolls to them while it explains. |
| `highlight_path` | Marks a file or folder in the tree. |
| `user_focus` | Finds out what you're looking at — open file, visible lines, the line you clicked, any selection. This is how "what's this?" works. |

### It walks, it doesn't answer

The agent's method is fixed and does not change with the question. Every
explanation is a sequence of **stops**, and one stop is always: open the file,
highlight the exact lines, say what happens here in terms of what a real
person using the software causes, then name where the flow goes next.

A narrow question ("what's this line?") sets where the walk *starts*. It never
turns the walk into a bare answer. This is deliberate — someone who does not
read code does not know which questions to ask, so being handed a route beats
being handed an answer service. It lives in `src/persona.ts`.

### Why it renders the repo instead of watching your screen

The first version screen-shared a window and used the SDK's vision locators
(`detect_objects`, `point_at_object`) to find things in the frame. Those are
Moondream-backed **object** detectors — built for "one leaf, one screw" in a
camera image — and they could not reliably find a filename in a screenshot of
a code listing. The SDK's own tool description says as much: draw a box around
something `cosmo_detect_objects` located, rather than guessing.

Rendering the repo in-app removes the guessing entirely. The app owns the DOM,
so it knows exactly where every file row and every line sits. A highlight is
an element lookup: exact, instant, and impossible to hallucinate.

## Files

- `src/persona.ts` — the instructions. **This is the product**; everything
  else is plumbing. Edit this first when the answers aren't the right shape.
- `src/repo/github.ts` — reading the repository.
- `src/repo/brief.ts` — what the agent knows before you speak.
- `src/repo/viewer.ts` — the file tree and code panel, and the pointing.
- `src/repo/tools.ts` — what the agent can do to that view.
- `src/main.ts` — ingest, then session, then transcript.

## Known limits

**Only public repos, unless you add a GitHub token.**

**It has read the repo's shape, not every file.** It reads files on demand and
is instructed to say when it's inferring from a name rather than from code it
has actually read.

**No syntax highlighting yet.** Plain monospace. It affects how the code looks
to you, not how well the agent understands it.

**It can't see the rest of your screen.** That was the trade for reliable
pointing. Screen-share for "look at my other window" could come back as a
second mode later.
