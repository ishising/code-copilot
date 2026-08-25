import { RealtimeClient, type SessionStartOptions } from 'cosmo-ai';

import { GREETING, VOICE, instructions } from './persona';
import { buildBrief, MANIFESTS } from './repo/brief';
import {
  fetchFile,
  fetchSnapshot,
  parseRepoRef,
  prefetchSources,
  type RepoRef,
} from './repo/github';
import { markToPromote, type PendingMark } from './repo/mark_timing';
import { repoTools } from './repo/tools';
import type { Route } from './repo/tools';
import { createViewer } from './repo/viewer';

const el = <T extends HTMLElement>(id: string): T => {
  const found = document.getElementById(id);
  if (found === null) throw new Error(`missing #${id}`);
  return found as T;
};

const setup = el('setup');
const setupForm = el<HTMLFormElement>('setup-form');
const repoInput = el<HTMLInputElement>('repo-input');
const ingestButton = el<HTMLButtonElement>('ingest');
const setupStatus = el('setup-status');

const app = el('app');
const repoName = el('repo-name');
const statusPill = el('status');
const endButton = el<HTMLButtonElement>('end');
const treeHost = el('tree');
const codeHost = el('code');
const crumb = el('crumb');
const transcriptPane = el('transcript');

const API_KEY = import.meta.env.VITE_COSMO_API_KEY;

/** Server-side retention for each run.
 *
 *  Read the contract before changing these: the SDK documents them as
 *  **narrowing only** — "a session can request less storage than the account
 *  permits, never more". So `true` here does not switch recording on; it
 *  declines to switch it off. Whether anything is actually kept is decided by
 *  the workspace's consent settings in the Cosmo dashboard, and leaving these
 *  unset already stores as much as those consents allow.
 *
 *  `storeTranscript` is the one to think about: it persists tool-call events,
 *  and this agent's tool calls carry the text of the files it read. Pointing
 *  the app at a private repository with this on means that source code is
 *  retained server-side. Set it to `false` to keep the audio without the code.
 */
const RECORDING = {
  storeRecording: true,
  storeAudio: true,
  storeTranscript: true,
  // The session publishes a screen share (see below), so this one is not a
  // no-op: it declines to switch video retention off. Whether the video is
  // actually kept is still the workspace's consent setting, not this flag.
  storeVideo: true,
  // `satisfies` rather than a bare object: these are passed as a variable, so
  // excess-property checking is off and a typo'd flag would compile silently
  // and be ignored at runtime — exactly the failure you would never notice.
} satisfies SessionStartOptions;

function setStatus(text: string, kind: 'idle' | 'live' | 'error'): void {
  statusPill.textContent = text;
  statusPill.className = kind;
}

function say(message: string, isError = false): void {
  setupStatus.textContent = message;
  setupStatus.className = isError ? 'hint error' : 'hint';
}

// ---- transcript ----

/** One bubble per (turnId, role). The SDK never coalesces deltas — that is
 *  the UI's job, and it keys on the turn, never on message identity. */
const bubbles = new Map<string, HTMLElement>();

function renderTranscript(event: {
  turnId: string;
  role: 'user' | 'assistant';
  text: string;
  append: boolean;
}): void {
  const key = `${event.turnId}:${event.role}`;
  let bubble = bubbles.get(key);
  if (bubble === undefined || !event.append) {
    bubble = document.createElement('div');
    bubble.className = `turn ${event.role}`;
    const who = document.createElement('span');
    who.className = 'who';
    who.textContent = event.role === 'assistant' ? 'copilot' : 'you';
    bubble.append(who, document.createElement('span'));
    transcriptPane.appendChild(bubble);
    bubbles.set(key, bubble);
  }
  const body = bubble.lastElementChild as HTMLElement;
  body.textContent = event.append ? `${body.textContent ?? ''}${event.text}` : event.text;
  transcriptPane.scrollTop = transcriptPane.scrollHeight;
}

/** What the agent did, in the transcript. Visible tool activity is the
 *  difference between "it isn't pointing" and knowing which step failed. */
function logAction(text: string): void {
  const line = document.createElement('div');
  line.className = 'act';
  line.textContent = text;
  transcriptPane.appendChild(line);
  transcriptPane.scrollTop = transcriptPane.scrollHeight;
}

/** The agent's opening offer, drawn as buttons in the transcript.
 *
 *  Not a fixed menu: the routes are whatever it proposed after reading the
 *  summary, and saying one out loud instead works identically. The buttons
 *  only save the user from having to invent the question — which is the whole
 *  problem this app exists for.
 */
