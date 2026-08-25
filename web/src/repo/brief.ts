/**
 * The repo brief: what the agent knows before the conversation starts.
 *
 * Deliberately deterministic — no model runs here. A realtime voice model has
 * a small working memory and gets slow and vague when it is stuffed, so this
 * is a compact, factual orientation (shape, stack, entry points, README) and
 * nothing more. Detail arrives on demand through `read_file`.
 */

import type { RepoSnapshot, TreeEntry } from './github';

/** Manifests worth reading in full at ingest: each one names the language and
 *  lists what the project borrowed rather than built. */
export const MANIFESTS = [
  'package.json',
  'requirements.txt',
  'pyproject.toml',
  'go.mod',
  'Cargo.toml',
  'Gemfile',
  'pom.xml',
  'composer.json',
] as const;

/** Directories that are somebody else's code or build output. They dominate
 *  file counts and tell you nothing about what the team built. */
const NOISE = /^(node_modules|dist|build|out|vendor|\.git|\.next|target|coverage|__pycache__)(\/|$)/;

const README_BUDGET = 1500;

function human(bytes: number): string {
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`;
  if (bytes >= 1000) return `${Math.round(bytes / 1000)} KB`;
  return `${bytes} B`;
}

type Group = { name: string; files: number; bytes: number };

/** Top-level shape: one line per root folder, biggest first. This is the
 *  single most useful thing to know about an unfamiliar repository. */
function topLevel(entries: TreeEntry[]): { groups: Group[]; loose: string[] } {
  const groups = new Map<string, Group>();
  const loose: string[] = [];

  for (const entry of entries) {
    if (entry.type !== 'blob' || NOISE.test(entry.path)) continue;
    const slash = entry.path.indexOf('/');
    if (slash === -1) {
      loose.push(entry.path);
      continue;
    }
    const name = entry.path.slice(0, slash);
    const group = groups.get(name) ?? { name, files: 0, bytes: 0 };
    group.files += 1;
    group.bytes += entry.size;
    groups.set(name, group);
  }

  return {
    groups: [...groups.values()].sort((a, b) => b.files - a.files),
    loose: loose.sort(),
  };
}

/** Files whose names conventionally mean "start reading here". Shallow paths
 *  first, because a `main.ts` at the root matters more than one six levels
 *  down in a test fixture. */
function entryPoints(entries: TreeEntry[]): string[] {
  const named = /(^|\/)(main|index|app|server|cli|__main__|program)\.[a-z]+$/i;
  return entries
    .filter(
      (entry) =>
        entry.type === 'blob' && !NOISE.test(entry.path) && named.test(entry.path),
    )
    .map((entry) => entry.path)
    .sort((a, b) => a.split('/').length - b.split('/').length || a.localeCompare(b))
    .slice(0, 8);
}

/** Dependencies, flattened to names. What a project borrows is the fastest
 *  read on what it actually does, and on how much of it is custom. */
function dependencies(manifests: Map<string, string>): string[] {
  const packageJson = manifests.get('package.json');
  if (packageJson !== undefined) {
    try {
      const parsed = JSON.parse(packageJson) as {
        dependencies?: Record<string, string>;
        devDependencies?: Record<string, string>;
      };
      return Object.keys({ ...parsed.dependencies, ...parsed.devDependencies });
    } catch {
      return [];
    }
  }
  const requirements = manifests.get('requirements.txt');
  if (requirements !== undefined) {
    return requirements
      .split('\n')
      .map((line) => line.trim().split(/[=<>!~[\s]/)[0] ?? '')
      .filter((name) => name !== '' && !name.startsWith('#'));
  }
  const goMod = manifests.get('go.mod');
  if (goMod !== undefined) {
    return [...goMod.matchAll(/^\s+([\w.\-/]+)\s+v/gm)].map((match) => match[1] ?? '');
  }
  return [];
}

function list(items: string[], max: number): string {
  if (items.length === 0) return 'none found';
  const shown = items.slice(0, max).join(', ');
  const rest = items.length - max;
  return rest > 0 ? `${shown} (+${rest} more)` : shown;
}

/** The usage example from the README — how a person actually holds this thing.
 *
 *  For a library this is the most valuable thing in the repository and it is
 *  not reachable by tracing code: there is no user-facing flow to follow, and
 *  the internal call chain is just the call chain. Five lines of usage say
 *  what the layers are for in a way that walking them never does.
 *
 *  Shell blocks are skipped — `npm install` teaches nothing about the shape. */
function usageExample(readme: string): string | null {
  const blocks = [...readme.matchAll(/```[a-z]*\n([\s\S]*?)```/g)]
    .map((match) => (match[1] ?? '').trim())
    .filter((block) => {
      const lines = block.split('\n');
      if (lines.length < 4) return false;
      return !/^(npm|pnpm|yarn|pip|uv|curl|brew|cd |git |export |\$)/.test(block);
    });
  if (blocks.length === 0) return null;
  return blocks.slice(0, 2).join('\n\n---\n\n').slice(0, 1800);
}

export function buildBrief(
  snapshot: RepoSnapshot,
  manifests: Map<string, string>,
): string {
  const { groups, loose } = topLevel(snapshot.entries);
  const files = snapshot.entries.filter(
    (entry) => entry.type === 'blob' && !NOISE.test(entry.path),
  );
  const deps = dependencies(manifests);

  const lines: string[] = [];
  lines.push(`REPOSITORY: ${snapshot.ref.owner}/${snapshot.ref.repo} (branch ${snapshot.branch})`);
  if (snapshot.description !== null && snapshot.description !== '') {
    lines.push(`GitHub description: ${snapshot.description}`);
  }
  // What it is, before where it is. This ordering is deliberate: the model's
  // attention is highest at the top of the brief, and a wall of borrowed
  // package names there taught it that the transport layer was the interesting
  // part of an SDK. Usage and README go first; the file census is orientation,
  // not subject matter.
  if (snapshot.readme !== null) {
    const usage = usageExample(snapshot.readme);
    if (usage !== null) {
      lines.push('', 'HOW IT IS USED (from the README) — for a library this is');
      lines.push('the real entry point, not whatever runs first:', usage);
    }

    const excerpt = snapshot.readme.slice(0, README_BUDGET);
    lines.push('', 'README (beginning):', excerpt);
    if (snapshot.readme.length > README_BUDGET) {
      lines.push('[README continues — read it with read_file if you need the rest]');
    }
  } else {
    lines.push('', 'No README in this repository.');
  }

  lines.push(
    '',
    `${files.length} files, ${groups.length} top-level folders` +
      (snapshot.truncated ? ' (tree truncated by GitHub — this is a big repo)' : ''),
  );

  lines.push('', 'TOP-LEVEL LAYOUT (largest first):');
  for (const group of groups.slice(0, 14)) {
    lines.push(`- ${group.name}/ — ${group.files} files, ${human(group.bytes)}`);
  }
  if (loose.length > 0) lines.push(`- loose files at the root: ${list(loose, 12)}`);

  const stack = MANIFESTS.filter((name) => manifests.has(name));
  if (stack.length > 0) {
    lines.push('', `STACK: ${stack.join(', ')} present.`);
  }
  if (deps.length > 0) {
    // Twelve, not thirty. This is a hint about what was borrowed, and a long
    // list reads as a list of topics worth walking.
    lines.push(`DEPENDENCIES (${deps.length} total): ${list(deps, 12)}`);
  }

  const starts = entryPoints(snapshot.entries);
  if (starts.length > 0) {
    lines.push(
      '',
      'LIKELY ENTRY POINTS (where execution begins — only worth walking if ' +
        'this is an app, and not the subject of a library): ' +
        starts.join(', '),
    );
  }

  return lines.join('\n');
}
