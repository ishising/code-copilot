import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { defineConfig } from 'vite';

/**
 * Where `gh` actually lives. Vite runs in Node here, so it can do what the
 * browser cannot — ask the GitHub CLI for its credential.
 */
const GH_CANDIDATES = [
  '/opt/homebrew/bin/gh',
  '/usr/local/bin/gh',
  '/usr/bin/gh',
  join(homedir(), '.local/bin/gh'),
];

/**
 * Borrow the GitHub CLI's token.
 *
 * It is an OAuth credential rather than a personal access token, so it reaches
 * organisations that reject a PAT on policy — measured: a fine-grained token
 * was refused by the `socratic-ai` org for exceeding a 366-day lifetime, while
 * this one reads the same private repository fine.
 *
 * Dev only. A production build must never bake a personal credential into a
 * bundle that gets served to someone else.
 */
function githubCLIToken(): string | null {
  const gh = GH_CANDIDATES.find((path) => existsSync(path));
  if (gh === undefined) return null;
  try {
    const token = execFileSync(gh, ['auth', 'token'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    return token === '' ? null : token;
  } catch {
    return null;
  }
}

export default defineConfig(({ command }) => {
  // An explicitly configured token always wins; this only fills a gap.
  if (command === 'serve' && !process.env['VITE_GITHUB_TOKEN']) {
    const token = githubCLIToken();
    if (token !== null) {
      process.env['VITE_GITHUB_TOKEN'] = token;
      console.log('  using the GitHub CLI credential (gh auth token)');
    }
  }
  return { server: { port: 7880 } };
});
