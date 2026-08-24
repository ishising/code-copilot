/**
 * Reading a public repository straight from the GitHub API.
 *
 * Unauthenticated requests are rate limited to 60/hour per IP, which is
 * plenty for a session or two but runs out during a day of demos — set
 * `VITE_GITHUB_TOKEN` (a read-only token) to lift it to 5000.
 */

const API = 'https://api.github.com';

/** A NUL byte, built rather than written, so this file stays free of literal
 *  control characters. Its presence is the cheap binary-file test. */
const NUL = String.fromCharCode(0);

export type RepoRef = {
  owner: string;
  repo: string;
  /** Folder to confine the walk to, from a `/tree/<branch>/<path>` URL. A
   *  monorepo is otherwise unusable: `socratic-ai/cosmo` holds over seventeen
   *  thousand files, and a brief built from all of them describes everything
   *  and explains nothing. */
  subpath?: string;
};

export type TreeEntry = {
  path: string;
  /** `blob` is a file, `tree` is a directory. */
  type: 'blob' | 'tree';
  size: number;
};

export type RepoSnapshot = {
  ref: RepoRef;
  branch: string;
  description: string | null;
  entries: TreeEntry[];
  readme: string | null;
  /** Whether the tree came back complete; huge monorepos get cut off. */
  truncated: boolean;
};

/** Accepts what someone would actually paste: a browser URL, with or without
 *  a `/tree/main/...` suffix, a `.git` clone URL, or bare `owner/repo`. */
export function parseRepoRef(input: string): RepoRef | null {
  const trimmed = input.trim().replace(/\.git$/, '').replace(/\/+$/, '');
  const url = trimmed.match(/github\.com[/:]([^/]+)\/([^/]+)/);
  if (url !== null && url[1] !== undefined && url[2] !== undefined) {
    // Anything after `/tree/<branch>/` is the folder being pointed at.
    // `/blob/` is excluded on purpose: it addresses one file, and confining
    // the whole walk to a single file leaves nothing to walk.
    const folder = trimmed.match(/\/tree\/[^/]+\/(.+)$/);
    const subpath = folder?.[1];
    return subpath === undefined
      ? { owner: url[1], repo: url[2] }
      : { owner: url[1], repo: url[2], subpath };
  }
  const bare = trimmed.match(/^([\w.-]+)\/([\w.-]+)$/);
  if (bare !== null && bare[1] !== undefined && bare[2] !== undefined) {
    return { owner: bare[1], repo: bare[2] };
  }
  return null;
}

function headers(): HeadersInit {
  const token = import.meta.env.VITE_GITHUB_TOKEN;
  const base: Record<string, string> = { Accept: 'application/vnd.github+json' };
  if (typeof token === 'string' && token !== '') {
    base['Authorization'] = `Bearer ${token}`;
  }
  return base;
}

/** GitHub's own explanation, which is almost always the useful one — it names
 *  the org policy, the missing permission, or the SSO grant that is actually
 *  blocking the call. Falls back to the status code when there is no body. */
async function githubMessage(response: Response, path: string): Promise<string> {
  try {
    const body = (await response.json()) as { message?: string };
    if (typeof body.message === 'string' && body.message !== '') {
      return `GitHub refused that (${response.status}): ${body.message}`;
    }
  } catch {
    // No JSON body; fall through to the bare status.
  }
  return `GitHub returned ${response.status} for ${path}`;
}

/** The only network call this app makes to GitHub, and the only place a
 *  GitHub token is ever sent. `method` is stated rather than left to the
 *  default so that read-only is a visible property of this function: every
 *  GitHub mutation requires POST, PUT, PATCH or DELETE, so a GET client
 *  cannot create, change or delete anything, whatever it asks for. Changing
 *  this line is the only way to make this app capable of writing. */
async function api<T>(path: string): Promise<T> {
  const response = await fetch(`${API}${path}`, { method: 'GET', headers: headers() });
  if (!response.ok) {
    if (response.status === 404) {
      // Naming the path matters: a 404 is as often a URL this app built
      // wrongly as a repository that isn't there, and a message that only
      // ever blames the address sends you checking the address.
      const hasToken =
        typeof import.meta.env.VITE_GITHUB_TOKEN === 'string' &&
        import.meta.env.VITE_GITHUB_TOKEN !== '';
      throw new Error(
        `GitHub returned 404 for ${path}. ` +
          (hasToken
            ? "A token is configured, so either the repository doesn't exist or " +
              'the token has no access to it.'
            : 'No GitHub token is configured, which a private repository needs. ' +
              'Signing in with `gh auth login` is enough — the dev server picks ' +
              'that up automatically.'),
      );
    }
    // A 403 is only a rate limit when the budget is actually spent. It is
    // also how GitHub reports an org policy rejection, a token missing a
    // permission, and unauthorized SSO — collapsing all of those into "rate
    // limited" sends you off debugging the wrong thing entirely, so the
    // remaining-budget header decides, and GitHub's own words get through.
    const spent = response.headers.get('x-ratelimit-remaining') === '0';
    if (spent) {
      throw new Error(
        'GitHub is rate limiting us. Wait a few minutes, or add a GitHub ' +
          'token to .env to lift the limit.',
      );
    }
    throw new Error(await githubMessage(response, path));
  }
  return (await response.json()) as T;
}