function renderRoutes(routes: Route[], choose: (route: Route) => void): void {
  const block = document.createElement('div');
  block.className = 'routes';

  const heading = document.createElement('div');
  heading.className = 'act';
  heading.textContent = 'where would you like to start?';
  block.appendChild(heading);

  for (const route of routes) {
    const button = document.createElement('button');
    button.className = 'route';
    button.type = 'button';

    const label = document.createElement('span');
    label.className = 'route-label';
    label.textContent = route.label;

    const summary = document.createElement('span');
    summary.className = 'route-summary';
    summary.textContent = route.summary;

    button.append(label, summary);
    button.onclick = () => {
      // The offer is spent either way — a second click would ask twice.
      block.remove();
      choose(route);
    };
    block.appendChild(button);
  }

  const hint = document.createElement('div');
  hint.className = 'act';
  hint.textContent = 'or just say what you want to understand';
  block.appendChild(hint);

  transcriptPane.appendChild(block);
  transcriptPane.scrollTop = transcriptPane.scrollHeight;
}

/** Why a session refused to start, in words worth reading.
 *
 *  The SDK raises typed errors carrying a status and a structured `detail`
 *  (`concurrent_session_limit`, an entitlement refusal, a config rejection).
 *  Collapsing all of that into "could not connect" is how a wrong-host 401 —
 *  which reads as a bad key, but means the key belongs to the other Cosmo
 *  installation entirely — costs an afternoon to find. */
function sessionStartMessage(error: unknown): string {
  if (!(error instanceof Error)) return 'could not start the session';
  const withDetail = error as Error & {
    status?: number;
    detail?: { code?: string; message?: string } | null;
  };
  const status = withDetail.status;
  const detail = withDetail.detail;
  const said = detail?.message ?? error.message;

  if (status === 401 || status === 403) {
    return `${said} — check VITE_COSMO_BASE_URL matches the host that issued your key`;
  }
  const code = detail?.code === undefined ? '' : ` (${detail.code})`;
  return status === undefined ? said : `${said}${code} [HTTP ${status}]`;
}

// ---- ingest, then talk ----

async function readManifests(ref: RepoRef, paths: Set<string>): Promise<Map<string, string>> {
  const found = new Map<string, string>();
  await Promise.all(
    MANIFESTS.filter((name) => paths.has(name)).map(async (name) => {
      try {
        const { text } = await fetchFile(ref, name);
        found.set(name, text);
      } catch {
        // A manifest we can't read just drops out of the brief.
      }
    }),
  );
  return found;
}

