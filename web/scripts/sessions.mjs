#!/usr/bin/env node
/**
 * List your Cosmo sessions, or print one session's transcript.
 *
 *   node scripts/sessions.mjs                 # recent sessions
 *   node scripts/sessions.mjs <session-id>    # that session's transcript
 *
 * Reads the API key from .env so the key never lands in your shell history.
 *
 * Audio is deliberately absent: the external API exposes sessions, transcripts
 * and usage, and no audio endpoint (`/recording`, `/audio`, `/recordings` and
 * `/media` all 404). Recordings, if your workspace keeps them, live in the
 * Cosmo web app rather than behind this API.
 */

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

/**
 * The host follows the configured backend rather than being pinned here. A
 * hardcoded `app.askcosmo.ai` returned 401 for a key that was working
 * perfectly against `platform.askcosmo.ai` at the time — a stored key is only
 * valid against the backend that issued it, so guessing the host reports a
 * dead credential that is actually fine.
 */
function host() {
  const configured =
    process.env['COSMO_BASE_URL'] ??
    read(join(root, '.env'))
      ?.split('\n')
      .find((l) => l.startsWith('VITE_COSMO_BASE_URL='))
      ?.slice('VITE_COSMO_BASE_URL='.length)
      .trim();
  return (configured && configured.length > 0 ? configured : 'https://platform.askcosmo.ai').replace(/\/$/, '');
}

const read = (path) => {
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return null;
  }
};

/**
 * The same resolution order the apps use, and for the same reason: this script
 * looked only at `.env` and returned 401 while the Mac app connected happily,
 * because the credential it was actually using came from `cosmo login`. A
 * debugging tool that cannot see the credential under test is worse than no
 * tool — it reports a dead key that is not the one in play.
 *
 * Order, first non-empty wins: COSMO_API_KEY, then `web/.env`, then the Mac
 * app's config.json, then the CLI's credentials file.
 */
function apiKey() {
  const fromEnv = process.env['COSMO_API_KEY']?.trim();
  if (fromEnv) return { key: fromEnv, from: 'COSMO_API_KEY' };

  const dotenv = read(join(root, '.env'));
  const line = dotenv?.split('\n').find((l) => l.startsWith('VITE_COSMO_API_KEY='));
  const fromFile = line?.slice('VITE_COSMO_API_KEY='.length).trim();
  if (fromFile) return { key: fromFile, from: 'web/.env' };

  const configPath = join(
    homedir(),
    'Library/Application Support/CodeCopilot/config.json',
  );
  const config = read(configPath);
  if (config) {
    try {
      const value = JSON.parse(config)?.cosmoApiKey?.trim();
      if (value) return { key: value, from: 'config.json' };
    } catch {
      // Malformed config is not a reason to stop; fall through to the CLI.
    }
  }

  // `cosmo login` writes TOML. Only the flat `api_key`/`expires_at` pair of
  // the selected profile is needed here, so this reads that subset rather
  // than taking a TOML dependency for a debugging script.
  const credentials = read(
    process.env['COSMO_CREDENTIALS_FILE'] ?? join(homedir(), '.cosmo/credentials'),
  );
  if (credentials) {
    const profile = process.env['COSMO_PROFILE'] ?? 'default';
    const section = credentials
      .split(/^\s*\[/m)
      .find((block) => block.startsWith(`profiles.${profile}]`) || block.startsWith(`${profile}]`));
    const value = section?.match(/^\s*api_key\s*=\s*"([^"]+)"/m)?.[1];
    const expires = section?.match(/^\s*expires_at\s*=\s*"?([^"\n]+)"?/m)?.[1];
    if (value) {
      // The key travels with an expiry, and an expired one earns a 401 that
      // looks identical to a wrong one. Say which it is.
      const at = Number.isNaN(Date.parse(expires ?? '')) ? null : Date.parse(expires);
      if (at !== null && at < Date.now()) {
        console.error(`The ${profile} credential expired ${new Date(at).toLocaleString()}. Run: cosmo login`);
        process.exit(1);
      }
      return { key: value, from: `cosmo login (${profile})` };
    }
  }

  console.error(
    'No Cosmo API key found. Looked at: COSMO_API_KEY, web/.env, the Mac app\'s\n' +
      'config.json, and ~/.cosmo/credentials. Run `cosmo login` or fill in web/.env.',
  );
  process.exit(1);
}

async function api(path, key) {
  const response = await fetch(`${host()}${path}`, {
    headers: { Authorization: `Bearer ${key}` },
  });
  if (!response.ok) {
    console.error(
      `${path} -> HTTP ${response.status}` +
        (response.status === 401 ? ' — that key is not valid for this host' : ''),
    );
    process.exit(1);
  }
  return response.json();
}

const when = (epoch) =>
  epoch ? new Date(epoch * 1000).toLocaleString() : '—';

const { key, from } = apiKey();
console.error(`(key from ${from})`);
const sessionId = process.argv[2];

if (!sessionId) {
  const sessions = await api('/api/v1/external/sessions?limit=20', key);
  if (sessions.length === 0) {
    console.log('No sessions yet.');
  }
  for (const s of sessions) {
    const mins =
      s.ended_at && s.started_at
        ? `${Math.round((s.ended_at - s.started_at) / 60)}m`
        : 'running';
    console.log(`${s.id}  ${when(s.started_at).padEnd(22)} ${mins.padEnd(8)} ${s.status}`);
  }
  console.log('\nTranscript:  node scripts/sessions.mjs <session-id>');
} else {
  const turns = await api(
    `/api/v1/external/sessions/${sessionId}/transcript`,
    key,
  );
  for (const turn of turns) {
    // Tool traffic is stored as text on the turn, clipped by the server to a
    // couple of hundred characters — enough to see what was called, never the
    // full file the tool returned.
    const text = String(turn.text ?? '');
    const who = turn.role === 'assistant' ? 'copilot' : 'you';
    if (text.startsWith('[tool')) {
      console.log(`  · ${text.replace(/\s+/g, ' ').slice(0, 120)}`);
    } else {
      console.log(`\n${who.toUpperCase()}: ${text}`);
    }
  }
}