/** Base64 that may hold code points above Latin-1 — `atob` alone mangles any
 *  file containing an em dash or an emoji. */
function decodeBase64(content: string): string {
  const binary = atob(content.replace(/\s/g, ''));
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}

export async function fetchSnapshot(ref: RepoRef): Promise<RepoSnapshot> {
  const meta = await api<{ default_branch: string; description: string | null }>(
    `/repos/${ref.owner}/${ref.repo}`,
  );

  const tree = await api<{
    tree: { path: string; type: string; size?: number }[];
    truncated: boolean;
  }>(`/repos/${ref.owner}/${ref.repo}/git/trees/${meta.default_branch}?recursive=1`);

  let entries: TreeEntry[] = tree.tree
    .filter((item) => item.type === 'blob' || item.type === 'tree')
    .map((item) => ({
      path: item.path,
      type: item.type === 'tree' ? ('tree' as const) : ('blob' as const),
      size: item.size ?? 0,
    }));

  if (ref.subpath !== undefined) {
    const prefix = ref.subpath.endsWith('/') ? ref.subpath : `${ref.subpath}/`;
    entries = entries.filter(
      (entry) => entry.path === ref.subpath || entry.path.startsWith(prefix),
    );
  }

  let readme: string | null = null;
  try {
    const raw = await api<{ content: string }>(`/repos/${ref.owner}/${ref.repo}/readme`);
    readme = decodeBase64(raw.content);
  } catch {
    // A repo with no README is normal; the brief just says so.
  }

  return {
    ref,
    branch: meta.default_branch,
    description: meta.description,
    entries,
    readme,
    truncated: tree.truncated,
  };
}

/** Extensions worth pulling up front. Code and config only: these are what a
 *  walkthrough traces through and what search needs to look inside. */
const SOURCE = new RegExp(
  '\\.(ts|tsx|js|jsx|mjs|cjs|py|go|rb|java|kt|swift|rs|php|cs|scala|' +
    'vue|svelte|sql|sh|bash|toml|ya?ml|json|html|css|scss)$',
  'i',
);

const SKIP_DIR = /^(node_modules|dist|build|out|vendor|\.git|\.next|target|coverage|__pycache__)(\/|$)/;

/** How many files to pull at ingest, and how wide to open the pipe. The cap
 *  keeps a monorepo from spending thousands of requests; the concurrency
 *  keeps a normal repo down to a couple of seconds. */
const PREFETCH_LIMIT = 250;
const PREFETCH_CONCURRENCY = 12;
const PREFETCH_MAX_BYTES = 120_000;

/** Pull the source files up front.
 *
 *  Two things depend on this. Search can only look inside files it already
 *  has, and following a flow — this calls that, which writes here — is search,
 *  not guesswork. And every later `read_file` is then a cache hit, so the
 *  agent can follow a thread across six files without six round trips
 *  stalling the conversation. */
export async function prefetchSources(
  ref: RepoRef,
  entries: TreeEntry[],
  onProgress?: (done: number, total: number) => void,
): Promise<Map<string, string>> {
  const wanted = entries
    .filter(
      (entry) =>
        entry.type === 'blob' &&
        !SKIP_DIR.test(entry.path) &&
        SOURCE.test(entry.path) &&
        entry.size > 0 &&
        entry.size <= PREFETCH_MAX_BYTES,
    )
    // Shallow files first: a repo's important code is rarely six levels down,
    // so if the cap bites, it bites on the least interesting files.
    .sort((a, b) => a.path.split('/').length - b.path.split('/').length)
    .slice(0, PREFETCH_LIMIT);

  const cache = new Map<string, string>();
  let done = 0;

  for (let i = 0; i < wanted.length; i += PREFETCH_CONCURRENCY) {
    const batch = wanted.slice(i, i + PREFETCH_CONCURRENCY);
    await Promise.all(
      batch.map(async (entry) => {
        try {
          const { text } = await fetchFile(ref, entry.path);
          cache.set(entry.path, text);
        } catch {
          // A file we can't read is simply not searchable; not worth failing
          // the whole ingest over one bad blob.
        }
        done += 1;
        onProgress?.(done, wanted.length);
      }),
    );
  }

  return cache;
}

/** One file's text. Rejects binaries and anything too big to be worth
 *  reading, with a reason the agent can say out loud. */
export async function fetchFile(
  ref: RepoRef,
  path: string,
): Promise<{ text: string; lines: number }> {
  const encoded = path.split('/').map(encodeURIComponent).join('/');
  const file = await api<{ content?: string; encoding?: string; size: number }>(
    `/repos/${ref.owner}/${ref.repo}/contents/${encoded}`,
  );
  if (file.content === undefined || file.encoding !== 'base64') {
    throw new Error(`${path} is not a readable text file`);
  }
  if (file.size > 400_000) {
    throw new Error(`${path} is too large to read (${Math.round(file.size / 1024)} KB)`);
  }
  const text = decodeBase64(file.content);
  if (text.includes(NUL)) throw new Error(`${path} looks like a binary file`);
  return { text, lines: text.split('\n').length };
}