async function begin(input: string): Promise<void> {
  const ref = parseRepoRef(input);
  if (ref === null) {
    say('That does not look like a GitHub repository — try github.com/owner/repo', true);
    return;
  }

  ingestButton.disabled = true;
  say(`Reading ${ref.owner}/${ref.repo}…`);

  let snapshot;
  try {
    snapshot = await fetchSnapshot(ref);
  } catch (error) {
    say(error instanceof Error ? error.message : 'Could not read that repository', true);
    ingestButton.disabled = false;
    return;
  }

  const paths = new Set(snapshot.entries.map((entry) => entry.path));
  const manifests = await readManifests(ref, paths);
  const brief = buildBrief(snapshot, manifests);

  // Pull the source up front. Following a flow means searching for where a
  // thing is defined and then where it is called, and search can only look
  // inside files we already hold — so this is what makes a walkthrough
  // possible at all, rather than a sequence of guesses at paths.
  say(`Reading the code in ${ref.owner}/${ref.repo}…`);
  const cache = await prefetchSources(ref, snapshot.entries, (done, total) => {
    say(`Reading the code… ${done} of ${total} files`);
  });

  setup.hidden = true;
  app.hidden = false;
  repoName.textContent = `${ref.owner}/${ref.repo}`;
  setStatus('connecting', 'idle');

  const viewer = createViewer({
    treeHost,
    codeHost,
    crumb,
    snapshot,
    load: (path) => fetchFile(ref, path),
  });

  if (import.meta.env.DEV) {
    // Handy from the browser console when a highlight lands somewhere odd:
    // __viewer.highlightLines('path/to/file.ts', 10, 14, 'here').
    (window as unknown as { __viewer?: unknown }).__viewer = viewer;
  }

  // The repo is on screen and browsable from here on, so a missing key costs
  // the voice but not the visit — and it says so where it will be read.
  // `.env.example` ships the literal `cosmo_...`, which would otherwise sail
  // through a bare prefix check and fail much later as a credential error.
  if (
    typeof API_KEY !== 'string' ||
    !API_KEY.startsWith('cosmo_') ||
    API_KEY === 'cosmo_...'
  ) {
    setStatus('no api key', 'error');
    logAction(
      'No Cosmo API key, so the voice session is off. Copy .env.example to ' +
        '.env, paste your key in as VITE_COSMO_API_KEY, and reload. You can ' +
        'still browse the repository.',
    );
    return;
  }

  let pendingMark: PendingMark | null = null;
  // `offer_routes` only ever fires inside a live session, but the tools are
  // built before `agent.start()` returns — so the closure reads this rather
  // than capturing a session that does not exist yet.
  let live: Awaited<ReturnType<typeof agent.start>> | undefined;

  const tools = repoTools({
    ref,
    viewer,
    onActivity: logAction,
    cache,
    allPaths: [...paths],
    onRead: (path, from, to) => {
      pendingMark = { path, from, to, at: Date.now() };
    },
    onRoutes: (routes) => {
      renderRoutes(routes, (route) => {
        // `sendText` asks — it lands as a turn and the agent answers it. A
        // click and saying the same sentence take exactly the same path.
        renderTranscript({
          turnId: `route-${Date.now()}`,
          role: 'user',
          text: route.label,
          append: false,
        });
        void live?.sendText(`Walk me through this: ${route.label}`);
      });
    },
  });

  if (import.meta.env.DEV) {
    // Drive a tool by hand exactly as the agent would, without burning a
    // voice session: __tools.read_file({ path: 'index.js' }).
    (window as unknown as { __tools?: unknown }).__tools = Object.fromEntries(
      tools.specs.map((spec) => [spec.name, spec.handler]),
    );
  }

  const client = new RealtimeClient({ apiKey: API_KEY });

  const agent = client.agent({
    instructions: instructions(brief),
    voice: VOICE,
    greeting: GREETING,
    modelOptions: { provider: 'gemini', includeThoughts: false },
    tools: [{ kind: 'web_search' }, ...tools.specs],
  });

  let session;
  try {
    session = await agent.start(RECORDING);
    live = session;
  } catch (error) {
    const why = sessionStartMessage(error);
    setStatus('session failed', 'error');
    logAction(why);
    console.error(error);
    return;
  }

  endButton.hidden = false;
  endButton.onclick = () => void session.end();

  // Publish the screen the user already picked, if they picked one.
  //
  // `addVideoStream` rather than `startScreenShare`, because that one would
  // call `getDisplayMedia` again from here — far outside the click that
  // authorised it — which is exactly the failure this replaces. `kind:
  // 'screen'` makes the transport publish it as a screen-share track rather
  // than a camera.
  //
  // The default fps is about 1, tuned for a model glancing at a frame. This
  // is meant to be watched back by a person, so it matches the Mac app's 5.
  if (pendingScreen !== null) {
    const stream = pendingScreen;
    pendingScreen = null;
    void session
      .addVideoStream(stream, { kind: 'screen', fps: 5 })
      .then(() => logAction('recording the screen'))
      .catch((error: unknown) => {
        const why = error instanceof Error ? error.message : String(error);
        logAction(`not recording the screen — ${why}`);
        for (const track of stream.getTracks()) track.stop();
      });

    // Stopping the share from the browser's own "stop sharing" bar ends the
    // track, not the session. Say so, or the recording quietly stops being a
    // recording with nothing to show for it.
    for (const track of stream.getTracks()) {
      track.addEventListener('ended', () => logAction('screen recording stopped'));
    }
  }

  session.on('ready', () => setStatus('live', 'live'));
  session.on('transcript', (event) => {
    renderTranscript(event);
    // First words of an assistant turn: put the mark up now, rather than
    // waiting for a `highlight_lines` that lands when the sentence is over.
    const promote = markToPromote(event, pendingMark, Date.now());
    if (event.role === 'assistant') pendingMark = null;
    if (promote === null) return;
    void viewer.highlightLines(promote.path, promote.from, promote.to);
  });
  // The tools report their own activity with exact paths (see repoTools), so
  // the bare tool name here would only duplicate it less precisely. What is
  // still worth surfacing is a call that failed inside the SDK before a
  // handler ever ran — a schema rejection, say.
  session.on('tool_result', (event) => {
    if (!event.ok) logAction(`✗ ${event.summary ?? 'a tool call failed'}`);
  });
  session.on('error', (event) => {
    if (event !== null) setStatus(event.message ?? 'error', 'error');
  });
  session.on('session_ended', () => {
    setStatus('ended', 'idle');
    endButton.hidden = true;
  });
}

/**
 * The screen the user picked, captured while their click still counts.
 *
 * `getDisplayMedia` requires transient user activation — a *recent* click —
 * and an earlier version asked for it after `agent.start()` resolved, tens of
 * seconds and several awaits later. The browser refused every time, silently
 * enough that five sessions recorded nothing before anyone noticed. So the
 * request is issued from inside the submit handler, before anything is
 * awaited, and the resulting track waits here until there is a session to
 * publish it on.
 */
let pendingScreen: MediaStream | null = null;

setupForm.onsubmit = (event) => {
  event.preventDefault();

  // Fired, deliberately, without awaiting: holding up the repo read on a
  // picker the user might sit on for ten seconds would make the walk feel
  // broken. Declining is normal and simply leaves the session unrecorded.
  if (navigator.mediaDevices?.getDisplayMedia) {
    void navigator.mediaDevices
      .getDisplayMedia({ video: true })
      .then((stream) => {
        pendingScreen = stream;
      })
      .catch((error: unknown) => {
        const why = error instanceof Error ? error.message : String(error);
        logAction(`not recording the screen — ${why}`);
      });
  }

  void begin(repoInput.value).catch((error: unknown) => {
    console.error(error);
    say('Something broke — check the browser console', true);
    ingestButton.disabled = false;
  });
};
