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
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HOST = 'https://app.askcosmo.ai';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');

function apiKey() {
  const line = readFileSync(join(root, '.env'), 'utf8')
    .split('\n')
    .find((l) => l.startsWith('VITE_COSMO_API_KEY='));
  const key = line?.slice('VITE_COSMO_API_KEY='.length).trim();
  if (!key || !key.startsWith('cosmo_')) {
    console.error('No usable VITE_COSMO_API_KEY in .env');
    process.exit(1);
  }
  return key;
}

async function api(path, key) {
  const response = await fetch(`${HOST}${path}`, {
    headers: { Authorization: `Bearer ${key}` },
  });
  if (!response.ok) {
    console.error(`${path} -> HTTP ${response.status}`);
    process.exit(1);
  }
  return response.json();
}

const when = (epoch) =>
  epoch ? new Date(epoch * 1000).toLocaleString() : '—';

const key = apiKey();
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
